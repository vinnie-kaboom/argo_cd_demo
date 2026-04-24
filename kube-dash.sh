#!/usr/bin/env bash
# ============================================================
#  kube-dash  —  Kubernetes Terminal Dashboard
#  Pure bash + kubectl. Zero other dependencies.
#  Works fully air-gapped.
#
#  Controls:
#    Arrow keys / j,k    Navigate lists
#    Tab                 Next panel
#    Shift-Tab           Previous panel
#    Enter               Drill into resource
#    l                   Logs (selected pod)
#    e                   Exec shell (selected pod)
#    d                   Describe resource
#    r                   Rolling restart (deploy/sts/ds)
#    D                   Delete resource (with confirm)
#    /                   Search/filter current view
#    n                   Switch namespace
#    c                   Switch context
#    f                   Toggle follow logs
#    q / Ctrl-C          Quit / back
#    ?                   Help screen
#    1-6                 Jump to view
# ============================================================

set -uo pipefail

# ── Version ────────────────────────────────────────────────
VERSION="1.0.0"

# ── Terminal capabilities ──────────────────────────────────
TERM_ROWS=$(tput lines 2>/dev/null || echo 40)
TERM_COLS=$(tput cols  2>/dev/null || echo 120)

# ── Colors ─────────────────────────────────────────────────
C_RESET=$'\e[0m'
C_BOLD=$'\e[1m'
C_DIM=$'\e[2m'
C_REV=$'\e[7m'

C_BLACK=$'\e[38;5;232m'
C_WHITE=$'\e[38;5;255m'
C_GRAY=$'\e[38;5;240m'
C_LGRAY=$'\e[38;5;248m'

C_CYAN=$'\e[38;5;51m'
C_DCYAN=$'\e[38;5;38m'
C_GREEN=$'\e[38;5;82m'
C_YELLOW=$'\e[38;5;220m'
C_ORANGE=$'\e[38;5;208m'
C_RED=$'\e[38;5;196m'
C_BLUE=$'\e[38;5;39m'
C_MAGENTA=$'\e[38;5;171m'

BG_BAR=$'\e[48;5;235m'
BG_SEL=$'\e[48;5;24m'
BG_HDR=$'\e[48;5;17m'
BG_BLACK=$'\e[48;5;232m'

# ── State ──────────────────────────────────────────────────
CURRENT_NS="default"
CURRENT_CTX=""
CURRENT_VIEW="pods"     # pods | deploys | nodes | events | argocd | certs
SELECTED_IDX=0
FILTER=""
LAST_REFRESH=0
REFRESH_INTERVAL=5      # seconds
LOG_FOLLOW=false

# View index for header tabs
declare -A VIEW_IDX=([pods]=1 [deploys]=2 [nodes]=3 [events]=4 [argocd]=5 [certs]=6)

# Store fetched data globally to avoid re-fetching on every keypress
declare -a DATA_LINES=()
DETAIL_MODE=false
DETAIL_RESOURCE=""
DETAIL_NAME=""
DETAIL_NS=""

# ── Terminal setup ─────────────────────────────────────────

_term_init() {
  tput smcup 2>/dev/null   # save screen
  tput civis 2>/dev/null   # hide cursor
  stty -echo 2>/dev/null   # no input echo
  # Raw input mode for single-keypress reads
  stty cbreak 2>/dev/null || true
}

_term_restore() {
  tput cnorm 2>/dev/null   # show cursor
  tput rmcup 2>/dev/null   # restore screen
  stty echo  2>/dev/null   # restore echo
  stty -cbreak 2>/dev/null || true
  echo ""
  echo "  ${C_CYAN}kube-dash exited${C_RESET}"
}

trap '_term_restore; exit 0' EXIT INT TERM

# ── Drawing primitives ─────────────────────────────────────

# Move cursor to row, col (1-indexed)
_at() { printf '\e[%d;%dH' "$1" "$2"; }

# Clear from cursor to end of line
_eol() { printf '\e[K'; }

# Clear entire screen without flicker
_clear() { printf '\e[2J'; }

# Draw a horizontal line
_hline() {
  local row=$1 col=$2 width=$3 char="${4:-─}" color="${5:-$C_GRAY}"
  _at "$row" "$col"
  printf '%b%s%b' "$color" "$(printf '%*s' "$width" '' | tr ' ' "$char")" "$C_RESET"
}

# Draw a box
_box() {
  local r=$1 c=$2 h=$3 w=$4 color="${5:-$C_GRAY}"
  local i
  # Top
  _at "$r" "$c"
  printf '%b╭%s╮%b' "$color" "$(printf '%*s' $(( w-2 )) '' | tr ' ' '─')" "$C_RESET"
  # Sides
  for (( i=1; i<h-1; i++ )); do
    _at $(( r+i )) "$c"
    printf '%b│%b' "$color" "$C_RESET"
    _at $(( r+i )) $(( c+w-1 ))
    printf '%b│%b' "$color" "$C_RESET"
  done
  # Bottom
  _at $(( r+h-1 )) "$c"
  printf '%b╰%s╯%b' "$color" "$(printf '%*s' $(( w-2 )) '' | tr ' ' '─')" "$C_RESET"
}

# Pad/truncate string to exact width
_fit() {
  local str="$1" width="$2"
  # Strip ANSI for length calc
  local plain
  plain=$(printf '%s' "$str" | sed 's/\x1b\[[0-9;]*m//g')
  local len=${#plain}
  if (( len > width )); then
    # Truncate — tricky with ANSI, just work on plain
    printf '%s' "${plain:0:$(( width-1 ))}…"
  else
    printf '%s%*s' "$str" $(( width - len )) ''
  fi
}

# ── Header bar ─────────────────────────────────────────────

_draw_header() {
  TERM_COLS=$(tput cols 2>/dev/null || echo 120)

  _at 1 1
  printf '%b%b%-*s%b' "$BG_HDR" "$C_BOLD" "$TERM_COLS" "" "$C_RESET"

  _at 1 2
  printf '%b%b kube-dash %bv%s%b' "$BG_HDR" "$C_CYAN" "$C_GRAY" "$VERSION" "$C_RESET"

  # Context + namespace
  local ctx_display="${CURRENT_CTX:-none}"
  local ns_display="${CURRENT_NS}"
  local info="${C_YELLOW}${ctx_display}${C_RESET}${C_GRAY}/${C_RESET}${C_GREEN}${ns_display}${C_RESET}"
  local info_plain="${ctx_display}/${ns_display}"
  local info_col=$(( TERM_COLS / 2 - ${#info_plain} / 2 ))
  _at 1 "$info_col"
  printf '%b  %b%s%b/%b%s%b  ' "$BG_HDR" "$C_YELLOW" "$ctx_display" "$C_GRAY" "$C_GREEN" "$ns_display" "$C_RESET"

  # Clock top right
  local clock
  clock=$(date '+%H:%M:%S')
  _at 1 $(( TERM_COLS - 9 ))
  printf '%b%b%s%b ' "$BG_HDR" "$C_LGRAY" "$clock" "$C_RESET"
}

# ── Tab bar ────────────────────────────────────────────────

_draw_tabs() {
  TERM_COLS=$(tput cols 2>/dev/null || echo 120)

  _at 2 1
  printf '%b%-*s%b' "$BG_BAR" "$TERM_COLS" "" "$C_RESET"
  _at 2 1

  local tabs=("1:Pods" "2:Deploys" "3:Nodes" "4:Events" "5:ArgoCD" "6:Certs")
  local views=("pods" "deploys" "nodes" "events" "argocd" "certs")

  printf ' '
  for i in "${!tabs[@]}"; do
    local tab="${tabs[$i]}"
    local view="${views[$i]}"
    if [[ "$view" == "$CURRENT_VIEW" ]]; then
      printf '%b%b %s %b ' "$C_CYAN" "$C_BOLD" "$tab" "$C_RESET$BG_BAR"
    else
      printf '%b %s %b' "$C_GRAY" "$tab" "$C_RESET$BG_BAR"
    fi
    printf '│'
  done

  # Filter indicator
  if [[ -n "$FILTER" ]]; then
    printf ' %b/%s%b' "$C_YELLOW" "$FILTER" "$C_RESET"
  fi

  # Refresh countdown
  local now elapsed next
  now=$(date +%s)
  elapsed=$(( now - LAST_REFRESH ))
  next=$(( REFRESH_INTERVAL - elapsed ))
  (( next < 0 )) && next=0
  _at 2 $(( TERM_COLS - 12 ))
  printf '%b refresh %-2ds%b' "$C_GRAY" "$next" "$C_RESET"
}

# ── Status bar ─────────────────────────────────────────────

_draw_statusbar() {
  TERM_COLS=$(tput cols 2>/dev/null || echo 120)
  TERM_ROWS=$(tput lines 2>/dev/null || echo 40)

  _at "$TERM_ROWS" 1
  printf '%b%-*s%b' "$BG_BAR" "$TERM_COLS" "" "$C_RESET"
  _at "$TERM_ROWS" 2

  if $DETAIL_MODE; then
    printf '%b[q]%b back  %b[l]%b logs  %b[e]%b exec  %b[r]%b restart  %b[D]%b delete  %b[?]%b help' \
      "$C_CYAN" "$C_RESET" "$C_CYAN" "$C_RESET" "$C_CYAN" "$C_RESET" \
      "$C_CYAN" "$C_RESET" "$C_RED"  "$C_RESET" "$C_CYAN" "$C_RESET"
  else
    printf '%b[1-6]%b view  %b[↑↓/jk]%b nav  %b[Enter]%b detail  %b[l]%b logs  %b[/]%b filter  %b[n]%b ns  %b[c]%b ctx  %b[?]%b help  %b[q]%b quit' \
      "$C_CYAN" "$C_RESET" "$C_CYAN" "$C_RESET" "$C_CYAN" "$C_RESET" \
      "$C_CYAN" "$C_RESET" "$C_CYAN" "$C_RESET" "$C_CYAN" "$C_RESET" \
      "$C_CYAN" "$C_RESET" "$C_CYAN" "$C_RESET" "$C_CYAN" "$C_RESET"
  fi
}

# ── Column header row ──────────────────────────────────────

_draw_col_header() {
  local row=$1; shift
  local cols=("$@")
  TERM_COLS=$(tput cols 2>/dev/null || echo 120)

  _at "$row" 1
  printf '%b%b ' "$C_BOLD" "$C_DCYAN"
  for col in "${cols[@]}"; do
    printf '%-s  ' "$col"
  done
  printf '%b' "$C_RESET"
  _eol
}

# ── Status color helper ────────────────────────────────────

_status_color() {
  local s="$1"
  case "$s" in
    Running|Healthy|Synced|True|Ready|Bound|Active|Succeeded)
      printf '%b' "$C_GREEN" ;;
    Pending|Progressing|OutOfSync|Unknown|Terminating)
      printf '%b' "$C_YELLOW" ;;
    Failed|Error|CrashLoopBackOff|OOMKilled|Degraded|False|Lost)
      printf '%b' "$C_RED" ;;
    Completed)
      printf '%b' "$C_GRAY" ;;
    *)
      printf '%b' "$C_LGRAY" ;;
  esac
}

# ── Data fetchers ──────────────────────────────────────────

_fetch_pods() {
  local ns_flag
  [[ "$CURRENT_NS" == "all" ]] && ns_flag="-A" || ns_flag="-n $CURRENT_NS"

  mapfile -t DATA_LINES < <(
    kubectl get pods $ns_flag \
      --no-headers \
      -o custom-columns=\
'NAMESPACE:.metadata.namespace,'\
'NAME:.metadata.name,'\
'READY:.status.containerStatuses[*].ready,'\
'STATUS:.status.phase,'\
'RESTARTS:.status.containerStatuses[*].restartCount,'\
'AGE:.metadata.creationTimestamp,'\
'NODE:.spec.nodeName' \
      2>/dev/null \
    | awk '{
        # Count ready containers
        split($3, a, ","); ready=0; total=0
        for (i in a) { total++; if (a[i]=="true") ready++ }
        # Sum restarts
        split($5, b, ","); restarts=0
        for (i in b) { restarts += b[i]+0 }
        printf "%s\t%s\t%d/%d\t%s\t%d\t%s\t%s\n", $1,$2,ready,total,$4,restarts,$6,$7
      }' \
    | sort -k4,4
  )
}

_fetch_deploys() {
  local ns_flag
  [[ "$CURRENT_NS" == "all" ]] && ns_flag="-A" || ns_flag="-n $CURRENT_NS"

  mapfile -t DATA_LINES < <(
    kubectl get deployments $ns_flag \
      --no-headers \
      -o custom-columns=\
'NAMESPACE:.metadata.namespace,'\
'NAME:.metadata.name,'\
'READY:.status.readyReplicas,'\
'UP-TO-DATE:.status.updatedReplicas,'\
'AVAILABLE:.status.availableReplicas,'\
'DESIRED:.spec.replicas,'\
'AGE:.metadata.creationTimestamp' \
      2>/dev/null \
    | awk '{
        ready=$3; desired=$6
        if (ready=="<none>") ready=0
        if (desired=="<none>") desired=0
        status="OK"
        if (ready+0 < desired+0) status="Degraded"
        if (ready==desired && desired+0>0) status="Healthy"
        printf "%s\t%s\t%s/%s\t%s\t%s\t%s\n", $1,$2,ready,desired,status,$5,$7
      }'
  )
}

_fetch_nodes() {
  mapfile -t DATA_LINES < <(
    kubectl get nodes \
      --no-headers \
      -o custom-columns=\
'NAME:.metadata.name,'\
'STATUS:.status.conditions[-1].type,'\
'ROLES:.metadata.labels.node-role\.kubernetes\.io/control-plane,'\
'VERSION:.status.nodeInfo.kubeletVersion,'\
'OS:.status.nodeInfo.osImage,'\
'ARCH:.status.nodeInfo.architecture,'\
'AGE:.metadata.creationTimestamp' \
      2>/dev/null \
    | awk '{
        role=$3; if (role=="<none>"||role=="") role="worker"
        else role="control-plane"
        printf "%s\t%s\t%s\t%s\t%s\t%s\n", $1,$2,role,$4,$6,$7
      }'
  )
}

_fetch_events() {
  local ns_flag
  [[ "$CURRENT_NS" == "all" ]] && ns_flag="-A" || ns_flag="-n $CURRENT_NS"

  mapfile -t DATA_LINES < <(
    kubectl get events $ns_flag \
      --no-headers \
      --sort-by='.lastTimestamp' \
      -o custom-columns=\
'NAMESPACE:.metadata.namespace,'\
'LAST:.lastTimestamp,'\
'TYPE:.type,'\
'REASON:.reason,'\
'OBJECT:.involvedObject.name,'\
'MESSAGE:.message' \
      2>/dev/null \
    | tail -50 \
    | awk '{ printf "%s\t%s\t%s\t%s\t%s\t%s\n", $1,$2,$3,$4,$5,$6 }'
  )
}

_fetch_argocd() {
  mapfile -t DATA_LINES < <(
    kubectl get applications.argoproj.io -A \
      --no-headers \
      -o custom-columns=\
'NAMESPACE:.metadata.namespace,'\
'NAME:.metadata.name,'\
'SYNC:.status.sync.status,'\
'HEALTH:.status.health.status,'\
'REPO:.spec.source.repoURL,'\
'PATH:.spec.source.path,'\
'TARGET:.spec.destination.namespace' \
      2>/dev/null \
    | awk '{ printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n", $1,$2,$3,$4,$5,$6,$7 }' \
    || echo "argocd-ns	not-found	N/A	N/A	N/A	N/A	N/A"
  )
}

_fetch_certs() {
  mapfile -t DATA_LINES < <(
    kubectl get certificates.cert-manager.io -A \
      --no-headers \
      -o custom-columns=\
'NAMESPACE:.metadata.namespace,'\
'NAME:.metadata.name,'\
'READY:.status.conditions[-1].status,'\
'SECRET:.spec.secretName,'\
'ISSUER:.spec.issuerRef.name,'\
'EXPIRY:.status.notAfter,'\
'RENEW:.status.renewalTime' \
      2>/dev/null \
    | awk '{ printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n", $1,$2,$3,$4,$5,$6,$7 }' \
    || echo "cert-ns	not-found	N/A	N/A	N/A	N/A	N/A"
  )
}

_refresh_data() {
  case "$CURRENT_VIEW" in
    pods)    _fetch_pods    ;;
    deploys) _fetch_deploys ;;
    nodes)   _fetch_nodes   ;;
    events)  _fetch_events  ;;
    argocd)  _fetch_argocd  ;;
    certs)   _fetch_certs   ;;
  esac
  LAST_REFRESH=$(date +%s)
  # Reset selection if out of bounds
  local count=${#DATA_LINES[@]}
  (( SELECTED_IDX >= count && count > 0 )) && SELECTED_IDX=$(( count - 1 ))
}

# ── Filter data ────────────────────────────────────────────

_filtered_lines() {
  if [[ -z "$FILTER" ]]; then
    printf '%s\n' "${DATA_LINES[@]}"
  else
    printf '%s\n' "${DATA_LINES[@]}" | grep -i "$FILTER" 2>/dev/null || true
  fi
}

# ── View renderers ─────────────────────────────────────────

_render_pods() {
  local start_row=4
  local max_rows=$(( TERM_ROWS - start_row - 1 ))
  TERM_COLS=$(tput cols 2>/dev/null || echo 120)

  # Column widths
  local w_ns=14 w_name=36 w_ready=7 w_status=18 w_restarts=9 w_age=10 w_node=20

  _at $start_row 1
  printf '%b%b %-*s %-*s %-*s %-*s %-*s %-*s %-*s%b' \
    "$C_BOLD" "$C_DCYAN" \
    "$w_ns" "NAMESPACE" "$w_name" "NAME" "$w_ready" "READY" \
    "$w_status" "STATUS" "$w_restarts" "RESTARTS" "$w_age" "AGE" "$w_node" "NODE" \
    "$C_RESET"
  _eol

  _hline $(( start_row+1 )) 1 "$TERM_COLS" "─" "$C_GRAY"

  local row=$(( start_row + 2 ))
  local idx=0
  local filtered=()
  mapfile -t filtered < <(_filtered_lines)

  for line in "${filtered[@]}"; do
    (( row > TERM_ROWS - 1 )) && break

    IFS=$'\t' read -r ns name ready status restarts age node <<< "$line"

    local sc
    sc=$(_status_color "$status")

    _at "$row" 1

    if (( idx == SELECTED_IDX )); then
      printf '%b' "$BG_SEL"
    fi

    printf ' %b%-*s%b %b%-*s%b %b%-*s%b %b%-*s%b %b%-*s%b %-*s %-*s' \
      "$C_GRAY"  "$w_ns"       "$ns" \
      "$C_RESET" "$C_WHITE"    "$w_name"     "${name:0:$w_name}" \
      "$C_RESET" "$C_GREEN"    "$w_ready"    "$ready" \
      "$C_RESET" "$sc"         "$w_status"   "$status" \
      "$C_RESET" \
      "$(if (( ${restarts:-0} > 5 )); then printf '%b' "$C_RED"; else printf '%b' "$C_LGRAY"; fi)" \
      "$w_restarts" "${restarts:-0}" \
      "$C_RESET" \
      "$w_age"  "${age:0:$w_age}" \
      "$w_node" "${node:0:$w_node}"

    printf '%b' "$C_RESET"
    _eol

    (( idx++ ))
    (( row++ ))
  done

  # Empty state
  if [[ ${#filtered[@]} -eq 0 ]]; then
    _at $(( start_row + 4 )) $(( TERM_COLS/2 - 10 ))
    printf '%bNo pods found%b' "$C_GRAY" "$C_RESET"
  fi

  # Summary line
  _at $(( TERM_ROWS - 1 )) 2
  local total=${#filtered[@]}
  local running
  running=$(printf '%s\n' "${filtered[@]}" | grep -c "Running" 2>/dev/null || echo 0)
  printf '%b%d pods%b  %bRunning: %d%b' "$C_LGRAY" "$total" "$C_RESET" "$C_GREEN" "$running" "$C_RESET"
}

_render_deploys() {
  local start_row=4
  TERM_COLS=$(tput cols 2>/dev/null || echo 120)

  local w_ns=14 w_name=36 w_ready=10 w_status=12 w_age=10

  _at $start_row 1
  printf '%b%b %-*s %-*s %-*s %-*s %-*s%b' \
    "$C_BOLD" "$C_DCYAN" \
    "$w_ns" "NAMESPACE" "$w_name" "NAME" \
    "$w_ready" "READY" "$w_status" "STATUS" "$w_age" "AGE" \
    "$C_RESET"
  _eol
  _hline $(( start_row+1 )) 1 "$TERM_COLS" "─" "$C_GRAY"

  local row=$(( start_row+2 ))
  local idx=0
  local filtered=()
  mapfile -t filtered < <(_filtered_lines)

  for line in "${filtered[@]}"; do
    (( row > TERM_ROWS-1 )) && break
    IFS=$'\t' read -r ns name ready status replicas rollout age <<< "$line"
    local sc; sc=$(_status_color "$status")

    _at "$row" 1
    (( idx == SELECTED_IDX )) && printf '%b' "$BG_SEL"

    printf ' %b%-*s%b %b%-*s%b %b%-*s%b %b%-*s%b %-*s' \
      "$C_GRAY"  "$w_ns"    "$ns" \
      "$C_RESET" "$C_WHITE" "$w_name"   "${name:0:$w_name}" \
      "$C_RESET" "$C_WHITE" "$w_ready"  "$ready" \
      "$C_RESET" "$sc"      "$w_status" "$status" \
      "$C_RESET" "$w_age"   "${age:0:$w_age}"

    printf '%b'; _eol
    (( idx++ )); (( row++ ))
  done
}

_render_nodes() {
  local start_row=4
  TERM_COLS=$(tput cols 2>/dev/null || echo 120)

  local w_name=30 w_status=10 w_role=14 w_ver=16 w_arch=8 w_age=10

  _at $start_row 1
  printf '%b%b %-*s %-*s %-*s %-*s %-*s %-*s%b' \
    "$C_BOLD" "$C_DCYAN" \
    "$w_name" "NAME" "$w_status" "STATUS" "$w_role" "ROLE" \
    "$w_ver" "VERSION" "$w_arch" "ARCH" "$w_age" "AGE" \
    "$C_RESET"
  _eol
  _hline $(( start_row+1 )) 1 "$TERM_COLS" "─" "$C_GRAY"

  local row=$(( start_row+2 ))
  local idx=0
  local filtered=()
  mapfile -t filtered < <(_filtered_lines)

  for line in "${filtered[@]}"; do
    (( row > TERM_ROWS-1 )) && break
    IFS=$'\t' read -r name status role version arch age <<< "$line"
    local sc; sc=$(_status_color "$status")
    local role_color="$C_CYAN"
    [[ "$role" == "worker" ]] && role_color="$C_LGRAY"

    _at "$row" 1
    (( idx == SELECTED_IDX )) && printf '%b' "$BG_SEL"

    printf ' %b%-*s%b %b%-*s%b %b%-*s%b %-*s %-*s %-*s' \
      "$C_WHITE"    "$w_name"   "${name:0:$w_name}" \
      "$C_RESET"    "$sc"       "$w_status" "$status" \
      "$C_RESET"    "$role_color" "$w_role" "$role" \
      "$C_RESET"    "$w_ver"    "${version:0:$w_ver}" \
                    "$w_arch"   "$arch" \
                    "$w_age"    "${age:0:$w_age}"

    printf '%b'; _eol
    (( idx++ )); (( row++ ))
  done
}

_render_events() {
  local start_row=4
  TERM_COLS=$(tput cols 2>/dev/null || echo 120)

  local w_ns=12 w_time=20 w_type=8 w_reason=20 w_obj=28

  _at $start_row 1
  printf '%b%b %-*s %-*s %-*s %-*s %-*s %s%b' \
    "$C_BOLD" "$C_DCYAN" \
    "$w_ns" "NAMESPACE" "$w_time" "LAST SEEN" "$w_type" "TYPE" \
    "$w_reason" "REASON" "$w_obj" "OBJECT" "MESSAGE" \
    "$C_RESET"
  _eol
  _hline $(( start_row+1 )) 1 "$TERM_COLS" "─" "$C_GRAY"

  local row=$(( start_row+2 ))
  local idx=0
  local filtered=()
  mapfile -t filtered < <(_filtered_lines)

  # Show newest first
  local rev_filtered=()
  for (( i=${#filtered[@]}-1; i>=0; i-- )); do
    rev_filtered+=("${filtered[$i]}")
  done

  for line in "${rev_filtered[@]}"; do
    (( row > TERM_ROWS-1 )) && break
    IFS=$'\t' read -r ns time type reason obj msg <<< "$line"

    local tc="$C_LGRAY"
    [[ "$type" == "Warning" ]] && tc="$C_YELLOW"
    [[ "$type" == "Error"   ]] && tc="$C_RED"

    _at "$row" 1
    (( idx == SELECTED_IDX )) && printf '%b' "$BG_SEL"

    local msg_width=$(( TERM_COLS - w_ns - w_time - w_type - w_reason - w_obj - 10 ))
    (( msg_width < 10 )) && msg_width=10

    printf ' %b%-*s%b %-*s %b%-*s%b %-*s %-*s %b%s%b' \
      "$C_GRAY"  "$w_ns"     "${ns:0:$w_ns}" \
      "$C_RESET" "$w_time"   "${time:0:$w_time}" \
      "$tc"      "$w_type"   "${type:0:$w_type}" \
      "$C_RESET" "$w_reason" "${reason:0:$w_reason}" \
                 "$w_obj"    "${obj:0:$w_obj}" \
      "$C_LGRAY" "${msg:0:$msg_width}" "$C_RESET"

    _eol
    (( idx++ )); (( row++ ))
  done
}

_render_argocd() {
  local start_row=4
  TERM_COLS=$(tput cols 2>/dev/null || echo 120)

  local w_ns=14 w_name=28 w_sync=12 w_health=12 w_target=16 w_path=20

  _at $start_row 1
  printf '%b%b %-*s %-*s %-*s %-*s %-*s %-*s%b' \
    "$C_BOLD" "$C_DCYAN" \
    "$w_ns" "NAMESPACE" "$w_name" "APP NAME" \
    "$w_sync" "SYNC" "$w_health" "HEALTH" \
    "$w_target" "TARGET NS" "$w_path" "PATH" \
    "$C_RESET"
  _eol
  _hline $(( start_row+1 )) 1 "$TERM_COLS" "─" "$C_GRAY"

  local row=$(( start_row+2 ))
  local idx=0
  local filtered=()
  mapfile -t filtered < <(_filtered_lines)

  if [[ ${#filtered[@]} -eq 1 && "${filtered[0]}" == *"not-found"* ]]; then
    _at $(( start_row+4 )) $(( TERM_COLS/2-20 ))
    printf '%bArgoCD CRDs not found — is ArgoCD installed?%b' "$C_GRAY" "$C_RESET"
    return
  fi

  for line in "${filtered[@]}"; do
    (( row > TERM_ROWS-1 )) && break
    IFS=$'\t' read -r ns name sync health repo path target <<< "$line"
    local sc; sc=$(_status_color "$sync")
    local hc; hc=$(_status_color "$health")

    _at "$row" 1
    (( idx == SELECTED_IDX )) && printf '%b' "$BG_SEL"

    printf ' %b%-*s%b %b%-*s%b %b%-*s%b %b%-*s%b %-*s %-*s' \
      "$C_GRAY"  "$w_ns"     "${ns:0:$w_ns}" \
      "$C_RESET" "$C_WHITE"  "$w_name"   "${name:0:$w_name}" \
      "$C_RESET" "$sc"       "$w_sync"   "$sync" \
      "$C_RESET" "$hc"       "$w_health" "$health" \
      "$C_RESET" "$w_target" "${target:0:$w_target}" \
                 "$w_path"   "${path:0:$w_path}"

    printf '%b'; _eol
    (( idx++ )); (( row++ ))
  done
}

_render_certs() {
  local start_row=4
  TERM_COLS=$(tput cols 2>/dev/null || echo 120)

  local w_ns=14 w_name=28 w_ready=7 w_secret=24 w_issuer=20 w_expiry=22

  _at $start_row 1
  printf '%b%b %-*s %-*s %-*s %-*s %-*s %-*s%b' \
    "$C_BOLD" "$C_DCYAN" \
    "$w_ns" "NAMESPACE" "$w_name" "NAME" "$w_ready" "READY" \
    "$w_secret" "SECRET" "$w_issuer" "ISSUER" "$w_expiry" "EXPIRES" \
    "$C_RESET"
  _eol
  _hline $(( start_row+1 )) 1 "$TERM_COLS" "─" "$C_GRAY"

  local row=$(( start_row+2 ))
  local idx=0
  local filtered=()
  mapfile -t filtered < <(_filtered_lines)

  if [[ ${#filtered[@]} -eq 1 && "${filtered[0]}" == *"not-found"* ]]; then
    _at $(( start_row+4 )) $(( TERM_COLS/2-20 ))
    printf '%bcert-manager CRDs not found — is cert-manager installed?%b' "$C_GRAY" "$C_RESET"
    return
  fi

  for line in "${filtered[@]}"; do
    (( row > TERM_ROWS-1 )) && break
    IFS=$'\t' read -r ns name ready secret issuer expiry renew <<< "$line"
    local rc; rc=$(_status_color "$ready")

    # Color expiry based on how soon
    local ec="$C_GREEN"
    if [[ "$expiry" != "<none>" && "$expiry" != "N/A" ]]; then
      local exp_epoch now_epoch days_left
      exp_epoch=$(date -d "$expiry" +%s 2>/dev/null || echo 0)
      now_epoch=$(date +%s)
      days_left=$(( (exp_epoch - now_epoch) / 86400 ))
      (( days_left < 30 )) && ec="$C_YELLOW"
      (( days_left < 7  )) && ec="$C_RED"
    fi

    _at "$row" 1
    (( idx == SELECTED_IDX )) && printf '%b' "$BG_SEL"

    printf ' %b%-*s%b %b%-*s%b %b%-*s%b %-*s %-*s %b%-*s%b' \
      "$C_GRAY"  "$w_ns"     "${ns:0:$w_ns}" \
      "$C_RESET" "$C_WHITE"  "$w_name"   "${name:0:$w_name}" \
      "$C_RESET" "$rc"       "$w_ready"  "$ready" \
      "$C_RESET" "$w_secret" "${secret:0:$w_secret}" \
                 "$w_issuer" "${issuer:0:$w_issuer}" \
      "$ec"      "$w_expiry" "${expiry:0:$w_expiry}" "$C_RESET"

    _eol
    (( idx++ )); (( row++ ))
  done
}

# ── Detail / describe view ─────────────────────────────────

_show_detail() {
  local resource="$1" name="$2" ns="$3"
  DETAIL_MODE=true
  DETAIL_RESOURCE="$resource"
  DETAIL_NAME="$name"
  DETAIL_NS="$ns"

  _clear

  local output
  output=$(kubectl describe "$resource" "$name" -n "$ns" 2>&1)

  local row=1
  TERM_ROWS=$(tput lines 2>/dev/null || echo 40)
  TERM_COLS=$(tput cols  2>/dev/null || echo 120)

  # Header
  _at 1 1
  printf '%b%b kube-dash › describe › %s/%s %b' "$BG_HDR" "$C_CYAN" "$resource" "$name" "$C_RESET"
  _eol

  _at 2 1
  printf '%b%b[q]%b back  %b[l]%b logs  %b[e]%b exec  %b[r]%b restart%b' \
    "$BG_BAR" "$C_CYAN" "$C_RESET$BG_BAR" \
    "$C_CYAN" "$C_RESET$BG_BAR" \
    "$C_CYAN" "$C_RESET$BG_BAR" \
    "$C_CYAN" "$C_RESET$BG_BAR" \
    "$C_RESET"
  _eol

  # Output with syntax coloring
  local line_num=0
  while IFS= read -r line; do
    (( line_num++ ))
    local out_row=$(( line_num + 2 ))
    (( out_row >= TERM_ROWS )) && break

    _at "$out_row" 1

    # Color key lines
    if [[ "$line" =~ ^[A-Z][a-zA-Z]+: ]]; then
      printf '%b%b%s%b' "$C_CYAN" "$C_BOLD" "$line" "$C_RESET"
    elif [[ "$line" =~ "Running"|"Ready"|"True"|"Healthy" ]]; then
      printf '%b%s%b' "$C_GREEN" "$line" "$C_RESET"
    elif [[ "$line" =~ "Error"|"Failed"|"CrashLoop"|"OOM" ]]; then
      printf '%b%s%b' "$C_RED" "$line" "$C_RESET"
    elif [[ "$line" =~ "Warning"|"Pending" ]]; then
      printf '%b%s%b' "$C_YELLOW" "$line" "$C_RESET"
    else
      printf '%s' "$line"
    fi
    _eol
  done <<< "$output"
}

# ── Log viewer ─────────────────────────────────────────────

_show_logs() {
  local pod="$1" ns="$2" container="${3:-}"
  local container_flag=""
  [[ -n "$container" ]] && container_flag="-c $container"

  _clear
  _at 1 1
  printf '%b%b kube-dash › logs › %s %b' "$BG_HDR" "$C_CYAN" "$pod" "$C_RESET"
  _eol
  _at 2 1
  printf '%b%b[q]%b back  %b[f]%b toggle follow%b' \
    "$BG_BAR" "$C_CYAN" "$C_RESET$BG_BAR" "$C_CYAN" "$C_RESET$BG_BAR" "$C_RESET"
  _eol

  # Restore terminal for log display
  tput cnorm 2>/dev/null
  stty echo 2>/dev/null
  stty -cbreak 2>/dev/null || true

  _at 3 1
  if $LOG_FOLLOW; then
    kubectl logs -f --tail=200 $container_flag "$pod" -n "$ns" 2>&1 \
      | head -$(( TERM_ROWS - 3 )) \
      | while IFS= read -r line; do
          if [[ "$line" =~ "ERROR"|"error"|"Error"|"FATAL"|"panic" ]]; then
            printf '%b%s%b\n' "$C_RED" "$line" "$C_RESET"
          elif [[ "$line" =~ "WARN"|"warn"|"WARNING" ]]; then
            printf '%b%s%b\n' "$C_YELLOW" "$line" "$C_RESET"
          else
            printf '%s\n' "$line"
          fi
        done
  else
    kubectl logs --tail=100 $container_flag "$pod" -n "$ns" 2>&1 \
      | while IFS= read -r line; do
          if [[ "$line" =~ "ERROR"|"error"|"Error"|"FATAL"|"panic" ]]; then
            printf '%b%s%b\n' "$C_RED" "$line" "$C_RESET"
          elif [[ "$line" =~ "WARN"|"warn"|"WARNING" ]]; then
            printf '%b%s%b\n' "$C_YELLOW" "$line" "$C_RESET"
          else
            printf '%s\n' "$line"
          fi
        done
  fi

  printf '\n%b--- end of logs — press any key ---%b\n' "$C_GRAY" "$C_RESET"
  read -rsn1

  # Re-init terminal
  stty -echo 2>/dev/null
  stty cbreak 2>/dev/null || true
  tput civis 2>/dev/null
  DETAIL_MODE=false
}

# ── Exec shell ─────────────────────────────────────────────

_exec_shell() {
  local pod="$1" ns="$2"
  _term_restore
  printf '\n%b kube-dash › exec › %s %b\n\n' "$C_CYAN" "$pod" "$C_RESET"
  kubectl exec -it "$pod" -n "$ns" -- sh -c "bash 2>/dev/null || sh" || true
  printf '\n%bReturning to kube-dash...%b\n' "$C_GRAY" "$C_RESET"
  sleep 1
  _term_init
  DETAIL_MODE=false
}

# ── Rolling restart ────────────────────────────────────────

_rolling_restart() {
  local resource="$1" name="$2" ns="$3"
  _at $(( TERM_ROWS/2 )) $(( TERM_COLS/2 - 20 ))
  printf '%bRestarting %s/%s...%b' "$C_YELLOW" "$resource" "$name" "$C_RESET"
  kubectl rollout restart "$resource/$name" -n "$ns" &>/dev/null && \
    { _at $(( TERM_ROWS/2 )) $(( TERM_COLS/2 - 20 ))
      printf '%b✓ Restart initiated for %s%b     ' "$C_GREEN" "$name" "$C_RESET"
    } || \
    { _at $(( TERM_ROWS/2 )) $(( TERM_COLS/2 - 20 ))
      printf '%b✗ Restart failed%b     ' "$C_RED" "$C_RESET"
    }
  sleep 1
}

# ── Delete with confirm ────────────────────────────────────

_delete_resource() {
  local resource="$1" name="$2" ns="$3"
  local mid_row=$(( TERM_ROWS/2 ))
  local mid_col=$(( TERM_COLS/2 - 25 ))

  _at "$mid_row" "$mid_col"
  printf '%b%bDelete %s/%s? [y/N]:%b ' "$BG_BAR" "$C_RED" "$resource" "$name" "$C_RESET"

  tput cnorm 2>/dev/null
  stty echo 2>/dev/null
  local confirm
  read -r confirm
  stty -echo 2>/dev/null
  tput civis 2>/dev/null

  if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
    kubectl delete "$resource" "$name" -n "$ns" &>/dev/null && \
      { _at "$mid_row" "$mid_col"
        printf '%b✓ Deleted %s%b          ' "$C_GREEN" "$name" "$C_RESET"
      }
    sleep 1
    LAST_REFRESH=0  # force refresh
  fi
}

# ── Namespace picker ───────────────────────────────────────

_pick_namespace() {
  local namespaces=()
  mapfile -t namespaces < <(
    kubectl get namespaces -o jsonpath='{.items[*].metadata.name}' 2>/dev/null \
    | tr ' ' '\n' | sort
  )
  namespaces=("all" "${namespaces[@]}")

  _clear
  _at 1 1
  printf '%b%b kube-dash › select namespace %b' "$BG_HDR" "$C_CYAN" "$C_RESET"

  local idx=0
  local count=${#namespaces[@]}

  while true; do
    local row=3
    for i in "${!namespaces[@]}"; do
      _at "$row" 3
      if (( i == idx )); then
        printf '%b%b ▶ %-30s%b' "$BG_SEL" "$C_WHITE" "${namespaces[$i]}" "$C_RESET"
      else
        printf '   %-30s' "${namespaces[$i]}"
      fi
      _eol
      (( row++ ))
    done

    _at $(( row + 1 )) 3
    printf '%b↑↓ navigate  Enter select  q cancel%b' "$C_GRAY" "$C_RESET"

    local key
    IFS= read -rsn1 key
    case "$key" in
      $'\x1b')
        local seq; read -rsn2 -t 0.1 seq || seq=""
        [[ "$seq" == "[A" ]] && (( idx > 0 )) && (( idx-- ))
        [[ "$seq" == "[B" ]] && (( idx < count-1 )) && (( idx++ ))
        ;;
      k) (( idx > 0 )) && (( idx-- )) ;;
      j) (( idx < count-1 )) && (( idx++ )) ;;
      '') CURRENT_NS="${namespaces[$idx]}"; SELECTED_IDX=0; LAST_REFRESH=0; return ;;
      q|Q) return ;;
    esac
  done
}

# ── Context picker ─────────────────────────────────────────

_pick_context() {
  local contexts=()
  mapfile -t contexts < <(kubectl config get-contexts -o name 2>/dev/null | sort)

  _clear
  _at 1 1
  printf '%b%b kube-dash › select context %b' "$BG_HDR" "$C_CYAN" "$C_RESET"

  local idx=0
  local count=${#contexts[@]}

  while true; do
    local row=3
    for i in "${!contexts[@]}"; do
      _at "$row" 3
      if (( i == idx )); then
        printf '%b%b ▶ %-50s%b' "$BG_SEL" "$C_WHITE" "${contexts[$i]}" "$C_RESET"
      else
        local marker="  "
        [[ "${contexts[$i]}" == "$CURRENT_CTX" ]] && marker="${C_GREEN}●${C_RESET}"
        printf '%b %b %-50s' "$marker" "$C_RESET" "${contexts[$i]}"
      fi
      _eol
      (( row++ ))
    done

    local key
    IFS= read -rsn1 key
    case "$key" in
      $'\x1b')
        local seq; read -rsn2 -t 0.1 seq || seq=""
        [[ "$seq" == "[A" ]] && (( idx > 0 )) && (( idx-- ))
        [[ "$seq" == "[B" ]] && (( idx < count-1 )) && (( idx++ ))
        ;;
      k) (( idx > 0 )) && (( idx-- )) ;;
      j) (( idx < count-1 )) && (( idx++ )) ;;
      '')
        kubectl config use-context "${contexts[$idx]}" &>/dev/null
        CURRENT_CTX="${contexts[$idx]}"
        CURRENT_NS="default"
        SELECTED_IDX=0
        LAST_REFRESH=0
        return
        ;;
      q|Q) return ;;
    esac
  done
}

# ── Help screen ────────────────────────────────────────────

_show_help() {
  _clear
  _at 1 1
  printf '%b%b kube-dash v%s › help %b' "$BG_HDR" "$C_CYAN" "$VERSION" "$C_RESET"

  local col1=4 col2=28 row=3

  _help_row() {
    _at "$row" "$col1"
    printf '%b%-22s%b %s' "$C_CYAN" "$1" "$C_RESET" "$2"
    (( row++ ))
  }

  _help_section() {
    (( row++ ))
    _at "$row" "$col1"
    printf '%b%b%s%b' "$C_YELLOW" "$C_BOLD" "$1" "$C_RESET"
    (( row++ ))
    _hline "$row" "$col1" 50 "─" "$C_GRAY"
    (( row++ ))
  }

  _help_section "Navigation"
  _help_row "1-6"          "Switch view (Pods/Deploys/Nodes/Events/ArgoCD/Certs)"
  _help_row "↑↓ / j k"     "Move selection up/down"
  _help_row "Enter"        "Describe / drill into selected resource"
  _help_row "Tab"          "Next view"
  _help_row "Shift-Tab"    "Previous view"
  _help_row "n"            "Pick namespace"
  _help_row "c"            "Pick context"
  _help_row "/"            "Filter current view (type to search)"
  _help_row "Esc"          "Clear filter"

  _help_section "Actions"
  _help_row "l"            "Logs for selected pod"
  _help_row "f"            "Toggle follow logs"
  _help_row "e"            "Exec shell into selected pod"
  _help_row "d"            "Describe selected resource"
  _help_row "r"            "Rolling restart (deploy/sts/ds)"
  _help_row "D"            "Delete resource (with confirmation)"

  _help_section "Views"
  _help_row "1 / p"        "Pods"
  _help_row "2"            "Deployments"
  _help_row "3"            "Nodes"
  _help_row "4"            "Events"
  _help_row "5 / a"        "ArgoCD Applications"
  _help_row "6"            "cert-manager Certificates"

  _help_section "General"
  _help_row "?"            "This help screen"
  _help_row "q / Ctrl-C"   "Quit / go back"
  _help_row "R (capital)"  "Force refresh"

  (( row += 2 ))
  _at "$row" "$col1"
  printf '%bPress any key to return...%b' "$C_GRAY" "$C_RESET"
  read -rsn1
}

# ── Search/filter input ────────────────────────────────────

_input_filter() {
  local mid_row=$(( TERM_ROWS - 2 ))
  tput cnorm 2>/dev/null
  stty echo 2>/dev/null

  _at "$mid_row" 2
  printf '%b/%b' "$C_YELLOW" "$C_RESET"

  local input=""
  local char
  while IFS= read -rsn1 char; do
    case "$char" in
      $'\x1b') break ;;  # ESC — cancel
      '') FILTER="$input"; break ;;  # Enter — apply
      $'\x7f'|$'\b') [[ -n "$input" ]] && input="${input%?}" ;;
      *) input+="$char" ;;
    esac
    _at "$mid_row" 2
    printf '%b/%b%-40s' "$C_YELLOW" "$C_RESET" "$input"
  done

  stty -echo 2>/dev/null
  tput civis 2>/dev/null
}

# ── Get selected resource info ─────────────────────────────

_selected_line() {
  local filtered=()
  mapfile -t filtered < <(_filtered_lines)
  (( ${#filtered[@]} == 0 )) && return 1
  (( SELECTED_IDX >= ${#filtered[@]} )) && SELECTED_IDX=$(( ${#filtered[@]} - 1 ))
  echo "${filtered[$SELECTED_IDX]}"
}

_selected_pod_name() {
  local line; line=$(_selected_line) || return 1
  IFS=$'\t' read -r ns name _ <<< "$line"
  echo "$name"
}

_selected_pod_ns() {
  local line; line=$(_selected_line) || return 1
  IFS=$'\t' read -r ns _ <<< "$line"
  echo "$ns"
}

# ── Main render loop ───────────────────────────────────────

_render_view() {
  # Refresh data if needed
  local now
  now=$(date +%s)
  if (( now - LAST_REFRESH >= REFRESH_INTERVAL )); then
    _refresh_data
  fi

  _draw_header
  _draw_tabs

  case "$CURRENT_VIEW" in
    pods)    _render_pods    ;;
    deploys) _render_deploys ;;
    nodes)   _render_nodes   ;;
    events)  _render_events  ;;
    argocd)  _render_argocd  ;;
    certs)   _render_certs   ;;
  esac

  _draw_statusbar
}

# ── Main input loop ────────────────────────────────────────

_main_loop() {
  _clear

  while true; do
    # Re-read terminal size on each frame
    TERM_ROWS=$(tput lines 2>/dev/null || echo 40)
    TERM_COLS=$(tput cols  2>/dev/null || echo 120)

    if ! $DETAIL_MODE; then
      _render_view
    fi

    # Read input with timeout for auto-refresh
    local key=""
    IFS= read -rsn1 -t "$REFRESH_INTERVAL" key || true

    case "$key" in

      # ── Quit ──────────────────────────────────────────────
      q|Q) exit 0 ;;

      # ── Help ──────────────────────────────────────────────
      '?') _show_help; _clear; DETAIL_MODE=false ;;

      # ── View switching ────────────────────────────────────
      1|p) CURRENT_VIEW="pods";    SELECTED_IDX=0; FILTER=""; LAST_REFRESH=0; DETAIL_MODE=false; _clear ;;
      2)   CURRENT_VIEW="deploys"; SELECTED_IDX=0; FILTER=""; LAST_REFRESH=0; DETAIL_MODE=false; _clear ;;
      3)   CURRENT_VIEW="nodes";   SELECTED_IDX=0; FILTER=""; LAST_REFRESH=0; DETAIL_MODE=false; _clear ;;
      4)   CURRENT_VIEW="events";  SELECTED_IDX=0; FILTER=""; LAST_REFRESH=0; DETAIL_MODE=false; _clear ;;
      5|a) CURRENT_VIEW="argocd";  SELECTED_IDX=0; FILTER=""; LAST_REFRESH=0; DETAIL_MODE=false; _clear ;;
      6)   CURRENT_VIEW="certs";   SELECTED_IDX=0; FILTER=""; LAST_REFRESH=0; DETAIL_MODE=false; _clear ;;

      # ── Tab navigation ────────────────────────────────────
      $'\t')
        local views=("pods" "deploys" "nodes" "events" "argocd" "certs")
        local cur_idx=0
        for i in "${!views[@]}"; do [[ "${views[$i]}" == "$CURRENT_VIEW" ]] && cur_idx=$i; done
        CURRENT_VIEW="${views[$(( (cur_idx+1) % ${#views[@]} ))]}"
        SELECTED_IDX=0; FILTER=""; LAST_REFRESH=0; DETAIL_MODE=false; _clear
        ;;

      # ── Navigation ────────────────────────────────────────
      $'\x1b')
        local seq; read -rsn2 -t 0.1 seq || seq=""
        local filtered=()
        mapfile -t filtered < <(_filtered_lines)
        local count=${#filtered[@]}
        case "$seq" in
          "[A"|"[D") # Up / left arrow
            (( SELECTED_IDX > 0 )) && (( SELECTED_IDX-- ))
            ;;
          "[B"|"[C") # Down / right arrow
            (( SELECTED_IDX < count-1 )) && (( SELECTED_IDX++ ))
            ;;
          "") # Plain ESC — clear filter or back
            if [[ -n "$FILTER" ]]; then
              FILTER=""
            elif $DETAIL_MODE; then
              DETAIL_MODE=false; _clear
            fi
            ;;
          "[Z") # Shift-Tab
            local views=("pods" "deploys" "nodes" "events" "argocd" "certs")
            local cur_idx=0
            for i in "${!views[@]}"; do [[ "${views[$i]}" == "$CURRENT_VIEW" ]] && cur_idx=$i; done
            CURRENT_VIEW="${views[$(( (cur_idx-1+${#views[@]}) % ${#views[@]} ))]}"
            SELECTED_IDX=0; FILTER=""; LAST_REFRESH=0; DETAIL_MODE=false; _clear
            ;;
        esac
        ;;

      k) # Up (vim)
        local filtered=(); mapfile -t filtered < <(_filtered_lines)
        (( SELECTED_IDX > 0 )) && (( SELECTED_IDX-- ))
        ;;
      j) # Down (vim)
        local filtered=(); mapfile -t filtered < <(_filtered_lines)
        local count=${#filtered[@]}
        (( SELECTED_IDX < count-1 )) && (( SELECTED_IDX++ ))
        ;;

      # ── Enter — describe ──────────────────────────────────
      '')
        local line; line=$(_selected_line) || continue
        IFS=$'\t' read -r ns name _ <<< "$line"
        local res="pods"
        [[ "$CURRENT_VIEW" == "deploys" ]] && res="deployment"
        [[ "$CURRENT_VIEW" == "nodes"   ]] && res="node" && ns="default"
        [[ "$CURRENT_VIEW" == "argocd"  ]] && res="application.argoproj.io"
        [[ "$CURRENT_VIEW" == "certs"   ]] && res="certificate.cert-manager.io"
        _show_detail "$res" "$name" "$ns"
        ;;

      # ── Logs ──────────────────────────────────────────────
      l|L)
        if [[ "$CURRENT_VIEW" == "pods" ]]; then
          local pod ns
          pod=$(_selected_pod_name) && ns=$(_selected_pod_ns) && \
            _show_logs "$pod" "$ns"
          _clear; DETAIL_MODE=false
        fi
        ;;

      # ── Exec ──────────────────────────────────────────────
      e|E)
        if [[ "$CURRENT_VIEW" == "pods" ]]; then
          local pod ns
          pod=$(_selected_pod_name) && ns=$(_selected_pod_ns) && \
            _exec_shell "$pod" "$ns"
          _clear
        fi
        ;;

      # ── Describe ──────────────────────────────────────────
      d)
        local line; line=$(_selected_line) || continue
        IFS=$'\t' read -r ns name _ <<< "$line"
        local res="pods"
        [[ "$CURRENT_VIEW" == "deploys" ]] && res="deployment"
        [[ "$CURRENT_VIEW" == "nodes"   ]] && res="node"
        _show_detail "$res" "$name" "$ns"
        ;;

      # ── Rolling restart ───────────────────────────────────
      r)
        if [[ "$CURRENT_VIEW" == "deploys" ]]; then
          local line; line=$(_selected_line) || continue
          IFS=$'\t' read -r ns name _ <<< "$line"
          _rolling_restart "deployment" "$name" "$ns"
          LAST_REFRESH=0
        fi
        ;;

      # ── Delete ────────────────────────────────────────────
      D)
        local line; line=$(_selected_line) || continue
        IFS=$'\t' read -r ns name _ <<< "$line"
        local res="pod"
        [[ "$CURRENT_VIEW" == "deploys" ]] && res="deployment"
        _delete_resource "$res" "$name" "$ns"
        ;;

      # ── Filter ────────────────────────────────────────────
      '/')
        _input_filter
        SELECTED_IDX=0
        ;;

      # ── Namespace picker ──────────────────────────────────
      n|N)
        _pick_namespace
        _clear; DETAIL_MODE=false
        ;;

      # ── Context picker ────────────────────────────────────
      c|C)
        _pick_context
        _clear; DETAIL_MODE=false
        ;;

      # ── Follow logs toggle ────────────────────────────────
      f|F)
        $LOG_FOLLOW && LOG_FOLLOW=false || LOG_FOLLOW=true
        ;;

      # ── Force refresh ─────────────────────────────────────
      R)
        LAST_REFRESH=0
        ;;

      # ── Back from detail ──────────────────────────────────
      $'\x08') # Backspace
        DETAIL_MODE=false; _clear
        ;;

    esac
  done
}

# ── Bootstrap ─────────────────────────────────────────────

_bootstrap() {
  # Check kubectl
  command -v kubectl &>/dev/null || {
    echo "Error: kubectl not found" >&2
    exit 1
  }

  # Get current context and namespace
  CURRENT_CTX=$(kubectl config current-context 2>/dev/null || echo "none")
  CURRENT_NS=$(kubectl config view --minify \
    --output 'jsonpath={..namespace}' 2>/dev/null || echo "")
  [[ -z "$CURRENT_NS" ]] && CURRENT_NS="default"

  # Handle args
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -n|--namespace) CURRENT_NS="$2"; shift 2 ;;
      --context)      kubectl config use-context "$2" &>/dev/null; CURRENT_CTX="$2"; shift 2 ;;
      --readonly)     READONLY=true; shift ;;
      --interval)     REFRESH_INTERVAL="$2"; shift 2 ;;
      -v|--view)      CURRENT_VIEW="$2"; shift 2 ;;
      --help|-h)
        cat <<EOF
Usage: kube-dash [options]
  -n, --namespace <ns>    Start in namespace
  --context <ctx>         Use context
  --interval <secs>       Refresh interval (default: 5)
  -v, --view <view>       Start view: pods|deploys|nodes|events|argocd|certs
  --help                  This help
EOF
        exit 0 ;;
      *) shift ;;
    esac
  done

  _term_init
  _main_loop
}

_bootstrap "$@"
