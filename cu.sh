#!/usr/bin/env bash

# cu — CRI Runtime Navigator (crictl helper)
set -u
set -o pipefail

CU_VERSION="0.1.0"
OLD_STTY=""
READONLY=false
RUNTIME_ENDPOINT="${CONTAINER_RUNTIME_ENDPOINT:-}"
IMAGE_ENDPOINT="${IMAGE_SERVICE_ENDPOINT:-}"
KIND_NODE=""
USE_KIND_FALLBACK=false
NO_KIND_FALLBACK=false
CURRENT_VIEW="containers"
SELECTED_IDX=0
SCROLL_OFFSET=0
FILTER=""
WATCH_MODE=false
REFRESH_INTERVAL=4
LAST_REFRESH=0
TERM_INITIALIZED=false
SORT_KEY="name"
SORT_DESC=false
INCIDENT_MODE=false
SMART_LOG_SINCE="15m"
SMART_LOG_ERRORS_ONLY=false
BUNDLE_DIR="${CU_BUNDLE_DIR:-./artifacts/cu-bundles}"
declare -a DATA_LINES=()
declare -A PREV_ATTEMPTS=()
ALERT_MSG=""
ALERT_UNTIL=0
SNAPSHOT_ACTIVE=false
SNAPSHOT_VIEW=""
SNAPSHOT_MSG=""
declare -A SNAPSHOT_MAP=()

# Colors
BOLD=$'\e[1m'; RESET=$'\e[0m'; GREEN=$'\e[32m'; CYAN=$'\e[36m'
WHITE=$'\e[37m'; GRAY=$'\e[90m'; BG_SELECT=$'\e[48;5;236m'; RED=$'\e[31m'
YELLOW=$'\e[33m'; DIM=$'\e[2m'; FG_RESET=$'\e[39m'

# Helpers
die() { echo -e "${RED}x error:${RESET} $*" >&2; exit 1; }
ok() { echo -e "${GREEN}ok${RESET} $*"; }
info() { echo -e "${CYAN}>${RESET} $*"; }
warn() { echo -e "${YELLOW}!${RESET} $*"; }

_at() { printf '\e[%d;%dH' "$1" "$2"; }
_eol() { printf '\e[K'; }
_clear() { printf '\e[2J\e[H'; }

_term_init() {
  tput smcup 2>/dev/null || true
  tput civis 2>/dev/null || true
  stty -echo -icanon isig min 1 time 0 2>/dev/null || true
  TERM_INITIALIZED=true
}

_term_restore_silent() {
  tput cnorm 2>/dev/null || true
  tput rmcup 2>/dev/null || true
  stty sane 2>/dev/null || true
}

_term_restore() {
  _term_restore_silent
  echo ""
}

_cleanup_on_exit() {
  if [[ "$TERM_INITIALIZED" == "true" ]]; then
    _term_restore
  fi
}

trap '_cleanup_on_exit' EXIT

_local_runtime_sockets() {
  local candidates=(
    "/run/containerd/containerd.sock"
    "/var/run/containerd/containerd.sock"
    "/run/crio/crio.sock"
    "/var/run/crio/crio.sock"
  )
  local s
  for s in "${candidates[@]}"; do
    [[ -S "$s" ]] && printf '%s\n' "$s"
  done
}

_print_socket_hint() {
  local found
  found="$(_local_runtime_sockets)"
  if [[ -n "$found" ]]; then
    echo "Detected local CRI sockets:" >&2
    printf '%s\n' "$found" | sed 's/^/  - /' >&2
  else
    cat >&2 <<'EOF'
No local CRI sockets detected at common paths:
  - /run/containerd/containerd.sock
  - /var/run/containerd/containerd.sock
  - /run/crio/crio.sock
  - /var/run/crio/crio.sock
EOF
  fi
}

require() {
  local cmd="$1"
  if command -v "$cmd" >/dev/null 2>&1; then
    return 0
  fi

  if [[ "$cmd" == "crictl" ]]; then
    cat >&2 <<'EOF'
x error: 'crictl' is required.

Install options:
  1) Ubuntu/Debian package (if available):
     sudo apt-get update && sudo apt-get install -y cri-tools

  2) Manual install from release tarball:
     VERSION="v1.30.1"
     curl -fsSL -o /tmp/crictl.tgz \
       "https://github.com/kubernetes-sigs/cri-tools/releases/download/${VERSION}/crictl-${VERSION}-linux-amd64.tar.gz"
     sudo tar -C /usr/local/bin -xzf /tmp/crictl.tgz

Notes:
  - In Codespaces/dev containers, crictl may not be present by default.
  - crictl only works where a CRI socket is reachable (containerd/CRI-O node).
EOF
    _print_socket_hint
    exit 1
  fi

  die "'$cmd' is required."
}

_normalize_endpoint() {
  local ep="$1"
  [[ -z "$ep" ]] && return 0
  if [[ "$ep" == unix://* || "$ep" == npipe://* || "$ep" == tcp://* ]]; then
    printf '%s' "$ep"
  else
    printf 'unix://%s' "$ep"
  fi
}

_detect_endpoint_from_crictl_yaml() {
  local cfg="/etc/crictl.yaml"
  [[ -f "$cfg" ]] || return 0
  awk -F': *' '/^[[:space:]]*runtime-endpoint:/ {print $2; exit}' "$cfg" 2>/dev/null || true
}

_detect_runtime_endpoint() {
  if [[ -n "$RUNTIME_ENDPOINT" ]]; then
    RUNTIME_ENDPOINT=$(_normalize_endpoint "$RUNTIME_ENDPOINT")
    return 0
  fi

  local from_cfg
  from_cfg="$(_detect_endpoint_from_crictl_yaml)"
  if [[ -n "$from_cfg" ]]; then
    RUNTIME_ENDPOINT=$(_normalize_endpoint "$from_cfg")
    return 0
  fi

  local candidates=(
    "/run/containerd/containerd.sock"
    "/var/run/containerd/containerd.sock"
    "/run/crio/crio.sock"
    "/var/run/crio/crio.sock"
  )

  local s
  for s in "${candidates[@]}"; do
    if [[ -S "$s" ]]; then
      RUNTIME_ENDPOINT="unix://${s}"
      return 0
    fi
  done
}

_check_runtime_access() {
  if [[ -n "$RUNTIME_ENDPOINT" ]]; then
    case "$RUNTIME_ENDPOINT" in
      unix://*)
        local sock_path="${RUNTIME_ENDPOINT#unix://}"
        if [[ ! -S "$sock_path" ]]; then
          cat >&2 <<EOF
x error: runtime endpoint socket not found:
  $RUNTIME_ENDPOINT

Use a valid endpoint with:
  ./cu.sh -r unix:///run/containerd/containerd.sock --ps
EOF
          _print_socket_hint
          exit 1
        fi
        ;;
      tcp://*|npipe://*)
        # Remote endpoints may be valid; do not pre-check local socket path.
        ;;
    esac
    return 0
  fi

  if ! $NO_KIND_FALLBACK && _maybe_enable_kind_fallback; then
    return 0
  fi

  cat >&2 <<'EOF'
x error: no CRI runtime endpoint could be detected.

Set one explicitly, for example:
  ./cu.sh -r unix:///run/containerd/containerd.sock --ps
EOF
  _print_socket_hint
  exit 1
}

_detect_kind_node() {
  if ! command -v docker >/dev/null 2>&1; then
    return 1
  fi

  if [[ -n "$KIND_NODE" ]]; then
    if docker ps --format '{{.Names}}' | grep -Fx "$KIND_NODE" >/dev/null 2>&1; then
      printf '%s' "$KIND_NODE"
      return 0
    fi
    return 1
  fi

  local cluster=""
  if command -v kind >/dev/null 2>&1; then
    cluster=$(kind get clusters 2>/dev/null | head -n 1 || true)
  fi

  if [[ -n "$cluster" ]]; then
    local preferred="${cluster}-control-plane"
    if docker ps --format '{{.Names}}' | grep -Fx "$preferred" >/dev/null 2>&1; then
      printf '%s' "$preferred"
      return 0
    fi
  fi

  docker ps --format '{{.Names}}' | grep -E -- '-control-plane([0-9]+)?$' | head -n 1 || true
}

_maybe_enable_kind_fallback() {
  local node
  node="$(_detect_kind_node)"
  [[ -z "$node" ]] && return 1

  if ! docker exec "$node" crictl --version >/dev/null 2>&1; then
    return 1
  fi

  KIND_NODE="$node"
  USE_KIND_FALLBACK=true
  info "No local CRI socket found; using kind node runtime via docker exec on '$KIND_NODE'."
  return 0
}

_crictl() {
  if $USE_KIND_FALLBACK; then
    docker exec "$KIND_NODE" crictl "$@"
    return $?
  fi

  local args=()

  if [[ -n "$RUNTIME_ENDPOINT" ]]; then
    args+=(--runtime-endpoint "$RUNTIME_ENDPOINT")
    if [[ -n "$IMAGE_ENDPOINT" ]]; then
      args+=(--image-endpoint "$(_normalize_endpoint "$IMAGE_ENDPOINT")")
    else
      args+=(--image-endpoint "$RUNTIME_ENDPOINT")
    fi
  fi

  crictl "${args[@]}" "$@"
}

_preview_endpoint() {
  if $USE_KIND_FALLBACK; then
    echo "kind://${KIND_NODE}"
    return 0
  fi

  if [[ -n "$RUNTIME_ENDPOINT" ]]; then
    echo "$RUNTIME_ENDPOINT"
  else
    echo "(crictl default/config)"
  fi
}

_fetch_containers() {
  mapfile -t DATA_LINES < <(
    _crictl ps -a --no-trunc 2>/dev/null | tail -n +2 | awk '{
      cid=$1; image=$2; created=$3; state=$4; name=$5; attempt=$6; pod=$7;
      if (cid=="") next;
      printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n", cid, name, state, image, pod, created, attempt;
    }'
  )
}

_fetch_pods() {
  mapfile -t DATA_LINES < <(
    _crictl pods --no-trunc 2>/dev/null | tail -n +2 | awk '{
      pid=$1; created=$2; state=$3; name=$4; ns=$5; attempt=$6;
      if (pid=="") next;
      printf "%s\t%s\t%s\t%s\t%s\t%s\n", pid, name, ns, state, created, attempt;
    }'
  )
}

_fetch_images() {
  mapfile -t DATA_LINES < <(
    _crictl images 2>/dev/null | tail -n +2 | awk '{
      image=$1; tag=$2; id=$3; size=$4;
      if (image=="") next;
      printf "%s\t%s\t%s\t%s\n", image, tag, id, size;
    }'
  )
}

_fetch_info() {
  local endpoint
  endpoint="$(_preview_endpoint)"
  local runtime="unknown"
  runtime=$(_crictl info 2>/dev/null | awk -F': ' '/runtimeName/ {gsub(/"/,"",$2); print $2; exit}')
  [[ -z "$runtime" ]] && runtime="unknown"

  DATA_LINES=()
  DATA_LINES+=("endpoint\t${endpoint}")
  DATA_LINES+=("runtime\t${runtime}")
  if $USE_KIND_FALLBACK; then
    DATA_LINES+=("mode\tkind docker exec")
    DATA_LINES+=("kind-node\t${KIND_NODE}")
  else
    DATA_LINES+=("mode\tlocal/explicit endpoint")
  fi
}

_fetch_data() {
  case "$CURRENT_VIEW" in
    containers) _fetch_containers ;;
    pods) _fetch_pods ;;
    images) _fetch_images ;;
    info) _fetch_info ;;
  esac
}

_reset_sort_for_view() {
  SORT_DESC=false
  case "$CURRENT_VIEW" in
    containers) SORT_KEY="name" ;;
    pods) SORT_KEY="name" ;;
    images) SORT_KEY="image" ;;
    info) SORT_KEY="key" ;;
  esac
}

_sort_index_for_key() {
  local key="$1"
  case "$CURRENT_VIEW:$key" in
    containers:id) echo 1 ;;
    containers:name) echo 2 ;;
    containers:state) echo 3 ;;
    containers:image) echo 4 ;;
    containers:pod) echo 5 ;;
    containers:created) echo 6 ;;
    containers:attempt) echo 7 ;;

    pods:id) echo 1 ;;
    pods:name) echo 2 ;;
    pods:namespace) echo 3 ;;
    pods:state) echo 4 ;;
    pods:created) echo 5 ;;
    pods:attempt) echo 6 ;;

    images:image) echo 1 ;;
    images:tag) echo 2 ;;
    images:id) echo 3 ;;
    images:size) echo 4 ;;

    info:key) echo 1 ;;
    info:value) echo 2 ;;
    *) echo 0 ;;
  esac
}

_is_numeric_sort_key() {
  case "$CURRENT_VIEW:$SORT_KEY" in
    containers:attempt|pods:attempt) return 0 ;;
    *) return 1 ;;
  esac
}

_sort_lines() {
  (( $# == 0 )) && return 0

  local idx
  idx=$(_sort_index_for_key "$SORT_KEY")
  if (( idx <= 0 )); then
    printf '%s\n' "$@"
    return 0
  fi

  local keyopt="-k${idx},${idx}"
  $SORT_DESC && keyopt+="r"

  if _is_numeric_sort_key; then
    printf '%s\n' "$@" | sort -n -t $'\t' "$keyopt"
  else
    printf '%s\n' "$@" | sort -t $'\t' "$keyopt"
  fi
}

_cycle_sort_key() {
  local -a keys=()
  case "$CURRENT_VIEW" in
    containers) keys=("name" "state" "image" "pod" "created" "attempt" "id") ;;
    pods) keys=("name" "namespace" "state" "created" "attempt" "id") ;;
    images) keys=("image" "tag" "size" "id") ;;
    info) keys=("key" "value") ;;
  esac

  local i
  for i in "${!keys[@]}"; do
    if [[ "${keys[$i]}" == "$SORT_KEY" ]]; then
      SORT_KEY="${keys[$(( (i + 1) % ${#keys[@]} ))]}"
      return 0
    fi
  done

  SORT_KEY="${keys[0]}"
}

_filtered_lines() {
  local lines=()
  if [[ -z "$FILTER" ]]; then
    lines=("${DATA_LINES[@]}")
  else
    mapfile -t lines < <(printf '%s\n' "${DATA_LINES[@]}" | grep -i "$FILTER" 2>/dev/null || true)
  fi

  if $INCIDENT_MODE; then
    mapfile -t lines < <(printf '%s\n' "${lines[@]}" | grep -iE 'error|failed|exited|crash|oom|notready|unknown|stopped' 2>/dev/null || true)
  fi

  (( ${#lines[@]} == 0 )) && return 0

  mapfile -t lines < <(_sort_lines "${lines[@]}")
  printf '%s\n' "${lines[@]}"
}

_status_color() {
  local s="${1,,}"
  case "$s" in
    running|ready) printf '%b' "$GREEN" ;;
    exited|stopped|created|unknown) printf '%b' "$YELLOW" ;;
    error|failed|notready|crashloopbackoff|oomkilled) printf '%b' "$RED" ;;
    *) printf '%b' "$WHITE" ;;
  esac
}

_state_badge() {
  local state="$1"
  local label
  label=$(printf '%s' "$state" | tr '[:lower:]' '[:upper:]')
  (( ${#label} > 10 )) && label="${label:0:10}"
  local sc
  sc=$(_status_color "$state")
  printf '%b[% -10s]%b' "$sc" "$label" "$FG_RESET"
}

_is_bad_state() {
  local s="${1,,}"
  case "$s" in
    running|ready) return 1 ;;
    *) return 0 ;;
  esac
}

_set_alert() {
  local msg="$1"
  ALERT_MSG="$msg"
  ALERT_UNTIL=$(( $(date +%s) + 10 ))
}

_update_restart_alerts() {
  [[ "$CURRENT_VIEW" != "containers" ]] && return 0

  local id name state image pod created attempt
  local prev numeric
  local -a bumps=()
  local -A next_attempts=()

  local line
  for line in "${DATA_LINES[@]}"; do
    IFS=$'\t' read -r id name state image pod created attempt <<< "$line"
    [[ -z "$id" ]] && continue
    numeric="${attempt//[^0-9]/}"
    [[ -z "$numeric" ]] && numeric=0
    next_attempts["$id"]="$numeric"

    prev="${PREV_ATTEMPTS[$id]:-}"
    if [[ -n "$prev" ]] && (( numeric > prev )); then
      bumps+=("${name}(${prev}->${numeric})")
    fi
  done

  PREV_ATTEMPTS=()
  for id in "${!next_attempts[@]}"; do
    PREV_ATTEMPTS["$id"]="${next_attempts[$id]}"
  done

  if $WATCH_MODE && (( ${#bumps[@]} > 0 )); then
    local msg="restart deltas: ${bumps[0]}"
    if (( ${#bumps[@]} > 1 )); then
      msg+=" +$(( ${#bumps[@]} - 1 )) more"
    fi
    _set_alert "$msg"
  fi
}

_snapshot_capture() {
  SNAPSHOT_MAP=()
  SNAPSHOT_VIEW="$CURRENT_VIEW"

  local line id state attempt
  case "$CURRENT_VIEW" in
    containers)
      for line in "${DATA_LINES[@]}"; do
        IFS=$'\t' read -r id _name state _image _pod _created attempt <<< "$line"
        [[ -z "$id" ]] && continue
        SNAPSHOT_MAP["$id"]="${state}|${attempt}"
      done
      ;;
    pods)
      for line in "${DATA_LINES[@]}"; do
        IFS=$'\t' read -r id _name _ns state _created _attempt <<< "$line"
        [[ -z "$id" ]] && continue
        SNAPSHOT_MAP["$id"]="$state"
      done
      ;;
    *)
      local idx=0
      for line in "${DATA_LINES[@]}"; do
        SNAPSHOT_MAP["line-${idx}"]="$line"
        (( idx++ ))
      done
      ;;
  esac

  SNAPSHOT_ACTIVE=true
  SNAPSHOT_MSG="baseline captured (${#DATA_LINES[@]} rows)"
}

_snapshot_diff() {
  SNAPSHOT_MSG=""
  $SNAPSHOT_ACTIVE || return 0
  [[ "$SNAPSHOT_VIEW" == "$CURRENT_VIEW" ]] || {
    SNAPSHOT_MSG="baseline view=${SNAPSHOT_VIEW}; current=${CURRENT_VIEW}"
    return 0
  }

  local line id state attempt
  local new_fail=0 recovered=0 changed=0 new_items=0 removed=0
  local -A current_map=()

  case "$CURRENT_VIEW" in
    containers)
      for line in "${DATA_LINES[@]}"; do
        IFS=$'\t' read -r id _name state _image _pod _created attempt <<< "$line"
        [[ -z "$id" ]] && continue
        current_map["$id"]="${state}|${attempt}"

        local base="${SNAPSHOT_MAP[$id]:-}"
        local base_state=""
        [[ -n "$base" ]] && base_state="${base%%|*}"

        if [[ -z "$base" ]]; then
          (( new_items++ ))
          if _is_bad_state "$state"; then (( new_fail++ )); fi
        else
          if [[ "$base" != "${state}|${attempt}" ]]; then (( changed++ )); fi
          if _is_bad_state "$state" && ! _is_bad_state "$base_state"; then (( new_fail++ )); fi
          if ! _is_bad_state "$state" && _is_bad_state "$base_state"; then (( recovered++ )); fi
        fi
      done
      ;;
    pods)
      for line in "${DATA_LINES[@]}"; do
        IFS=$'\t' read -r id _name _ns state _created _attempt <<< "$line"
        [[ -z "$id" ]] && continue
        current_map["$id"]="$state"

        local base_state="${SNAPSHOT_MAP[$id]:-}"
        if [[ -z "$base_state" ]]; then
          (( new_items++ ))
          if _is_bad_state "$state"; then (( new_fail++ )); fi
        else
          [[ "$base_state" != "$state" ]] && (( changed++ ))
          if _is_bad_state "$state" && ! _is_bad_state "$base_state"; then (( new_fail++ )); fi
          if ! _is_bad_state "$state" && _is_bad_state "$base_state"; then (( recovered++ )); fi
        fi
      done
      ;;
    *)
      SNAPSHOT_MSG="baseline active for ${SNAPSHOT_VIEW}"
      return 0
      ;;
  esac

  for id in "${!SNAPSHOT_MAP[@]}"; do
    [[ -n "${current_map[$id]:-}" ]] || (( removed++ ))
  done

  SNAPSHOT_MSG="diff new-fail:${new_fail} recovered:${recovered} changed:${changed} new:${new_items} removed:${removed}"
}

_selected_line() {
  local filtered=()
  mapfile -t filtered < <(_filtered_lines)
  (( ${#filtered[@]} == 0 )) && return 1

  local sidx=$SELECTED_IDX
  (( sidx < 0 )) && sidx=0
  (( sidx >= ${#filtered[@]} )) && sidx=$(( ${#filtered[@]} - 1 ))
  printf '%s' "${filtered[$sidx]}"
}

_detail_text_for_selected() {
  local line
  line="$(_selected_line)" || { printf 'no selection'; return 0; }

  case "$CURRENT_VIEW" in
    containers)
      local id name state image pod created attempt
      IFS=$'\t' read -r id name state image pod created attempt <<< "$line"
      printf 'id=%s  name=%s  state=%s  image=%s  pod=%s  created=%s  attempt=%s' \
        "${id:0:20}" "${name}" "${state}" "${image}" "${pod:0:20}" "${created}" "${attempt}"
      ;;
    pods)
      local pid pname pns pstate pcreated patt
      IFS=$'\t' read -r pid pname pns pstate pcreated patt <<< "$line"
      printf 'pod-id=%s  name=%s  ns=%s  state=%s  created=%s  attempt=%s' \
        "${pid:0:20}" "${pname}" "${pns}" "${pstate}" "${pcreated}" "${patt}"
      ;;
    images)
      local image tag iid size
      IFS=$'\t' read -r image tag iid size <<< "$line"
      printf 'image=%s:%s  id=%s  size=%s' "$image" "$tag" "${iid:0:20}" "$size"
      ;;
    info)
      local k v
      IFS=$'\t' read -r k v <<< "$line"
      printf '%s=%s' "$k" "$v"
      ;;
  esac
}

_view_hints() {
  case "$CURRENT_VIEW" in
    containers)
      printf '[Enter]inspect [l]logs [L]smart-logs [x]stop [D]delete [B]bundle [I]summary [i]incident [N]snapshot [S]next-sort [s]asc/desc [j/k|up/down]move [/]filter [w]watch [?]help [r]refresh [q]quit'
      ;;
    pods)
      printf '[Enter]inspectp [x]stopp [D]rmp [B]bundle [I]summary [i]incident [N]snapshot [S]next-sort [s]asc/desc [j/k|up/down]move [/]filter [w]watch [?]help [r]refresh [q]quit'
      ;;
    images)
      printf '[Enter]inspect-list [B]bundle [I]summary [i]incident [N]snapshot [S]next-sort [s]asc/desc [j/k|up/down]move [/]filter [w]watch [?]help [r]refresh [q]quit'
      ;;
    info)
      printf '[Enter]runtime-info [B]bundle [I]summary [i]incident [N]snapshot [S]next-sort [s]asc/desc [j/k|up/down]move [/]filter [w]watch [?]help [r]refresh [q]quit'
      ;;
  esac
}

_visible_rows() {
  local rows
  rows=$(tput lines 2>/dev/null || echo 40)
  local start=4
  # Header+tabs+endpoint+table header+separator + detail/hint/status rows.
  local v=$(( rows - start - 6 ))
  (( v < 1 )) && v=1
  printf '%d' "$v"
}

_draw_header() {
  local cols
  cols=$(tput cols 2>/dev/null || echo 120)
  local now
  now=$(date '+%H:%M:%S')

  _at 1 1
  printf '\e[48;5;17m%-*s\e[0m' "$cols" ""
  _at 1 2
  printf '%b%b cu-dash %bv%s%b' "$CYAN" "$BOLD" "$GRAY" "$CU_VERSION" "$RESET"

  _at 1 $(( cols - 22 ))
  if $WATCH_MODE; then
    printf '%bwatch:%ss%b  %s' "$YELLOW" "$REFRESH_INTERVAL" "$RESET" "$now"
  else
    printf '%blast:%s%b  %s' "$GRAY" "$(( $(date +%s) - LAST_REFRESH ))s" "$RESET" "$now"
  fi
}

_draw_tabs() {
  local cols
  cols=$(tput cols 2>/dev/null || echo 120)
  _at 2 1
  printf '\e[48;5;235m%-*s\e[0m' "$cols" ""
  _at 2 2

  local tabs=("1:containers" "2:pods" "3:images" "4:info")
  local t label key view
  for t in "${tabs[@]}"; do
    key="${t%%:*}"
    view="${t#*:}"
    label=" ${key} ${view} "
    if [[ "$CURRENT_VIEW" == "$view" ]]; then
      printf '\e[48;5;51m\e[38;5;232m%b%s%b\e[0m ' "$BOLD" "$label" "$RESET"
    else
      printf '\e[38;5;250m%s\e[0m ' "$label"
    fi
  done

  if [[ -n "$FILTER" ]]; then
    printf '  %b/%s%b' "$YELLOW" "$FILTER" "$RESET"
  fi
}

_draw_table() {
  local start=4
  local cols rows
  cols=$(tput cols 2>/dev/null || echo 120)
  rows=$(tput lines 2>/dev/null || echo 40)

  _at 3 1
  printf '%bendpoint:%b %s' "$GRAY" "$RESET" "$(_preview_endpoint)"
  _eol

  _at "$start" 1
  case "$CURRENT_VIEW" in
    containers)
      printf '%b%b %-12s %-16s %-13s %-28s %-12s %-9s%b' "$BOLD" "$CYAN" "ID" "NAME" "STATE" "IMAGE" "POD" "CREATED" "$RESET"
      ;;
    pods)
      printf '%b%b %-12s %-24s %-18s %-13s %-9s %-7s%b' "$BOLD" "$CYAN" "POD ID" "NAME" "NAMESPACE" "STATE" "CREATED" "ATTEMPT" "$RESET"
      ;;
    images)
      printf '%b%b %-32s %-16s %-14s %-10s%b' "$BOLD" "$CYAN" "IMAGE" "TAG" "IMAGE ID" "SIZE" "$RESET"
      ;;
    info)
      printf '%b%b %-18s %s%b' "$BOLD" "$CYAN" "KEY" "VALUE" "$RESET"
      ;;
  esac
  _eol

  _at $(( start + 1 )) 1
  printf '%b%*s%b' "$GRAY" "$cols" "" "$RESET"
  _at $(( start + 1 )) 1
  printf '%b%s%b' "$GRAY" "$(printf '%*s' "$cols" '' | tr ' ' '-')" "$RESET"

  local filtered=()
  mapfile -t filtered < <(_filtered_lines)

  local visible
  visible=$(_visible_rows)
  local end=$(( SCROLL_OFFSET + visible ))
  (( end > ${#filtered[@]} )) && end=${#filtered[@]}

  local row=$(( start + 2 ))
  local i line
  for (( i=SCROLL_OFFSET; i<end; i++ )); do
    line="${filtered[$i]}"
    _at "$row" 1
    _eol
    if (( i == SELECTED_IDX )); then
      printf '\e[48;5;24m'
    fi

    case "$CURRENT_VIEW" in
      containers)
        local id name state image pod created attempt badge
        IFS=$'\t' read -r id name state image pod created attempt <<< "$line"
        badge=$(_state_badge "$state")
        printf ' %-12s %-16s %-13s %-28s %-12s %-9s' "${id:0:12}" "${name:0:16}" "$badge" "${image:0:28}" "${pod:0:12}" "${created:0:9}"
        ;;
      pods)
        local pid pname pns pstate pcreated patt pbadge
        IFS=$'\t' read -r pid pname pns pstate pcreated patt <<< "$line"
        pbadge=$(_state_badge "$pstate")
        printf ' %-12s %-24s %-18s %-13s %-9s %-7s' "${pid:0:12}" "${pname:0:24}" "${pns:0:18}" "$pbadge" "${pcreated:0:9}" "${patt:0:7}"
        ;;
      images)
        local image tag iid size
        IFS=$'\t' read -r image tag iid size <<< "$line"
        printf ' %-32s %-16s %-14s %-10s' "${image:0:32}" "${tag:0:16}" "${iid:0:14}" "${size:0:10}"
        ;;
      info)
        local k v
        IFS=$'\t' read -r k v <<< "$line"
        printf ' %-18s %s' "${k:0:18}" "$v"
        ;;
    esac

    printf '%b' "$RESET"
    (( row++ ))
  done

  if (( ${#filtered[@]} == 0 )); then
    _at $(( start + 3 )) 2
    printf '%bNo data in %s%b' "$GRAY" "$CURRENT_VIEW" "$RESET"
  fi

  _at $(( rows - 4 )) 1
  printf '%b%s%b' "$GRAY" "$(printf '%*s' "$cols" '' | tr ' ' '-')" "$RESET"
  _eol

  local detail
  detail=$(_detail_text_for_selected)
  (( ${#detail} > cols - 11 )) && detail="${detail:0:$(( cols - 14 ))}..."
  _at $(( rows - 3 )) 1
  _eol
  printf '%bdetail:%b %s' "$CYAN" "$RESET" "$detail"

  _at $(( rows - 2 )) 1
  _eol
  local hints
  hints=$(_view_hints)
  (( ${#hints} > cols - 1 )) && hints="${hints:0:$(( cols - 4 ))}..."
  printf '%b%s%b' "$CYAN" "$hints" "$RESET"
  _eol

  _at $(( rows - 1 )) 1
  _eol
  local ord="asc"
  $SORT_DESC && ord="desc"
  local incident="off"
  $INCIDENT_MODE && incident="on"
  local status="rows:${#filtered[@]} view:${CURRENT_VIEW} selected:$(( SELECTED_IDX + 1 )) scroll:${SCROLL_OFFSET} sort:${SORT_KEY}(${ord}) incident:${incident}"
  if $SNAPSHOT_ACTIVE; then
    status+=" snap:on"
  fi
  if [[ -n "$SNAPSHOT_MSG" ]]; then
    status+=" | ${SNAPSHOT_MSG}"
  fi
  if (( $(date +%s) < ALERT_UNTIL )) && [[ -n "$ALERT_MSG" ]]; then
    status+=" | ALERT: ${ALERT_MSG}"
  fi
  (( ${#status} > cols - 2 )) && status="${status:0:$(( cols - 5 ))}..."
  printf '%b%s%b' "$GRAY" "$status" "$RESET"
}

_resolve_selected_id() {
  local filtered=()
  mapfile -t filtered < <(_filtered_lines)
  (( ${#filtered[@]} == 0 )) && return 1

  local sidx=$SELECTED_IDX
  (( sidx < 0 )) && sidx=0
  (( sidx >= ${#filtered[@]} )) && sidx=$(( ${#filtered[@]} - 1 ))

  local line
  line="${filtered[$sidx]}"
  IFS=$'\t' read -r _id _rest <<< "$line"
  printf '%s' "$_id"
}

_run_external() {
  local title="$1"
  shift
  _term_restore_silent
  echo ""
  echo "== $title =="
  echo ""
  "$@"
  echo ""
  read -r -p "Press Enter to return..." _
  _term_init
}

_ensure_bundle_dir() {
  mkdir -p "$BUNDLE_DIR" 2>/dev/null || true
}

_bundle_timestamp() {
  date +%Y%m%d-%H%M%S
}

_smart_logs_view() {
  local sid="$1"
  local title="smart logs ${sid:0:12}"
  local args=("logs" "--since" "$SMART_LOG_SINCE" "$sid")

  _term_restore_silent
  echo ""
  echo "== $title =="
  echo "mode: since=$SMART_LOG_SINCE errors_only=$SMART_LOG_ERRORS_ONLY"
  echo ""
  if $SMART_LOG_ERRORS_ONLY; then
    _crictl "${args[@]}" 2>/dev/null | grep -iE 'error|fatal|panic|exception|timeout|refused|denied|unavailable|failed' || true
  else
    _crictl "${args[@]}"
  fi
  echo ""
  echo "smart-log controls:"
  echo "  [1] since=5m  [2] since=15m  [3] since=1h  [e] toggle errors-only  [q] back"
  read -r -p "choose: " ch
  case "$ch" in
    1) SMART_LOG_SINCE="5m" ;;
    2) SMART_LOG_SINCE="15m" ;;
    3) SMART_LOG_SINCE="1h" ;;
    e|E)
      if $SMART_LOG_ERRORS_ONLY; then SMART_LOG_ERRORS_ONLY=false; else SMART_LOG_ERRORS_ONLY=true; fi
      ;;
    *) ;;
  esac
  _term_init
}

_build_diagnostics_bundle() {
  local sid="$1"
  local ts
  ts="$(_bundle_timestamp)"
  _ensure_bundle_dir

  local out="${BUNDLE_DIR}/cu-bundle-${ts}.txt"

  {
    echo "cu diagnostics bundle"
    echo "timestamp: $ts"
    echo "endpoint: $(_preview_endpoint)"
    echo "view: $CURRENT_VIEW"
    echo "incident_mode: $INCIDENT_MODE"
    echo "sort: $SORT_KEY desc=$SORT_DESC"
    echo "selected_id: ${sid:-none}"
    echo ""
    echo "==== crictl info ===="
    _crictl info 2>&1 || true
    echo ""
    echo "==== crictl ps -a ===="
    _crictl ps -a 2>&1 || true
    echo ""
    echo "==== crictl pods ===="
    _crictl pods 2>&1 || true
    echo ""
    echo "==== crictl images ===="
    _crictl images 2>&1 || true

    if [[ -n "$sid" ]]; then
      echo ""
      echo "==== selected inspect ===="
      if [[ "$CURRENT_VIEW" == "pods" ]]; then
        _crictl inspectp "$sid" 2>&1 || true
      else
        _crictl inspect "$sid" 2>&1 || true
      fi

      echo ""
      echo "==== selected logs (since=${SMART_LOG_SINCE}) ===="
      _crictl logs --since "$SMART_LOG_SINCE" "$sid" 2>&1 || true
    fi
  } > "$out"

  printf '%s' "$out"
}

_incident_summary_view() {
  _term_restore_silent

  local total_c running_c bad_c
  local total_p ready_p bad_p

  total_c=$(_crictl ps -a --no-trunc 2>/dev/null | awk 'NR>1{c++} END{print c+0}')
  running_c=$(_crictl ps -a --no-trunc 2>/dev/null | awk 'NR>1 && tolower($4)=="running" {c++} END{print c+0}')
  bad_c=$(( total_c - running_c ))

  total_p=$(_crictl pods --no-trunc 2>/dev/null | awk 'NR>1{c++} END{print c+0}')
  ready_p=$(_crictl pods --no-trunc 2>/dev/null | awk 'NR>1 && tolower($3)=="ready" {c++} END{print c+0}')
  bad_p=$(( total_p - ready_p ))

  local -a image_rows=()
  mapfile -t image_rows < <(_crictl ps -a --no-trunc 2>/dev/null | awk '
    NR>1 {
      st=tolower($4)
      if (st!="running") img[$2]++
    }
    END {
      for (i in img) printf "%d\t%s\n", img[i], i
    }
  ' | sort -nr | head -n 5)

  local -a workload_rows=()
  mapfile -t workload_rows < <(_crictl ps -a --no-trunc 2>/dev/null | awk '
    NR>1 {
      st=tolower($4)
      if (st!="running") wl[$5]++
    }
    END {
      for (w in wl) printf "%d\t%s\n", wl[w], w
    }
  ' | sort -nr | head -n 5)

  echo ""
  echo "== incident summary =="
  echo "endpoint: $(_preview_endpoint)"
  echo ""
  echo "containers: total=${total_c} running=${running_c} failing=${bad_c}"
  echo "pods:       total=${total_p} ready=${ready_p} failing=${bad_p}"
  echo ""
  echo "top failing images:"
  if (( ${#image_rows[@]} > 0 )); then
    local idx=1 row cnt img
    for row in "${image_rows[@]}"; do
      IFS=$'\t' read -r cnt img <<< "$row"
      printf '  i%d) %s (%s)\n' "$idx" "$img" "$cnt"
      (( idx++ ))
    done
  else
    echo "  - none"
  fi
  echo ""
  echo "top failing workloads:"
  if (( ${#workload_rows[@]} > 0 )); then
    local widx=1 wrow wcnt wl
    for wrow in "${workload_rows[@]}"; do
      IFS=$'\t' read -r wcnt wl <<< "$wrow"
      printf '  w%d) %s (%s)\n' "$widx" "$wl" "$wcnt"
      (( widx++ ))
    done
  else
    echo "  - none"
  fi
  echo ""
  echo "Drill-down: type iN or wN to filter containers (example: i1, w2)."
  read -r -p "Selection (Enter to return): " sel

  if [[ "$sel" =~ ^i([0-9]+)$ ]]; then
    local pick=$(( ${BASH_REMATCH[1]} - 1 ))
    if (( pick >= 0 && pick < ${#image_rows[@]} )); then
      local _cnt image
      IFS=$'\t' read -r _cnt image <<< "${image_rows[$pick]}"
      CURRENT_VIEW="containers"
      FILTER="$image"
      INCIDENT_MODE=true
      SELECTED_IDX=0
      SCROLL_OFFSET=0
      SNAPSHOT_MSG="drill-down image: ${image}"
    fi
  elif [[ "$sel" =~ ^w([0-9]+)$ ]]; then
    local wpick=$(( ${BASH_REMATCH[1]} - 1 ))
    if (( wpick >= 0 && wpick < ${#workload_rows[@]} )); then
      local _wcnt workload
      IFS=$'\t' read -r _wcnt workload <<< "${workload_rows[$wpick]}"
      CURRENT_VIEW="containers"
      FILTER="$workload"
      INCIDENT_MODE=true
      SELECTED_IDX=0
      SCROLL_OFFSET=0
      SNAPSHOT_MSG="drill-down workload: ${workload}"
    fi
  fi

  _term_init
}

_help_view() {
  _term_restore_silent
  cat <<'EOF'

== cu-dash help ==

Views
  1 containers     2 pods     3 images     4 info

Navigation
  j / k            move selection
  up / down        move selection
  /                set filter
  r                refresh
  w                toggle watch mode
  q                quit dashboard

Inspect / Actions
  Enter            inspect selected item
  l                logs (containers view)
  L                smart logs (containers view)
  x                stop selected container/pod sandbox
  D                delete selected container/pod sandbox

Troubleshooting
  i                toggle incident mode (failure-focused rows)
  I                incident summary popup (supports drill-down iN/wN)
  B                write diagnostics bundle file
  N                capture/clear snapshot baseline (diff in status bar)

Sorting
  S                cycle sort key for current view
  s                toggle sort order asc/desc

Smart logs controls
  1                since=5m
  2                since=15m
  3                since=1h
  e                toggle errors-only matching

CLI quick refs
  ./cu.sh --help
  ./cu.sh --bundle
  ./cu.sh --smart-logs <container-id> --since 15m

Press Enter to return...
EOF
  read -r _
  _term_init
}

_refresh_data() {
  _fetch_data
  _update_restart_alerts
  _snapshot_diff
  LAST_REFRESH=$(date +%s)

  local filtered=()
  mapfile -t filtered < <(_filtered_lines)
  if (( ${#filtered[@]} == 0 )); then
    SELECTED_IDX=0
    SCROLL_OFFSET=0
  else
    (( SELECTED_IDX >= ${#filtered[@]} )) && SELECTED_IDX=$(( ${#filtered[@]} - 1 ))
    (( SELECTED_IDX < 0 )) && SELECTED_IDX=0
  fi
}

_tui_loop() {
  _reset_sort_for_view
  _term_init
  _refresh_data

  while true; do
    _clear
    _draw_header
    _draw_tabs
    _draw_table

    local key
    if $WATCH_MODE; then
      IFS= read -rsn1 -t "$REFRESH_INTERVAL" key 2>/dev/null || true
      if [[ -z "${key:-}" ]]; then
        _refresh_data
        continue
      fi
    else
      IFS= read -rsn1 key 2>/dev/null || true
    fi

    case "$key" in
      q) break ;;
      1) CURRENT_VIEW="containers"; SELECTED_IDX=0; SCROLL_OFFSET=0; _reset_sort_for_view; _refresh_data ;;
      2) CURRENT_VIEW="pods"; SELECTED_IDX=0; SCROLL_OFFSET=0; _reset_sort_for_view; _refresh_data ;;
      3) CURRENT_VIEW="images"; SELECTED_IDX=0; SCROLL_OFFSET=0; _reset_sort_for_view; _refresh_data ;;
      4) CURRENT_VIEW="info"; SELECTED_IDX=0; SCROLL_OFFSET=0; _reset_sort_for_view; _refresh_data ;;
      j)
        (( SELECTED_IDX++ ))
        ;;
      k)
        (( SELECTED_IDX-- ))
        ;;
      r)
        _refresh_data
        ;;
      w)
        if $WATCH_MODE; then WATCH_MODE=false; else WATCH_MODE=true; fi
        ;;
      i)
        if $INCIDENT_MODE; then
          INCIDENT_MODE=false
        else
          INCIDENT_MODE=true
          if [[ "$CURRENT_VIEW" == "containers" || "$CURRENT_VIEW" == "pods" ]]; then
            SORT_KEY="state"
            SORT_DESC=false
          fi
        fi
        SELECTED_IDX=0
        SCROLL_OFFSET=0
        _refresh_data
        ;;
      S)
        _cycle_sort_key
        _refresh_data
        ;;
      s)
        if $SORT_DESC; then SORT_DESC=false; else SORT_DESC=true; fi
        _refresh_data
        ;;
      '/')
        _term_restore_silent
        read -r -p "Filter: " FILTER
        _term_init
        SELECTED_IDX=0
        SCROLL_OFFSET=0
        _refresh_data
        ;;
      $'\x1b')
        IFS= read -rsn2 -t 0.05 key 2>/dev/null || true
        case "$key" in
          '[A') (( SELECTED_IDX-- )) ;;
          '[B') (( SELECTED_IDX++ )) ;;
        esac
        ;;
      "")
        local sid
        sid="$(_resolve_selected_id)"
        if [[ -n "$sid" ]]; then
          case "$CURRENT_VIEW" in
            containers) _run_external "container inspect ${sid:0:12}" _crictl inspect "$sid" ;;
            pods) _run_external "pod inspect ${sid:0:12}" _crictl inspectp "$sid" ;;
            images) _run_external "image list" _crictl images ;;
            info) _run_external "runtime info" _crictl info ;;
          esac
        fi
        _refresh_data
        ;;
      l)
        if [[ "$CURRENT_VIEW" == "containers" ]]; then
          local sid
          sid="$(_resolve_selected_id)"
          [[ -n "$sid" ]] && _run_external "container logs ${sid:0:12}" _crictl logs "$sid"
          _refresh_data
        fi
        ;;
      L)
        if [[ "$CURRENT_VIEW" == "containers" ]]; then
          local sid
          sid="$(_resolve_selected_id)"
          [[ -n "$sid" ]] && _smart_logs_view "$sid"
          _refresh_data
        fi
        ;;
      B)
        local sid
        sid="$(_resolve_selected_id)" || sid=""
        _term_restore_silent
        local bundle
        bundle="$(_build_diagnostics_bundle "$sid")"
        echo ""
        echo "Bundle written: $bundle"
        read -r -p "Press Enter to continue..." _
        _term_init
        _refresh_data
        ;;
      I)
        _incident_summary_view
        _refresh_data
        ;;
      N)
        if $SNAPSHOT_ACTIVE && [[ "$SNAPSHOT_VIEW" == "$CURRENT_VIEW" ]]; then
          SNAPSHOT_ACTIVE=false
          SNAPSHOT_VIEW=""
          SNAPSHOT_MAP=()
          SNAPSHOT_MSG="snapshot cleared"
        else
          _snapshot_capture
        fi
        _refresh_data
        ;;
      '?')
        _help_view
        _refresh_data
        ;;
      x)
        if [[ "$CURRENT_VIEW" == "containers" ]]; then
          local sid
          sid="$(_resolve_selected_id)"
          if [[ -n "$sid" ]]; then
            _term_restore_silent
            if $READONLY; then
              echo "readonly mode enabled"
              read -r -p "Press Enter to continue..." _
            elif confirm "Stop container ${sid:0:12}?"; then
              _crictl stop "$sid"
              read -r -p "Press Enter to continue..." _
            fi
            _term_init
            _refresh_data
          fi
        elif [[ "$CURRENT_VIEW" == "pods" ]]; then
          local sid
          sid="$(_resolve_selected_id)"
          if [[ -n "$sid" ]]; then
            _term_restore_silent
            if $READONLY; then
              echo "readonly mode enabled"
              read -r -p "Press Enter to continue..." _
            elif confirm "Stop pod sandbox ${sid:0:12}?"; then
              _crictl stopp "$sid"
              read -r -p "Press Enter to continue..." _
            fi
            _term_init
            _refresh_data
          fi
        fi
        ;;
      D)
        local sid
        sid="$(_resolve_selected_id)"
        if [[ -n "$sid" ]]; then
          _term_restore_silent
          if $READONLY; then
            echo "readonly mode enabled"
            read -r -p "Press Enter to continue..." _
          else
            if [[ "$CURRENT_VIEW" == "containers" ]]; then
              confirm "Delete container ${sid:0:12}?" && _crictl rm "$sid"
            elif [[ "$CURRENT_VIEW" == "pods" ]]; then
              confirm "Delete pod sandbox ${sid:0:12}?" && _crictl rmp "$sid"
            fi
            read -r -p "Press Enter to continue..." _
          fi
          _term_init
          _refresh_data
        fi
        ;;
    esac

    local visible
    visible=$(_visible_rows)

    (( SELECTED_IDX < 0 )) && SELECTED_IDX=0
    if (( SELECTED_IDX < SCROLL_OFFSET )); then
      SCROLL_OFFSET=$SELECTED_IDX
    elif (( SELECTED_IDX >= SCROLL_OFFSET + visible )); then
      SCROLL_OFFSET=$(( SELECTED_IDX - visible + 1 ))
    fi
    (( SCROLL_OFFSET < 0 )) && SCROLL_OFFSET=0
  done

  _term_restore
}

confirm() {
  local prompt="$1"
  printf "%b%s%b [y/N]: " "$YELLOW" "$prompt" "$RESET"
  read -r ans
  [[ "$ans" == "y" || "$ans" == "Y" ]]
}

_picker() {
  local items=("$@")
  local selected=0
  local query=""
  local tmp_choice="/tmp/cu_choice"
  local hr="------------------------------------------"
  rm -f "$tmp_choice"

  OLD_STTY=$(stty -g)
  stty -echo -icanon isig min 1 time 0

  exec 3>&1; exec 1>/dev/tty
  tput civis

  cleanup() {
    [[ -n "$OLD_STTY" ]] && stty "$OLD_STTY"
    tput cnorm
    exec 1>&3
  }
  trap cleanup EXIT INT TERM

  while true; do
    local filtered=()
    local item
    for item in "${items[@]}"; do
      [[ -z "$query" || "$item" == *"$query"* ]] && filtered+=("$item")
    done

    local fcount=${#filtered[@]}
    (( selected >= fcount && fcount > 0 )) && selected=$(( fcount - 1 ))
    (( selected < 0 )) && selected=0

    clear
    printf "\n  ${BOLD}${WHITE}CRI RUNTIME NAVIGATOR${RESET}\n"
    printf "  ${GRAY}${hr}${RESET}\n"
    printf "  ${CYAN}>${RESET} endpoint: ${WHITE}%s${RESET}\n" "$(_preview_endpoint)"
    printf "  ${CYAN}>${RESET} search: ${WHITE}%s${RESET}${CYAN}|${RESET}\n" "$query"
    printf "  ${GRAY}${hr}${RESET}\n"

    local i
    for i in "${!filtered[@]}"; do
      (( i > 14 )) && break
      local name="${filtered[$i]}"
      if (( i == selected )); then
        printf "${BG_SELECT}${CYAN}  >  ${BOLD}%-64s${RESET}\n" "$name"
      else
        printf "     %-64s\n" "$name"
      fi
    done

    printf "  ${GRAY}${hr}${RESET}\n"
    printf "  ${GRAY}arrows: move | enter: select | q: quit${RESET}\n"

    local char
    char=$(dd bs=3 count=1 2>/dev/null)
    case "$char" in
      $'\x1b[A') (( selected > 0 )) && (( selected-- )) ;;
      $'\x1b[B') (( selected < fcount - 1 )) && (( selected++ )) ;;
      $'\x0a'|$'\x0d'|"")
        if (( fcount > 0 )); then
          echo "${filtered[$selected]}" > "$tmp_choice"
        fi
        break
        ;;
      $'\x1b'|q|Q) break ;;
      $'\x7f'|$'\x08') query="${query%?}" ;;
      *)
        if [[ "$char" =~ [[:print:]] ]]; then
          query+="$char"
          selected=0
        fi
        ;;
    esac
  done

  cleanup
  trap - EXIT INT TERM
}

list_pods() {
  _crictl pods
}

list_containers() {
  _crictl ps -a
}

list_images() {
  _crictl images
}

cmd_info() {
  info "Endpoint: $(_preview_endpoint)"
  _crictl info
}

cmd_logs() {
  local follow=false
  local id=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -f|--follow) follow=true; shift ;;
      *) id="$1"; shift ;;
    esac
  done

  [[ -z "$id" ]] && die "Need container ID."
  if $follow; then
    _crictl logs -f "$id"
  else
    _crictl logs "$id"
  fi
}

cmd_stop() {
  local id="$1"
  [[ -z "$id" ]] && die "Need container ID."
  $READONLY && die "Readonly mode enabled."
  confirm "Stop container $id?" || return 0
  _crictl stop "$id"
}

cmd_rm() {
  local id="$1"
  [[ -z "$id" ]] && die "Need container ID."
  $READONLY && die "Readonly mode enabled."
  confirm "Remove container $id?" || return 0
  _crictl rm "$id"
}

cmd_stopp() {
  local id="$1"
  [[ -z "$id" ]] && die "Need pod sandbox ID."
  $READONLY && die "Readonly mode enabled."
  confirm "Stop pod sandbox $id?" || return 0
  _crictl stopp "$id"
}

cmd_rmp() {
  local id="$1"
  [[ -z "$id" ]] && die "Need pod sandbox ID."
  $READONLY && die "Readonly mode enabled."
  confirm "Remove pod sandbox $id?" || return 0
  _crictl rmp "$id"
}

interactive() {
  _tui_loop
}

usage() {
  cat <<EOF
  ${BOLD}${CYAN}cu${RESET} v${CU_VERSION}  (crictl helper)

  cu                          Interactive container picker
  cu --info                   Runtime info
  cu --pods                   List pod sandboxes
  cu --ps                     List containers (all)
  cu --images                 List images
  cu --inspect <id>           Inspect container
  cu --inspectp <pod-id>      Inspect pod sandbox
  cu --logs <id> [-f]         Show logs (follow optional)
  cu --smart-logs <id>        Smart logs with --since window
  cu --bundle [id]            Write diagnostics bundle to artifacts folder
  cu --stop <id>              Stop container (confirm)
  cu --rm <id>                Remove container (confirm)
  cu --stopp <pod-id>         Stop pod sandbox (confirm)
  cu --rmp <pod-id>           Remove pod sandbox (confirm)

  Options:
    -r, --runtime-endpoint <endpoint>  Example: unix:///run/containerd/containerd.sock
    -i, --image-endpoint <endpoint>    Defaults to runtime endpoint
    --kind-node <docker-name>          Force running crictl inside this kind node container
    --no-kind-fallback                 Disable automatic kind fallback mode
    --since <duration>                 Smart-log/bundle since window (default: 15m)
    --readonly                         Disable stop/rm/stopp/rmp
    --help                             Show help
EOF
}

main() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -r|--runtime-endpoint) RUNTIME_ENDPOINT="$2"; shift 2 ;;
      -i|--image-endpoint) IMAGE_ENDPOINT="$2"; shift 2 ;;
      --kind-node) KIND_NODE="$2"; shift 2 ;;
      --no-kind-fallback) NO_KIND_FALLBACK=true; shift ;;
      --since) SMART_LOG_SINCE="$2"; shift 2 ;;
      --readonly) READONLY=true; shift ;;
      *) break ;;
    esac
  done

  local arg="${1:-}"
  if [[ "$arg" == "--help" || "$arg" == "-h" ]]; then
    usage
    return 0
  fi

  require crictl
  _detect_runtime_endpoint
  _check_runtime_access

  case "$arg" in
    "") interactive ;;
    --info) cmd_info ;;
    --pods) list_pods ;;
    --ps) list_containers ;;
    --images) list_images ;;
    --inspect)
      [[ -z "${2:-}" ]] && die "Need container ID."
      _crictl inspect "$2"
      ;;
    --inspectp)
      [[ -z "${2:-}" ]] && die "Need pod sandbox ID."
      _crictl inspectp "$2"
      ;;
    --logs)
      shift
      cmd_logs "$@"
      ;;
    --smart-logs)
      [[ -z "${2:-}" ]] && die "Need container ID."
      _term_init
      _smart_logs_view "$2"
      _term_restore
      ;;
    --bundle)
      local sid="${2:-}"
      local out
      out="$(_build_diagnostics_bundle "$sid")"
      echo "$out"
      ;;
    --stop)
      [[ -z "${2:-}" ]] && die "Need container ID."
      cmd_stop "$2"
      ;;
    --rm)
      [[ -z "${2:-}" ]] && die "Need container ID."
      cmd_rm "$2"
      ;;
    --stopp)
      [[ -z "${2:-}" ]] && die "Need pod sandbox ID."
      cmd_stopp "$2"
      ;;
    --rmp)
      [[ -z "${2:-}" ]] && die "Need pod sandbox ID."
      cmd_rmp "$2"
      ;;
    *)
      die "Unknown command: $arg (use --help)"
      ;;
  esac
}

main "$@"
