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

set -o pipefail

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
# Reset foreground only — used on selected rows to keep BG_SEL active
SEL_RST=$'\e[39m'

# ── State ──────────────────────────────────────────────────
CURRENT_NS="default"
CURRENT_CTX=""
CURRENT_VIEW="pods"     # pods | deploys | nodes | events | argocd | certs | generic
GENERIC_RESOURCE=""    # set when CURRENT_VIEW=generic, e.g. "applications"
SELECTED_IDX=0
SCROLL_OFFSET=0         # first visible row in current view
FILTER=""
LAST_REFRESH=0
REFRESH_INTERVAL=5      # seconds (used in watch mode)
LOG_FOLLOW=false
WATCH_MODE=false        # when true, auto-refreshes every REFRESH_INTERVAL seconds
READONLY=false          # when true, blocks destructive actions (delete, restart, exec)

# Per-view load tracking — key is "view:namespace", value=1 when loaded
declare -A VIEW_LOADED=()

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

_term_restore_silent() {
  tput cnorm  2>/dev/null || true  # show cursor
  tput rmcup  2>/dev/null || true  # restore screen
  stty echo   2>/dev/null || true  # restore echo
  stty -cbreak 2>/dev/null || true
}

_term_restore() {
  _term_restore_silent
  echo ""
  echo "  ${C_CYAN}kube-dash exited${C_RESET}"
}

trap '_term_restore; exit 0' EXIT INT TERM

# ── Input drain ────────────────────────────────────────────
# Flushes any bytes already sitting in the terminal input buffer.
# Called before every blocking read in the main loop so that keys
# pressed during rendering / kubectl calls never bleed through.
_drain_input() {
  local _junk
  while IFS= read -rsn1 -t 0.05 _junk 2>/dev/null; do :; done
}

# ── Drawing primitives ─────────────────────────────────────

# Move cursor to row, col (1-indexed)
_at() { printf '\e[%d;%dH' "$1" "$2"; }

# Clear from cursor to end of line
_eol() { printf '\e[K'; }

# Clear entire screen and home cursor
_clear() { printf '\e[2J\e[H'; }

# Draw a horizontal line
_hline() {
  local row=$1 col=$2 width=$3 char="${4:--}" color="${5:-$C_GRAY}"
  _at "$row" "$col"
  printf '%b%s%b' "$color" "$(printf '%*s' "$width" '' | tr ' ' "$char")" "$C_RESET"
}

# Draw a box
_box() {
  local r=$1 c=$2 h=$3 w=$4 color="${5:-$C_GRAY}"
  local i
  # Top
  _at "$r" "$c"
  printf '%b+%s+%b' "$color" "$(printf '%*s' $(( w-2 )) '' | tr ' ' '-')" "$C_RESET"
  # Sides
  for (( i=1; i<h-1; i++ )); do
    _at $(( r+i )) "$c"
    printf '%b|%b' "$color" "$C_RESET"
    _at $(( r+i )) $(( c+w-1 ))
    printf '%b|%b' "$color" "$C_RESET"
  done
  # Bottom
  _at $(( r+h-1 )) "$c"
  printf '%b+%s+%b' "$color" "$(printf '%*s' $(( w-2 )) '' | tr ' ' '-')" "$C_RESET"
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
  printf '\e[48;5;235m%-*s\e[0m' "$TERM_COLS" ""
  _at 2 1

  # View label map
  local view_label
  case "$CURRENT_VIEW" in
    pods)       view_label="Pods"        ;;
    deploys)    view_label="Deployments" ;;
    nodes)      view_label="Nodes"       ;;
    events)     view_label="Events"      ;;
    argocd)     view_label="ArgoCD"      ;;
    certs)      view_label="Certs"       ;;
    secrets)    view_label="Secrets"     ;;
    services)   view_label="Services"    ;;
    helm)       view_label="Helm"        ;;
    configmaps) view_label="ConfigMaps"  ;;
    pvcs)       view_label="PVCs"        ;;
    ingresses)  view_label="Ingresses"   ;;
    jobs)       view_label="Jobs"        ;;
    cronjobs)   view_label="CronJobs"    ;;
    hpa)        view_label="HPA"         ;;
    namespaces) view_label="Namespaces"  ;;
    generic)    view_label="${GENERIC_RESOURCE:-generic}" ;;
  esac

  # Active view highlighted
  printf '\e[48;5;235m \e[0m\e[48;5;51m\e[38;5;232m\e[1m %s \e[0m\e[48;5;235m' "$view_label"
  printf '\e[38;5;240m|\e[0m\e[48;5;235m'

  # Hint (always present, k9s-like compact wording on narrow widths)
  if (( TERM_COLS < 95 )); then
    printf '\e[38;5;240m  \e[38;5;51m|\e[38;5;240m : view\e[0m\e[48;5;235m'
  else
    printf '\e[38;5;240m press \e[38;5;51m:\e[38;5;240m to switch view\e[0m\e[48;5;235m'
  fi

  # Filter indicator
  if [[ -n "$FILTER" ]]; then
    local filter_disp="$FILTER"
    (( ${#filter_disp} > 20 )) && filter_disp="${filter_disp:0:17}..."
    printf '  \e[38;5;220m/%s\e[0m\e[48;5;235m' "$filter_disp"
  fi

  # Staleness / watch mode indicator
  local now elapsed stale_str stale_color
  now=$(date +%s)
  elapsed=$(( now - LAST_REFRESH ))

  if $WATCH_MODE; then
    # Pulse between two states using elapsed seconds for a blink effect
    if (( elapsed % 2 == 0 )); then
      stale_str=" WATCH ${REFRESH_INTERVAL}s"
      stale_color='\e[38;5;208m'   # orange — bright
    else
      stale_str=" watch ${REFRESH_INTERVAL}s"
      stale_color='\e[38;5;130m'   # orange — dim
    fi
  elif (( LAST_REFRESH == 0 )); then
    stale_str=" no data yet"
    stale_color='\e[38;5;196m'
  elif (( elapsed < 60 )); then
    stale_str=" updated ${elapsed}s ago"
    stale_color='\e[38;5;240m'
  elif (( elapsed < 300 )); then
    stale_str=" updated $((elapsed/60))m ago"
    stale_color='\e[38;5;220m'
  else
    stale_str=" stale $((elapsed/60))m — press R"
    stale_color='\e[38;5;196m'
  fi
  # Keep right-side status visible without clobbering the left view label/hint.
  if (( TERM_COLS < 110 )) && [[ "$stale_str" == *"press R"* ]]; then
    stale_str=" stale $((elapsed/60))m"
  fi
  if (( TERM_COLS < 92 )) && [[ "$stale_str" == *"updated"* ]]; then
    stale_str=" ${elapsed}s"
  fi

  local stale_len=${#stale_str}
  (( stale_len > TERM_COLS - 2 )) && stale_str=" ${stale_str:0:$(( TERM_COLS - 3 ))}"
  stale_len=${#stale_str}
  local stale_col=$(( TERM_COLS - stale_len + 1 ))
  (( stale_col < 26 )) && stale_col=26
  _at 2 "$stale_col"
  printf '\e[48;5;235m%b%s\e[0m' "$stale_color" "$stale_str"
}

# ── Status bar ─────────────────────────────────────────────

_draw_statusbar() {
  TERM_COLS=$(tput cols 2>/dev/null || echo 120)
  TERM_ROWS=$(tput lines 2>/dev/null || echo 40)

  # Separator line above footer
  _at $(( TERM_ROWS - 1 )) 1
  printf '\e[48;5;235m%-*s\e[0m' "$TERM_COLS" ""
  _at $(( TERM_ROWS - 1 )) 1
  printf '\e[38;5;240m%s\e[0m' "$(printf '%*s' "$TERM_COLS" '' | tr ' ' '-')"

  # Footer key bar
  _at "$TERM_ROWS" 1
  printf '%b%-*s%b' "$BG_BAR" "$TERM_COLS" "" "$C_RESET"
  _at "$TERM_ROWS" 2

  # Helper to print a key hint
  local k="$C_CYAN" r="$C_RESET"

  if $DETAIL_MODE; then
    # Inside describe pager (avoid wrap on narrow terminals)
    if (( TERM_COLS < 110 )); then
      printf '%b[q]%b back  %b[↑↓/j/k]%b scroll  %b[g/G]%b top/btm' \
        "$k" "$r" "$k" "$r" "$k" "$r"
    else
      printf '%b[q]%b back  %b[↑↓/j/k]%b scroll  %b[g/G]%b top/bottom  %b[l]%b logs  %b[e]%b exec  %b[r]%b restart' \
        "$k" "$r" "$k" "$r" "$k" "$r" "$k" "$r" "$k" "$r" "$k" "$r"
    fi
  else
    # Main list footer (width-aware so line never wraps)
    local watch_color="$C_CYAN"
    $WATCH_MODE && watch_color="$C_ORANGE"

    if (( TERM_COLS < 105 )); then
      if [[ "$CURRENT_VIEW" == "secrets" ]]; then
        printf '%b[x]%b decode  %b[w]%b watch  %b[/]%b filter  %b[:]%b view  %b[n]%b ns  %b[q]%b quit' \
          "$k" "$r" "$watch_color" "$r" "$k" "$r" "$k" "$r" "$k" "$r" "$k" "$r"
      else
        printf '%b[w]%b watch  %b[/]%b filter  %b[:]%b view  %b[n]%b ns  %b[C]%b ctx  %b[q]%b quit' \
          "$watch_color" "$r" "$k" "$r" "$k" "$r" "$k" "$r" "$k" "$r" "$k" "$r"
      fi
    elif (( TERM_COLS < 140 )); then
      if [[ "$CURRENT_VIEW" == "pods" ]]; then
        printf '%b[l]%b logs  %b[e]%b exec  %b[r]%b restart  %b[D]%b delete  %b[/]%b filter  %b[:]%b view  %b[n]%b ns  %b[C]%b ctx  %b[q]%b quit' \
          "$k" "$r" "$k" "$r" "$k" "$r" "$C_RED" "$r" "$k" "$r" "$k" "$r" "$k" "$r" "$k" "$r" "$k" "$r"
      elif [[ "$CURRENT_VIEW" == "secrets" ]]; then
        printf '%b[x]%b decode  %b[w]%b watch  %b[↑↓/j/k]%b nav  %b[Enter]%b describe  %b[/]%b filter  %b[:]%b view  %b[n]%b ns  %b[q]%b quit' \
          "$k" "$r" "$watch_color" "$r" "$k" "$r" "$k" "$r" "$k" "$r" "$k" "$r" "$k" "$r" "$k" "$r"
      else
        printf '%b[w]%b watch  %b[↑↓/j/k]%b nav  %b[Enter]%b describe  %b[/]%b filter  %b[:]%b view  %b[n]%b ns  %b[q]%b quit' \
          "$watch_color" "$r" "$k" "$r" "$k" "$r" "$k" "$r" "$k" "$r" "$k" "$r" "$k" "$r"
      fi
    else
      if [[ "$CURRENT_VIEW" == "pods" ]]; then
        printf '%b[l]%b logs  %b[e]%b exec  %b[v]%b prev-logs  %b[t]%b top  %b[f]%b fwd  %b[r]%b restart  %b[D]%b delete  %b[w]%b watch  %b[:]%b view  %b[/]%b filter  %b[n]%b ns  %b[C]%b ctx  %b[R]%b refresh  %b[?]%b help  %b[q]%b quit' \
          "$k" "$r" "$k" "$r" "$k" "$r" "$k" "$r" "$k" "$r" "$k" "$r" "$C_RED" "$r" "$watch_color" "$r" "$k" "$r" "$k" "$r" "$k" "$r" "$k" "$r" "$k" "$r" "$k" "$r" "$k" "$r"
      elif [[ "$CURRENT_VIEW" == "secrets" ]]; then
        printf '%b[x]%b decode  %b[w]%b watch  %b[:]%b view  %b[↑↓/j/k]%b nav  %b[Enter]%b describe  %b[/]%b filter  %b[n]%b ns  %b[C]%b ctx  %b[R]%b refresh  %b[?]%b help  %b[q]%b quit' \
          "$k" "$r" "$watch_color" "$r" "$k" "$r" "$k" "$r" "$k" "$r" "$k" "$r" "$k" "$r" "$k" "$r" "$k" "$r" "$k" "$r"
      else
        printf '%b[w]%b watch  %b[:]%b view  %b[↑↓/j/k]%b nav  %b[Enter]%b describe  %b[/]%b filter  %b[n]%b ns  %b[C]%b ctx  %b[R]%b refresh  %b[?]%b help  %b[q]%b quit' \
          "$watch_color" "$r" "$k" "$r" "$k" "$r" "$k" "$r" "$k" "$r" "$k" "$r" "$k" "$r" "$k" "$r" "$k" "$r"
      fi
    fi
  fi

  # Ensure rest of line is blank in case previous frame had longer text.
  _eol
}

_confirm_quit() {
  TERM_ROWS=$(tput lines 2>/dev/null || echo 40)
  TERM_COLS=$(tput cols  2>/dev/null || echo 120)

  local msg="Quit kube-dash? [y/N]"
  local row=$(( TERM_ROWS / 2 ))
  local col=$(( (TERM_COLS - ${#msg}) / 2 ))
  (( col < 2 )) && col=2

  _at "$row" 1
  printf '%b%-*s%b' "$BG_BAR" "$TERM_COLS" "" "$C_RESET"
  _at "$row" "$col"
  printf '%b%s%b' "$C_YELLOW" "$msg" "$C_RESET"
  _eol

  _drain_input
  local key=""
  IFS= read -rsn1 key
  case "$key" in
    y|Y) return 0 ;;
    *)   return 1 ;;
  esac
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

_human_age() {
  local ts="$1"
  [[ -z "$ts" || "$ts" == "<none>" ]] && { printf 'n/a'; return; }

  local now epoch diff
  now=$(date +%s)
  epoch=$(date -d "$ts" +%s 2>/dev/null || true)

  if [[ -z "$epoch" ]]; then
    printf '%s' "${ts:0:10}"
    return
  fi

  diff=$(( now - epoch ))
  (( diff < 0 )) && diff=0

  if (( diff < 60 )); then
    printf '%ds' "$diff"
  elif (( diff < 3600 )); then
    printf '%dm' $(( diff / 60 ))
  elif (( diff < 86400 )); then
    printf '%dh' $(( diff / 3600 ))
  else
    printf '%dd' $(( diff / 86400 ))
  fi
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
'NODE:.spec.nodeName,'\
'OWNERKIND:.metadata.ownerReferences[0].kind,'\
'OWNERNAME:.metadata.ownerReferences[0].name,'\
'PODIP:.status.podIP' \
      2>/dev/null \
    | awk '{
        # Count ready containers
        split($3, a, ","); ready=0; total=0
        for (i in a) { total++; if (a[i]=="true") ready++ }
        # Sum restarts
        split($5, b, ","); restarts=0
        for (i in b) { restarts += b[i]+0 }
        owner="-"
        if ($8!="" && $8!="<none>") {
          owner=$8
          if ($9!="" && $9!="<none>") owner=owner "/" $9
        }
        ip=$10
        if (ip=="" || ip=="<none>") ip="-"
        printf "%s\t%s\t%d/%d\t%s\t%d\t%s\t%s\t%s\t%s\n", $1,$2,ready,total,$4,restarts,$6,$7,owner,ip
      }' \
    | sort -k4,4
  )

  # Convert RFC3339 timestamps to human ages (k9s-like: 45s/12m/3h/5d)
  local i line ns name ready status restarts age node owner ip
  local sep=$'\t'
  for i in "${!DATA_LINES[@]}"; do
    line="${DATA_LINES[$i]}"
    IFS=$'\t' read -r ns name ready status restarts age node owner ip <<< "$line"
    age=$(_human_age "$age")
    DATA_LINES[$i]="${ns}${sep}${name}${sep}${ready}${sep}${status}${sep}${restarts}${sep}${age}${sep}${node}${sep}${owner}${sep}${ip}"
  done
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
        printf "%s\t%s\t%s/%s\t%s\t%s\n", $1,$2,ready,desired,status,$7
      }'
  )

  # Convert RFC3339 timestamps to human ages (k9s-like: 45s/12m/3h/5d)
  local i line ns name ready status age
  local sep=$'\t'
  for i in "${!DATA_LINES[@]}"; do
    line="${DATA_LINES[$i]}"
    IFS=$'\t' read -r ns name ready status age <<< "$line"
    age=$(_human_age "$age")
    DATA_LINES[$i]="${ns}${sep}${name}${sep}${ready}${sep}${status}${sep}${age}"
  done
}

_fetch_nodes() {
  mapfile -t DATA_LINES < <(
    kubectl get nodes \
      --no-headers \
      -o custom-columns=\
'NAME:.metadata.name,'\
'STATUS:.status.conditions[-1].type,'\
'ROLE:.metadata.labels.node-role\.kubernetes\.io/control-plane,'\
'VERSION:.status.nodeInfo.kubeletVersion,'\
'OS:.status.nodeInfo.operatingSystem,'\
'ARCH:.status.nodeInfo.architecture,'\
'AGE:.metadata.creationTimestamp' \
      2>/dev/null \
    | awk '{
        role=$3; if (role=="<none>"||role=="") role="worker"
        else role="control-plane"
        printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n", $1,$2,role,$4,$5,$6,$7
      }'
  )
}

_fetch_events() {
  local ns_flag
  [[ "$CURRENT_NS" == "all" ]] && ns_flag="-A" || ns_flag="-n $CURRENT_NS"

  if command -v python3 &>/dev/null; then
    # python3 path — handles spaces/tabs in message cleanly
    mapfile -t DATA_LINES < <(
      kubectl get events $ns_flag \
        --sort-by='.lastTimestamp' \
        -o json \
        2>/dev/null \
      | python3 -c "
import json, sys
data = json.load(sys.stdin)
items = data.get('items', [])
for ev in items[-50:]:
    ns     = ev.get('metadata', {}).get('namespace', '')
    last   = (ev.get('lastTimestamp') or ev.get('eventTime') or '')[:19]
    etype  = ev.get('type', '')
    reason = ev.get('reason', '')
    obj    = ev.get('involvedObject', {}).get('name', '')
    msg    = ev.get('message', '').replace('\n', ' ').replace('\t', ' ')
    print('\t'.join([ns, last, etype, reason, obj, msg]))
" 2>/dev/null \
      || true
    )
  else
    # awk fallback — uses jsonpath so message field is last and complete
    mapfile -t DATA_LINES < <(
      kubectl get events $ns_flag \
        --sort-by='.lastTimestamp' \
        --no-headers \
        -o custom-columns=\
'NS:.metadata.namespace,'\
'LAST:.lastTimestamp,'\
'TYPE:.type,'\
'REASON:.reason,'\
'OBJ:.involvedObject.name,'\
'MSG:.message' \
        2>/dev/null \
      | tail -50 \
      | while IFS= read -r evline; do
          # Grab first 5 fields, treat rest as message
          ns=$(echo "$evline"    | awk '{print $1}')
          last=$(echo "$evline"  | awk '{print $2}')
          type=$(echo "$evline"  | awk '{print $3}')
          reason=$(echo "$evline"| awk '{print $4}')
          obj=$(echo "$evline"   | awk '{print $5}')
          msg=$(echo "$evline"   | awk '{$1=$2=$3=$4=$5=""; print substr($0,6)}')
          printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$ns" "${last:0:19}" "$type" "$reason" "$obj" "$msg"
        done \
      || true
    )
  fi
}

_fetch_argocd() {
  if command -v python3 &>/dev/null; then
    mapfile -t DATA_LINES < <(
      kubectl get applications.argoproj.io -A -o json 2>/dev/null \
      | python3 -c "
import json, sys
data = json.load(sys.stdin)
for app in data.get('items', []):
    m   = app.get('metadata', {})
    sp  = app.get('spec', {})
    st  = app.get('status', {})
    ns     = m.get('namespace', '')
    name   = m.get('name', '')
    sync   = st.get('sync', {}).get('status', 'Unknown')
    health = st.get('health', {}).get('status', 'Unknown')
    src    = sp.get('source') or (sp.get('sources') or [{}])[0]
    repo   = src.get('repoURL', '')
    path   = src.get('path', src.get('chart', ''))
    target = sp.get('destination', {}).get('namespace', '')
    print('\t'.join([ns, name, sync, health, repo, path, target]))
" 2>/dev/null \
      || echo "argocd-ns	not-found	N/A	N/A	N/A	N/A	N/A"
    )
  else
    mapfile -t DATA_LINES < <(
      kubectl get applications.argoproj.io -A \
        --no-headers \
        -o custom-columns=\
'NAMESPACE:.metadata.namespace,'\
'NAME:.metadata.name,'\
'SYNC:.status.sync.status,'\
'HEALTH:.status.health.status,'\
'TARGET:.spec.destination.namespace' \
        2>/dev/null \
      | awk '{ printf "%s\t%s\t%s\t%s\tN/A\tN/A\t%s\n",$1,$2,$3,$4,$5 }' \
      || echo "argocd-ns	not-found	N/A	N/A	N/A	N/A	N/A"
    )
  fi
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

_fetch_secrets() {
  local ns_flag
  [[ "$CURRENT_NS" == "all" ]] && ns_flag="-A" || ns_flag="-n $CURRENT_NS"

  mapfile -t DATA_LINES < <(
    kubectl get secrets $ns_flag \
      --no-headers \
      -o custom-columns=\
'NAMESPACE:.metadata.namespace,'\
'NAME:.metadata.name,'\
'TYPE:.type,'\
'DATA:.data,'\
'AGE:.metadata.creationTimestamp' \
      2>/dev/null \
    | awk '{
        # Count data keys — field 4 is the data map, count colons as proxy
        n = split($4, a, ":")
        keys = (n > 1) ? n-1 : 0
        printf "%s\t%s\t%s\t%d\t%s\n", $1,$2,$3,keys,$5
      }'
  )
}

_fetch_services() {
  local ns_flag
  [[ "$CURRENT_NS" == "all" ]] && ns_flag="-A" || ns_flag="-n $CURRENT_NS"

  mapfile -t DATA_LINES < <(
    kubectl get services $ns_flag \
      --no-headers \
      -o custom-columns=\
'NAMESPACE:.metadata.namespace,'\
'NAME:.metadata.name,'\
'TYPE:.spec.type,'\
'CLUSTER-IP:.spec.clusterIP,'\
'EXTERNAL-IP:.status.loadBalancer.ingress[0].ip,'\
'PORT:.spec.ports[0].port,'\
'AGE:.metadata.creationTimestamp' \
      2>/dev/null \
    | awk '{
        eip=$5; if(eip=="<none>"||eip=="") eip="-"
        printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n",$1,$2,$3,$4,eip,$6,$7
      }'
  )
}

_fetch_helm() {
  local ns_flag
  [[ "$CURRENT_NS" == "all" ]] && ns_flag="--all-namespaces" || ns_flag="-n $CURRENT_NS"

  # helm list outputs tab-separated: name namespace revision updated status chart app_version
  mapfile -t DATA_LINES < <(
    helm list $ns_flag \
      --output table \
      --no-headers \
      2>/dev/null \
    | awk '{
        printf "%s\t%s\t%s\t%s\t%s\t%s\n", $1,$2,$3,$5,$6,$7
      }' \
    || echo "N/A	N/A	N/A	N/A	N/A	N/A"
  )
}

_fetch_configmaps() {
  local ns_flag
  [[ "$CURRENT_NS" == "all" ]] && ns_flag="-A" || ns_flag="-n $CURRENT_NS"

  if command -v python3 &>/dev/null; then
    mapfile -t DATA_LINES < <(
      kubectl get configmaps $ns_flag -o json 2>/dev/null \
      | python3 -c "
import json, sys
data = json.load(sys.stdin)
for cm in data.get('items', []):
    ns   = cm.get('metadata', {}).get('namespace', '')
    name = cm.get('metadata', {}).get('name', '')
    keys = len(cm.get('data') or {}) + len(cm.get('binaryData') or {})
  age  = cm.get('metadata', {}).get('creationTimestamp', '')
  if not ns or not name:
    continue
    print('\t'.join([ns, name, str(keys), age]))
" 2>/dev/null || true
    )
  else
    # awk fallback — just get name/ns/age, count keys separately
    mapfile -t DATA_LINES < <(
      kubectl get configmaps $ns_flag --no-headers \
        -o custom-columns=\
'NAMESPACE:.metadata.namespace,'\
'NAME:.metadata.name,'\
'KEYS:.metadata.annotations.kubectl\.kubernetes\.io/last-applied-configuration,'\
'AGE:.metadata.creationTimestamp' \
        2>/dev/null \
      | awk '{printf "%s\t%s\t%s\t%s\n",$1,$2,0,$4}'
    )
  fi

  # Normalize rows to: ns\tname\tkeys\tage(human). Drop malformed lines.
  local i line ns name keys age _extra
  local sep=$'\t'
  local cleaned=()
  for i in "${!DATA_LINES[@]}"; do
    line="${DATA_LINES[$i]}"
    IFS=$'\t' read -r ns name keys age _extra <<< "$line"

    # Namespace/name must exist and namespace must look like a valid K8s namespace.
    [[ -z "$ns" || -z "$name" ]] && continue
    [[ ! "$ns" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] && continue

    keys="${keys//[^0-9]/}"
    keys="${keys:-0}"
    age=$(_human_age "$age")

    cleaned+=("${ns}${sep}${name}${sep}${keys}${sep}${age}")
  done
  DATA_LINES=("${cleaned[@]}")
}

_fetch_pvcs() {
  local ns_flag
  [[ "$CURRENT_NS" == "all" ]] && ns_flag="-A" || ns_flag="-n $CURRENT_NS"
  mapfile -t DATA_LINES < <(
    kubectl get pvc $ns_flag --no-headers \
      -o custom-columns=\
'NAMESPACE:.metadata.namespace,'\
'NAME:.metadata.name,'\
'STATUS:.status.phase,'\
'VOLUME:.spec.volumeName,'\
'CAPACITY:.status.capacity.storage,'\
'ACCESS:.spec.accessModes[0],'\
'STORAGECLASS:.spec.storageClassName,'\
'AGE:.metadata.creationTimestamp' \
      2>/dev/null \
    | awk '{printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n",$1,$2,$3,$4,$5,$6,$7,$8}'
  )
}

_fetch_ingresses() {
  local ns_flag
  [[ "$CURRENT_NS" == "all" ]] && ns_flag="-A" || ns_flag="-n $CURRENT_NS"
  mapfile -t DATA_LINES < <(
    kubectl get ingresses $ns_flag --no-headers \
      -o custom-columns=\
'NAMESPACE:.metadata.namespace,'\
'NAME:.metadata.name,'\
'CLASS:.spec.ingressClassName,'\
'HOSTS:.spec.rules[0].host,'\
'ADDRESS:.status.loadBalancer.ingress[0].ip,'\
'PORTS:.spec.tls[0].hosts,'\
'AGE:.metadata.creationTimestamp' \
      2>/dev/null \
    | awk '{printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n",$1,$2,$3,$4,$5,$6,$7}'
  )
}

_fetch_jobs() {
  local ns_flag
  [[ "$CURRENT_NS" == "all" ]] && ns_flag="-A" || ns_flag="-n $CURRENT_NS"
  mapfile -t DATA_LINES < <(
    kubectl get jobs $ns_flag --no-headers \
      -o custom-columns=\
'NAMESPACE:.metadata.namespace,'\
'NAME:.metadata.name,'\
'COMPLETIONS:.status.succeeded,'\
'DESIRED:.spec.completions,'\
'DURATION:.status.startTime,'\
'AGE:.metadata.creationTimestamp' \
      2>/dev/null \
    | awk '{
        succ=$3; des=$4
        if (succ=="<none>") succ=0
        if (des=="<none>") des=1
        status="Running"
        if (succ+0>=des+0) status="Complete"
        printf "%s\t%s\t%s/%s\t%s\t%s\t%s\n",$1,$2,succ,des,status,$5,$6
      }'
  )
}

_fetch_cronjobs() {
  local ns_flag
  [[ "$CURRENT_NS" == "all" ]] && ns_flag="-A" || ns_flag="-n $CURRENT_NS"
  mapfile -t DATA_LINES < <(
    kubectl get cronjobs $ns_flag --no-headers \
      -o custom-columns=\
'NAMESPACE:.metadata.namespace,'\
'NAME:.metadata.name,'\
'SCHEDULE:.spec.schedule,'\
'SUSPEND:.spec.suspend,'\
'ACTIVE:.status.active,'\
'LASTRUN:.status.lastScheduleTime,'\
'AGE:.metadata.creationTimestamp' \
      2>/dev/null \
    | awk '{
        susp=$4; if(susp=="<none>"||susp=="false") susp="No"; else susp="Yes"
        active=$5; if(active=="<none>") active=0
        printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n",$1,$2,$3,susp,active,$6,$7
      }'
  )
}

_fetch_hpa() {
  local ns_flag
  [[ "$CURRENT_NS" == "all" ]] && ns_flag="-A" || ns_flag="-n $CURRENT_NS"
  mapfile -t DATA_LINES < <(
    kubectl get hpa $ns_flag --no-headers \
      -o custom-columns=\
'NAMESPACE:.metadata.namespace,'\
'NAME:.metadata.name,'\
'REFERENCE:.spec.scaleTargetRef.name,'\
'MINPODS:.spec.minReplicas,'\
'MAXPODS:.spec.maxReplicas,'\
'REPLICAS:.status.currentReplicas,'\
'AGE:.metadata.creationTimestamp' \
      2>/dev/null \
    | awk '{printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n",$1,$2,$3,$4,$5,$6,$7}' \
    || echo ""
  )
}

_fetch_namespaces() {
  mapfile -t DATA_LINES < <(
    # Always include "all" as the first option
    echo -e "all\t(all namespaces)\t-"
    kubectl get namespaces \
      --no-headers \
      -o custom-columns=\
'NAME:.metadata.name,'\
'STATUS:.status.phase,'\
'AGE:.metadata.creationTimestamp' \
      2>/dev/null \
    | awk '{printf "%s\t%s\t%s\n",$1,$2,$3}'
  )
}

_fetch_generic() {
  local resource="$GENERIC_RESOURCE"
  local ns_flag
  [[ "$CURRENT_NS" == "all" ]] && ns_flag="-A" || ns_flag="-n $CURRENT_NS"
  # nodes and namespaces are cluster-scoped
  [[ "$resource" == "nodes" || "$resource" == "namespaces" || "$resource" == "crds" ]] && ns_flag=""

  if [[ "$resource" == "replicasets" ]]; then
    mapfile -t DATA_LINES < <(
      kubectl get replicasets $ns_flag \
        --no-headers \
        -o custom-columns=\
'NAMESPACE:.metadata.namespace,'\
'NAME:.metadata.name,'\
'DESIRED:.spec.replicas,'\
'CURRENT:.status.replicas,'\
'READY:.status.readyReplicas,'\
'AGE:.metadata.creationTimestamp' \
        2>/dev/null \
      | awk '{
          d=$3; c=$4; r=$5
          if (d=="<none>" || d=="") d=0
          if (c=="<none>" || c=="") c=0
          if (r=="<none>" || r=="") r=0
          printf "%s\t%s\t%s\t%s\t%s\t%s\n", $1,$2,d,c,r,$6
        }'
    )

    local i line ns name desired current ready age
    local sep=$'\t'
    for i in "${!DATA_LINES[@]}"; do
      line="${DATA_LINES[$i]}"
      IFS=$'\t' read -r ns name desired current ready age <<< "$line"
      age=$(_human_age "$age")
      DATA_LINES[$i]="${ns}${sep}${name}${sep}${desired}${sep}${current}${sep}${ready}${sep}${age}"
    done
    return
  fi

  if [[ "$resource" == "statefulsets" ]]; then
    mapfile -t DATA_LINES < <(
      kubectl get statefulsets $ns_flag \
        --no-headers \
        -o custom-columns=\
'NAMESPACE:.metadata.namespace,'\
'NAME:.metadata.name,'\
'DESIRED:.spec.replicas,'\
'CURRENT:.status.replicas,'\
'READY:.status.readyReplicas,'\
'AGE:.metadata.creationTimestamp' \
        2>/dev/null \
      | awk '{
          d=$3; c=$4; r=$5
          if (d=="<none>" || d=="") d=0
          if (c=="<none>" || c=="") c=0
          if (r=="<none>" || r=="") r=0
          printf "%s\t%s\t%s\t%s\t%s\t%s\n", $1,$2,d,c,r,$6
        }'
    )

    local i line ns name desired current ready age
    local sep=$'\t'
    for i in "${!DATA_LINES[@]}"; do
      line="${DATA_LINES[$i]}"
      IFS=$'\t' read -r ns name desired current ready age <<< "$line"
      age=$(_human_age "$age")
      DATA_LINES[$i]="${ns}${sep}${name}${sep}${desired}${sep}${current}${sep}${ready}${sep}${age}"
    done
    return
  fi

  if [[ "$resource" == "daemonsets" ]]; then
    mapfile -t DATA_LINES < <(
      kubectl get daemonsets $ns_flag \
        --no-headers \
        -o custom-columns=\
'NAMESPACE:.metadata.namespace,'\
'NAME:.metadata.name,'\
'DESIRED:.status.desiredNumberScheduled,'\
'CURRENT:.status.currentNumberScheduled,'\
'READY:.status.numberReady,'\
'UPTODATE:.status.updatedNumberScheduled,'\
'AVAILABLE:.status.numberAvailable,'\
'AGE:.metadata.creationTimestamp' \
        2>/dev/null \
      | awk '{
          d=$3; c=$4; r=$5; u=$6; a=$7
          if (d=="<none>" || d=="") d=0
          if (c=="<none>" || c=="") c=0
          if (r=="<none>" || r=="") r=0
          if (u=="<none>" || u=="") u=0
          if (a=="<none>" || a=="") a=0
          printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", $1,$2,d,c,r,u,a,$8
        }'
    )

    local i line ns name desired current ready uptodate available age
    local sep=$'\t'
    for i in "${!DATA_LINES[@]}"; do
      line="${DATA_LINES[$i]}"
      IFS=$'\t' read -r ns name desired current ready uptodate available age <<< "$line"
      age=$(_human_age "$age")
      DATA_LINES[$i]="${ns}${sep}${name}${sep}${desired}${sep}${current}${sep}${ready}${sep}${uptodate}${sep}${available}${sep}${age}"
    done
    return
  fi

  mapfile -t DATA_LINES < <(
    kubectl get "$resource" $ns_flag \
      --no-headers \
      -o wide \
      2>/dev/null \
    | awk '{
        # Prefix each line with the resource name for context
        $1=$1  # trim leading whitespace
        print
      }'
  )
}

_render_generic() {
  local start_row=4
  TERM_COLS=$(tput cols 2>/dev/null || echo 120)

  if [[ "$GENERIC_RESOURCE" == "replicasets" ]]; then
    local w_ns=14 w_name=34 w_des=8 w_cur=8 w_ready=8 w_age=6

    _at $start_row 1
    printf '%b%b %-*s %-*s %-*s %-*s %-*s %-*s%b' \
      "$C_BOLD" "$C_DCYAN" \
      "$w_ns" "NAMESPACE" "$w_name" "NAME" \
      "$w_des" "DESIRED" "$w_cur" "CURRENT" "$w_ready" "READY" "$w_age" "AGE" \
      "$C_RESET"
    _eol
    _hline $(( start_row+1 )) 1 "$TERM_COLS" "-" "$C_GRAY"

    local row=$(( start_row+2 ))
    local filtered=()
    mapfile -t filtered < <(_filtered_lines)
    local _vis=$(( TERM_ROWS - 4 - start_row ))
    local _end=$(( SCROLL_OFFSET + _vis ))
    (( _end > ${#filtered[@]} )) && _end=${#filtered[@]}

    local idx
    for (( idx=SCROLL_OFFSET; idx<_end; idx++ )); do
      local line="${filtered[$idx]}"
      (( row > TERM_ROWS - 4 )) && break
      IFS=$'\t' read -r ns name desired current ready age <<< "$line"

      _at "$row" 1; _eol; _at "$row" 1
      local _rrst="$C_RESET"
      if (( idx == SELECTED_IDX )); then
        printf '%b' "$BG_SEL"
        _rrst="$SEL_RST$BG_SEL"
      fi

      printf ' %b%-*s%b %b%-*s%b %b%-*s%b %b%-*s%b %b%-*s%b %-*s' \
        "$C_GRAY"  "$w_ns"   "${ns:0:$w_ns}" \
        "$_rrst" "$C_WHITE" "$w_name"  "${name:0:$w_name}" \
        "$_rrst" "$C_WHITE" "$w_des"   "${desired:0:$w_des}" \
        "$_rrst" "$C_WHITE" "$w_cur"   "${current:0:$w_cur}" \
        "$_rrst" "$C_GREEN" "$w_ready" "${ready:0:$w_ready}" \
        "$_rrst" "$w_age"   "${age:0:$w_age}"

      printf '%b' "$_rrst"; _eol; printf '%b' "$C_RESET"
      (( row++ ))
    done

    if (( ${#filtered[@]} == 0 )); then
      _at $(( start_row+4 )) $(( TERM_COLS/2-14 ))
      printf '%bNo replicasets found%b' "$C_GRAY" "$C_RESET"
    fi

    _at $(( TERM_ROWS-2 )) 2
    printf '%b%d replicasets%b' "$C_LGRAY" "${#filtered[@]}" "$C_RESET"
    return
  fi

  if [[ "$GENERIC_RESOURCE" == "statefulsets" ]]; then
    local w_ns=14 w_name=34 w_des=8 w_cur=8 w_ready=8 w_age=6

    _at $start_row 1
    printf '%b%b %-*s %-*s %-*s %-*s %-*s %-*s%b' \
      "$C_BOLD" "$C_DCYAN" \
      "$w_ns" "NAMESPACE" "$w_name" "NAME" \
      "$w_des" "DESIRED" "$w_cur" "CURRENT" "$w_ready" "READY" "$w_age" "AGE" \
      "$C_RESET"
    _eol
    _hline $(( start_row+1 )) 1 "$TERM_COLS" "-" "$C_GRAY"

    local row=$(( start_row+2 ))
    local filtered=()
    mapfile -t filtered < <(_filtered_lines)
    local _vis=$(( TERM_ROWS - 4 - start_row ))
    local _end=$(( SCROLL_OFFSET + _vis ))
    (( _end > ${#filtered[@]} )) && _end=${#filtered[@]}

    local idx
    for (( idx=SCROLL_OFFSET; idx<_end; idx++ )); do
      local line="${filtered[$idx]}"
      (( row > TERM_ROWS - 4 )) && break
      IFS=$'\t' read -r ns name desired current ready age <<< "$line"

      _at "$row" 1; _eol; _at "$row" 1
      local _rrst="$C_RESET"
      if (( idx == SELECTED_IDX )); then
        printf '%b' "$BG_SEL"
        _rrst="$SEL_RST$BG_SEL"
      fi

      printf ' %b%-*s%b %b%-*s%b %b%-*s%b %b%-*s%b %b%-*s%b %-*s' \
        "$C_GRAY"  "$w_ns"   "${ns:0:$w_ns}" \
        "$_rrst" "$C_WHITE" "$w_name"  "${name:0:$w_name}" \
        "$_rrst" "$C_WHITE" "$w_des"   "${desired:0:$w_des}" \
        "$_rrst" "$C_WHITE" "$w_cur"   "${current:0:$w_cur}" \
        "$_rrst" "$C_GREEN" "$w_ready" "${ready:0:$w_ready}" \
        "$_rrst" "$w_age"   "${age:0:$w_age}"

      printf '%b' "$_rrst"; _eol; printf '%b' "$C_RESET"
      (( row++ ))
    done

    if (( ${#filtered[@]} == 0 )); then
      _at $(( start_row+4 )) $(( TERM_COLS/2-15 ))
      printf '%bNo statefulsets found%b' "$C_GRAY" "$C_RESET"
    fi

    _at $(( TERM_ROWS-2 )) 2
    printf '%b%d statefulsets%b' "$C_LGRAY" "${#filtered[@]}" "$C_RESET"
    return
  fi

  if [[ "$GENERIC_RESOURCE" == "daemonsets" ]]; then
    local w_ns=14 w_name=28 w_des=4 w_cur=4 w_ready=5 w_up=8 w_avail=9 w_age=6

    _at $start_row 1
    printf '%b%b %-*s %-*s %-*s %-*s %-*s %-*s %-*s %-*s%b' \
      "$C_BOLD" "$C_DCYAN" \
      "$w_ns" "NAMESPACE" "$w_name" "NAME" \
      "$w_des" "DES" "$w_cur" "CUR" "$w_ready" "READY" \
      "$w_up" "UP-TO-D" "$w_avail" "AVAILABLE" "$w_age" "AGE" \
      "$C_RESET"
    _eol
    _hline $(( start_row+1 )) 1 "$TERM_COLS" "-" "$C_GRAY"

    local row=$(( start_row+2 ))
    local filtered=()
    mapfile -t filtered < <(_filtered_lines)
    local _vis=$(( TERM_ROWS - 4 - start_row ))
    local _end=$(( SCROLL_OFFSET + _vis ))
    (( _end > ${#filtered[@]} )) && _end=${#filtered[@]}

    local idx
    for (( idx=SCROLL_OFFSET; idx<_end; idx++ )); do
      local line="${filtered[$idx]}"
      (( row > TERM_ROWS - 4 )) && break
      IFS=$'\t' read -r ns name desired current ready uptodate available age <<< "$line"

      _at "$row" 1; _eol; _at "$row" 1
      local _rrst="$C_RESET"
      if (( idx == SELECTED_IDX )); then
        printf '%b' "$BG_SEL"
        _rrst="$SEL_RST$BG_SEL"
      fi

      printf ' %b%-*s%b %b%-*s%b %b%-*s%b %b%-*s%b %b%-*s%b %b%-*s%b %b%-*s%b %-*s' \
        "$C_GRAY"  "$w_ns"    "${ns:0:$w_ns}" \
        "$_rrst" "$C_WHITE"  "$w_name"  "${name:0:$w_name}" \
        "$_rrst" "$C_WHITE"  "$w_des"   "${desired:0:$w_des}" \
        "$_rrst" "$C_WHITE"  "$w_cur"   "${current:0:$w_cur}" \
        "$_rrst" "$C_GREEN"  "$w_ready" "${ready:0:$w_ready}" \
        "$_rrst" "$C_WHITE"  "$w_up"    "${uptodate:0:$w_up}" \
        "$_rrst" "$C_WHITE"  "$w_avail" "${available:0:$w_avail}" \
        "$_rrst" "$w_age"    "${age:0:$w_age}"

      printf '%b' "$_rrst"; _eol; printf '%b' "$C_RESET"
      (( row++ ))
    done

    if (( ${#filtered[@]} == 0 )); then
      _at $(( start_row+4 )) $(( TERM_COLS/2-14 ))
      printf '%bNo daemonsets found%b' "$C_GRAY" "$C_RESET"
    fi

    _at $(( TERM_ROWS-2 )) 2
    printf '%b%d daemonsets%b' "$C_LGRAY" "${#filtered[@]}" "$C_RESET"
    return
  fi

  # Title shows resource type
  local ns_hint=""
  if [[ "$CURRENT_NS" == "all" ]]; then
    ns_hint=" -A"
  elif [[ "$GENERIC_RESOURCE" != "nodes" && "$GENERIC_RESOURCE" != "namespaces" && "$GENERIC_RESOURCE" != "crds" ]]; then
    ns_hint=" -n $CURRENT_NS"
  fi

  _at $start_row 1
  printf '%b%b %-s%b' "$C_BOLD" "$C_DCYAN" \
    "$(echo "$GENERIC_RESOURCE" | tr '[:lower:]' '[:upper:]')  (kubectl get $GENERIC_RESOURCE${ns_hint})" \
    "$C_RESET"
  _eol
  _hline $(( start_row+1 )) 1 "$TERM_COLS" "-" "$C_GRAY"

  local row=$(( start_row+2 ))
  local filtered=()
  mapfile -t filtered < <(_filtered_lines)
  local _vis=$(( TERM_ROWS - 4 - start_row ))
  local _end=$(( SCROLL_OFFSET + _vis ))
  (( _end > ${#filtered[@]} )) && _end=${#filtered[@]}

  local idx
  for (( idx=SCROLL_OFFSET; idx<_end; idx++ )); do
    local line="${filtered[$idx]}"
    (( row > TERM_ROWS - 4 )) && break
    _at "$row" 1
    local _rsel="" _rrst="$C_RESET"
    if (( idx == SELECTED_IDX )); then
      printf '%b' "$BG_SEL"
      _rsel="$BG_SEL"
      _rrst="$SEL_RST$BG_SEL"
    fi
    printf ' %b%s%b' "$C_WHITE" "${line:0:$(( TERM_COLS - 2 ))}" "$C_RESET"
    printf '%b' "$_rrst"; _eol; printf '%b' "$C_RESET"
    (( row++ ))
  done

  if (( ${#filtered[@]} == 0 )); then
    _at $(( start_row+4 )) $(( TERM_COLS/2-12 ))
    printf '%bNo %s found%b' "$C_GRAY" "$GENERIC_RESOURCE" "$C_RESET"
  fi
  _at $(( TERM_ROWS-2 )) 2
  printf '%b%d %s%b' "$C_LGRAY" "${#filtered[@]}" "$GENERIC_RESOURCE" "$C_RESET"
}

_refresh_data() {
  case "$CURRENT_VIEW" in
    pods)       _fetch_pods       ;;
    deploys)    _fetch_deploys    ;;
    nodes)      _fetch_nodes      ;;
    events)     _fetch_events     ;;
    argocd)     _fetch_argocd     ;;
    certs)      _fetch_certs      ;;
    secrets)    _fetch_secrets    ;;
    services)   _fetch_services   ;;
    helm)       _fetch_helm       ;;
    configmaps) _fetch_configmaps ;;
    pvcs)       _fetch_pvcs       ;;
    ingresses)  _fetch_ingresses  ;;
    jobs)       _fetch_jobs       ;;
    cronjobs)   _fetch_cronjobs   ;;
    hpa)        _fetch_hpa        ;;
    namespaces) _fetch_namespaces ;;
    generic)    _fetch_generic    ;;
  esac
  LAST_REFRESH=$(date +%s)
  VIEW_LOADED["${CURRENT_VIEW}:${CURRENT_NS}"]=1
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
  TERM_COLS=$(tput cols 2>/dev/null || echo 120)

  # Responsive columns. Prefer keeping quick-win diagnostics visible,
  # then progressively hide less-critical columns on narrow terminals.
  local w_ns=12 w_name=28 w_ready=7 w_status=14 w_restarts=8 w_age=6
  local w_owner=20 w_ip=15 w_node=18
  local show_owner=true show_ip=true show_node=true

  if (( TERM_COLS < 160 )); then
    w_name=24
    w_owner=16
    w_ip=14
    w_node=16
  fi
  if (( TERM_COLS < 142 )); then
    show_owner=false
    w_name=28
  fi
  if (( TERM_COLS < 128 )); then
    show_ip=false
    w_name=30
  fi
  if (( TERM_COLS < 114 )); then
    show_node=false
    w_name=32
  fi
  if (( TERM_COLS < 98 )); then
    show_owner=false
    show_node=false
    w_ip=13
    w_name=26
    w_status=12
    w_restarts=6
  fi
  if (( TERM_COLS < 86 )); then
    show_owner=false
    w_ns=9
    w_name=20
    w_ready=6
    w_status=10
    w_restarts=5
    w_age=5
    w_ip=11
  fi
  if (( TERM_COLS < 74 )); then
    show_ip=false
  fi

  _at $start_row 1
  printf '%b%b ' "$C_BOLD" "$C_DCYAN"
  printf '%-*s ' "$w_ns" "NAMESPACE"
  printf '%-*s ' "$w_name" "NAME"
  printf '%-*s ' "$w_ready" "READY"
  printf '%-*s ' "$w_status" "STATUS"
  printf '%-*s ' "$w_restarts" "RESTARTS"
  printf '%-*s ' "$w_age" "AGE"
  $show_owner && printf '%-*s ' "$w_owner" "OWNER"
  $show_ip && printf '%-*s ' "$w_ip" "POD IP"
  $show_node && printf '%-*s ' "$w_node" "NODE"
  printf '%b' "$C_RESET"
  _eol

  _hline $(( start_row+1 )) 1 "$TERM_COLS" "-" "$C_GRAY"

  local row=$(( start_row + 2 ))
  local idx=0
  local filtered=()
  mapfile -t filtered < <(_filtered_lines)

  local selected_node=""
  if (( ${#filtered[@]} > 0 )); then
    local _sidx=$SELECTED_IDX
    (( _sidx < 0 )) && _sidx=0
    (( _sidx >= ${#filtered[@]} )) && _sidx=$(( ${#filtered[@]} - 1 ))
    local _sel_line="${filtered[$_sidx]}"
    IFS=$'\t' read -r _ _ _ _ _ _ selected_node _ _ <<< "$_sel_line"
  fi

  # Render only the visible window starting at SCROLL_OFFSET
  local visible_count=$(( TERM_ROWS - 4 - start_row ))
  local render_end=$(( SCROLL_OFFSET + visible_count ))
  (( render_end > ${#filtered[@]} )) && render_end=${#filtered[@]}

  for (( idx=SCROLL_OFFSET; idx<render_end; idx++ )); do
    local line="${filtered[$idx]}"
    (( row > TERM_ROWS - 4 )) && break

    IFS=$'\t' read -r ns name ready status restarts age node owner ip <<< "$line"

    local sc
    sc=$(_status_color "$status")

    _at "$row" 1; _eol; _at "$row" 1
    local _rsel="" _rrst="$C_RESET"
    if (( idx == SELECTED_IDX )); then
      printf '%b' "$BG_SEL"
      _rsel="$BG_SEL"
      _rrst="$SEL_RST$BG_SEL"
    fi

    local _restart_color="$C_LGRAY"
    local _restarts_num="${restarts//[^0-9]/}"
    _restarts_num="${_restarts_num:-0}"
    (( _restarts_num > 5 )) && _restart_color="$C_RED"

    local owner_disp="$owner"
    local ip_disp="$ip"
    local node_disp="$node"
    (( ${#owner_disp} > w_owner )) && owner_disp="${owner_disp:0:$(( w_owner - 3 ))}..."
    (( ${#ip_disp} > w_ip )) && ip_disp="${ip_disp:0:$(( w_ip - 3 ))}..."
    (( ${#node_disp} > w_node )) && node_disp="${node_disp:0:$(( w_node - 3 ))}..."

    printf ' %b%-*s%b ' "$C_GRAY" "$w_ns" "${ns:0:$w_ns}" "$_rrst"
    printf '%b%-*s%b ' "$C_WHITE" "$w_name" "${name:0:$w_name}" "$_rrst"
    printf '%b%-*s%b ' "$C_GREEN" "$w_ready" "${ready:0:$w_ready}" "$_rrst"
    printf '%b%-*s%b ' "$sc" "$w_status" "${status:0:$w_status}" "$_rrst"
    printf '%b%-*s%b ' "$_restart_color" "$w_restarts" "${restarts:0:$w_restarts}" "$_rrst"
    printf '%b%-*s%b ' "$C_LGRAY" "$w_age" "${age:0:$w_age}" "$_rrst"
    $show_owner && printf '%b%-*s%b ' "$C_WHITE" "$w_owner" "$owner_disp" "$_rrst"
    $show_ip && printf '%b%-*s%b ' "$C_WHITE" "$w_ip" "$ip_disp" "$_rrst"
    $show_node && printf '%b%-*s%b ' "$C_WHITE" "$w_node" "$node_disp" "$_rrst"

    printf '%b' "$_rrst"; _eol; printf '%b' "$C_RESET"
    (( row++ ))
  done

  # Empty state
  if [[ ${#filtered[@]} -eq 0 ]]; then
    _at $(( start_row + 4 )) $(( TERM_COLS/2 - 10 ))
    printf '%bNo pods found%b' "$C_GRAY" "$C_RESET"
  fi

  # Summary line
  _at $(( TERM_ROWS - 2 )) 2; _eol; _at $(( TERM_ROWS - 2 )) 2
  local total=${#filtered[@]}
  local running=0
  for _l in "${filtered[@]}"; do [[ "$_l" == *"Running"* ]] && (( running++ )) || true; done
  printf '%b%d pods%b  %bRunning: %d%b' "$C_LGRAY" "$total" "$C_RESET" "$C_GREEN" "$running" "$C_RESET"

  if [[ -n "$selected_node" ]]; then
    local base_plain="${total} pods  Running: ${running}"
    local avail=$(( TERM_COLS - 2 - ${#base_plain} - 8 ))
    if (( avail > 6 )); then
      local node_full="$selected_node"
      if (( ${#node_full} > avail )); then
        node_full="...${node_full: -$(( avail - 3 ))}"
      fi
      printf '  %bNode:%b %b%s%b' "$C_GRAY" "$C_RESET" "$C_WHITE" "$node_full" "$C_RESET"
    fi
  fi
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
  _hline $(( start_row+1 )) 1 "$TERM_COLS" "-" "$C_GRAY"

  local row=$(( start_row+2 ))
  local filtered=()
  mapfile -t filtered < <(_filtered_lines)
  local _vis=$(( TERM_ROWS - 4 - start_row ))
  local _end=$(( SCROLL_OFFSET + _vis ))
  (( _end > ${#filtered[@]} )) && _end=${#filtered[@]}

  local idx
  for (( idx=SCROLL_OFFSET; idx<_end; idx++ )); do
    local line="${filtered[$idx]}"
    (( row > TERM_ROWS - 4 )) && break
    IFS=$'\t' read -r ns name ready status age <<< "$line"
    local sc; sc=$(_status_color "$status")

    _at "$row" 1
    local _rsel="" _rrst="$C_RESET"
    if (( idx == SELECTED_IDX )); then
      printf '%b' "$BG_SEL"
      _rsel="$BG_SEL"
      _rrst="$SEL_RST$BG_SEL"
    fi

    printf ' %b%-*s%b %b%-*s%b %b%-*s%b %b%-*s%b %-*s' \
      "$C_GRAY"  "$w_ns"    "$ns" \
      "$_rrst" "$C_WHITE" "$w_name"   "${name:0:$w_name}" \
      "$_rrst" "$C_WHITE" "$w_ready"  "$ready" \
      "$_rrst" "$sc"      "$w_status" "$status" \
      "$_rrst" "$w_age"   "${age:0:$w_age}"

    printf '%b' "$_rrst"; _eol; printf '%b' "$C_RESET"
    (( row++ ))
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
  _hline $(( start_row+1 )) 1 "$TERM_COLS" "-" "$C_GRAY"

  local row=$(( start_row+2 ))
  local filtered=()
  mapfile -t filtered < <(_filtered_lines)
  local _vis=$(( TERM_ROWS - 4 - start_row ))
  local _end=$(( SCROLL_OFFSET + _vis ))
  (( _end > ${#filtered[@]} )) && _end=${#filtered[@]}

  local idx
  for (( idx=SCROLL_OFFSET; idx<_end; idx++ )); do
    local line="${filtered[$idx]}"
    (( row > TERM_ROWS - 4 )) && break
    IFS=$'\t' read -r name status role version arch age <<< "$line"
    local sc; sc=$(_status_color "$status")
    local role_color="$C_CYAN"
    [[ "$role" == "worker" ]] && role_color="$C_LGRAY"

    _at "$row" 1
    local _rsel="" _rrst="$C_RESET"
    if (( idx == SELECTED_IDX )); then
      printf '%b' "$BG_SEL"
      _rsel="$BG_SEL"
      _rrst="$SEL_RST$BG_SEL"
    fi

    printf ' %b%-*s%b %b%-*s%b %b%-*s%b %-*s %-*s %-*s' \
      "$C_WHITE"    "$w_name"   "${name:0:$w_name}" \
      "$_rrst"    "$sc"       "$w_status" "$status" \
      "$_rrst"    "$role_color" "$w_role" "$role" \
      "$_rrst"    "$w_ver"    "${version:0:$w_ver}" \
                    "$w_arch"   "$arch" \
                    "$w_age"    "${age:0:$w_age}"

    printf '%b' "$_rrst"; _eol; printf '%b' "$C_RESET"
    (( row++ ))
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
  _hline $(( start_row+1 )) 1 "$TERM_COLS" "-" "$C_GRAY"

  local row=$(( start_row+2 ))
  local filtered=()
  mapfile -t filtered < <(_filtered_lines)

  # Show newest first
  local rev_filtered=()
  for (( i=${#filtered[@]}-1; i>=0; i-- )); do
    rev_filtered+=("${filtered[$i]}")
  done

  local _vis=$(( TERM_ROWS - 4 - start_row ))
  local _end=$(( SCROLL_OFFSET + _vis ))
  (( _end > ${#rev_filtered[@]} )) && _end=${#rev_filtered[@]}

  local idx
  for (( idx=SCROLL_OFFSET; idx<_end; idx++ )); do
    local line="${rev_filtered[$idx]}"
    (( row > TERM_ROWS - 4 )) && break
    IFS=$'\t' read -r ns time type reason obj msg <<< "$line"

    local tc="$C_LGRAY"
    [[ "$type" == "Warning" ]] && tc="$C_YELLOW"
    [[ "$type" == "Error"   ]] && tc="$C_RED"

    _at "$row" 1; _eol; _at "$row" 1
    local _rsel="" _rrst="$C_RESET"
    if (( idx == SELECTED_IDX )); then
      printf '%b' "$BG_SEL"
      _rsel="$BG_SEL"
      _rrst="$SEL_RST$BG_SEL"
    fi

    local msg_width=$(( TERM_COLS - w_ns - w_time - w_type - w_reason - w_obj - 10 ))
    (( msg_width < 10 )) && msg_width=10

    printf ' %b%-*s%b %-*s %b%-*s%b %-*s %-*s %b%s%b' \
      "$C_GRAY"  "$w_ns"     "${ns:0:$w_ns}" \
      "$_rrst" "$w_time"   "${time:0:$w_time}" \
      "$tc"      "$w_type"   "${type:0:$w_type}" \
      "$_rrst" "$w_reason" "${reason:0:$w_reason}" \
                 "$w_obj"    "${obj:0:$w_obj}" \
      "$C_LGRAY" "${msg:0:$msg_width}" "$_rrst"

    _eol; printf '%b' "$C_RESET"
    (( row++ ))
  done

  if [[ ${#filtered[@]} -eq 0 ]]; then
    _at $(( start_row+4 )) $(( TERM_COLS/2-14 ))
    printf '%bNo events found in namespace: %s%b' "$C_GRAY" "$CURRENT_NS" "$C_RESET"
  fi

  _at $(( TERM_ROWS-2 )) 2
  local warn_count=0
  local total_count=${#filtered[@]}
  for _evline in "${filtered[@]}"; do
    [[ "$_evline" == *"Warning"* ]] && (( warn_count++ )) || true
  done
  printf '%b%d events%b  %bWarnings: %d%b' \
    "$C_LGRAY" "$total_count" "$C_RESET" \
    "$C_YELLOW" "$warn_count" "$C_RESET"
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
  _hline $(( start_row+1 )) 1 "$TERM_COLS" "-" "$C_GRAY"

  local row=$(( start_row+2 ))
  local filtered=()
  mapfile -t filtered < <(_filtered_lines)

  if [[ ${#filtered[@]} -eq 1 && "${filtered[0]}" == *"not-found"* ]]; then
    _at $(( start_row+4 )) $(( TERM_COLS/2-20 ))
    printf '%bArgoCD CRDs not found — is ArgoCD installed?%b' "$C_GRAY" "$C_RESET"
    return
  fi

  local _vis=$(( TERM_ROWS - 4 - start_row ))
  local _end=$(( SCROLL_OFFSET + _vis ))
  (( _end > ${#filtered[@]} )) && _end=${#filtered[@]}

  local idx
  for (( idx=SCROLL_OFFSET; idx<_end; idx++ )); do
    local line="${filtered[$idx]}"
    (( row > TERM_ROWS - 4 )) && break
    IFS=$'\t' read -r ns name sync health repo path target <<< "$line"
    local sc; sc=$(_status_color "$sync")
    local hc; hc=$(_status_color "$health")

    _at "$row" 1
    local _rsel="" _rrst="$C_RESET"
    if (( idx == SELECTED_IDX )); then
      printf '%b' "$BG_SEL"
      _rsel="$BG_SEL"
      _rrst="$SEL_RST$BG_SEL"
    fi

    printf ' %b%-*s%b %b%-*s%b %b%-*s%b %b%-*s%b %-*s %-*s' \
      "$C_GRAY"  "$w_ns"     "${ns:0:$w_ns}" \
      "$_rrst" "$C_WHITE"  "$w_name"   "${name:0:$w_name}" \
      "$_rrst" "$sc"       "$w_sync"   "$sync" \
      "$_rrst" "$hc"       "$w_health" "$health" \
      "$_rrst" "$w_target" "${target:0:$w_target}" \
                 "$w_path"   "${path:0:$w_path}"

    printf '%b' "$_rrst"; _eol; printf '%b' "$C_RESET"
    (( row++ ))
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
  _hline $(( start_row+1 )) 1 "$TERM_COLS" "-" "$C_GRAY"

  local row=$(( start_row+2 ))
  local filtered=()
  mapfile -t filtered < <(_filtered_lines)

  if [[ ${#filtered[@]} -eq 1 && "${filtered[0]}" == *"not-found"* ]]; then
    _at $(( start_row+4 )) $(( TERM_COLS/2-20 ))
    printf '%bcert-manager CRDs not found — is cert-manager installed?%b' "$C_GRAY" "$C_RESET"
    return
  fi

  local _vis=$(( TERM_ROWS - 4 - start_row ))
  local _end=$(( SCROLL_OFFSET + _vis ))
  (( _end > ${#filtered[@]} )) && _end=${#filtered[@]}

  local idx
  for (( idx=SCROLL_OFFSET; idx<_end; idx++ )); do
    local line="${filtered[$idx]}"
    (( row > TERM_ROWS - 4 )) && break
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
    local _rsel="" _rrst="$C_RESET"
    if (( idx == SELECTED_IDX )); then
      printf '%b' "$BG_SEL"
      _rsel="$BG_SEL"
      _rrst="$SEL_RST$BG_SEL"
    fi

    printf ' %b%-*s%b %b%-*s%b %b%-*s%b %-*s %-*s %b%-*s%b' \
      "$C_GRAY"  "$w_ns"     "${ns:0:$w_ns}" \
      "$_rrst" "$C_WHITE"  "$w_name"   "${name:0:$w_name}" \
      "$_rrst" "$rc"       "$w_ready"  "$ready" \
      "$_rrst" "$w_secret" "${secret:0:$w_secret}" \
                 "$w_issuer" "${issuer:0:$w_issuer}" \
      "$ec"      "$w_expiry" "${expiry:0:$w_expiry}" "$_rrst"

    _eol; printf '%b' "$C_RESET"
    (( row++ ))
  done
}

_render_secrets() {
  local start_row=4
  TERM_COLS=$(tput cols 2>/dev/null || echo 120)
  local w_ns=16 w_name=40 w_type=32 w_keys=6 w_age=12

  _at $start_row 1
  printf '%b%b %-*s %-*s %-*s %-*s %-*s%b' \
    "$C_BOLD" "$C_DCYAN" \
    "$w_ns" "NAMESPACE" "$w_name" "NAME" \
    "$w_type" "TYPE" "$w_keys" "KEYS" "$w_age" "AGE" \
    "$_rrst"
  _eol
  _hline $(( start_row+1 )) 1 "$TERM_COLS" "-" "$C_GRAY"

  local row=$(( start_row+2 ))
  local filtered=()
  mapfile -t filtered < <(_filtered_lines)
  local _vis=$(( TERM_ROWS - 4 - start_row ))
  local _end=$(( SCROLL_OFFSET + _vis ))
  (( _end > ${#filtered[@]} )) && _end=${#filtered[@]}

  local idx
  for (( idx=SCROLL_OFFSET; idx<_end; idx++ )); do
    local line="${filtered[$idx]}"
    (( row > TERM_ROWS - 4 )) && break
    IFS=$'\t' read -r ns name type keys age <<< "$line"

    # Color by secret type
    local tc="$C_WHITE"
    [[ "$type" == "kubernetes.io/service-account-token" ]] && tc="$C_GRAY"
    [[ "$type" == "kubernetes.io/tls"                   ]] && tc="$C_CYAN"
    [[ "$type" == "Opaque"                              ]] && tc="$C_YELLOW"
    [[ "$type" == *"helm"*                              ]] && tc="$C_MAGENTA"

    _at "$row" 1
    local _rsel="" _rrst="$C_RESET"
    if (( idx == SELECTED_IDX )); then
      printf '%b' "$BG_SEL"
      _rsel="$BG_SEL"
      _rrst="$SEL_RST$BG_SEL"
    fi

    printf ' %b%-*s%b %b%-*s%b %b%-*s%b %b%-*s%b %-*s' \
      "$C_GRAY"  "$w_ns"   "${ns:0:$w_ns}" \
      "$_rrst" "$C_WHITE" "$w_name" "${name:0:$w_name}" \
      "$_rrst" "$tc"      "$w_type" "${type:0:$w_type}" \
      "$_rrst" "$C_LGRAY" "$w_keys" "${keys}" \
      "$_rrst"            "$w_age"  "${age:0:$w_age}"

    printf '%b' "$_rrst"; _eol; printf '%b' "$C_RESET"
    (( row++ ))
  done

  (( ${#filtered[@]} == 0 )) && {
    _at $(( start_row+4 )) $(( TERM_COLS/2-10 ))
    printf '%bNo secrets found%b' "$C_GRAY" "$C_RESET"
  }

  _at $(( TERM_ROWS-2 )) 2
  printf '%b%d secrets%b' "$C_LGRAY" "${#filtered[@]}" "$C_RESET"
}

_render_services() {
  local start_row=4
  TERM_COLS=$(tput cols 2>/dev/null || echo 120)
  local w_ns=16 w_name=36 w_type=12 w_cip=16 w_eip=16 w_ports=18 w_age=10

  _at $start_row 1
  printf '%b%b %-*s %-*s %-*s %-*s %-*s %-*s %-*s%b' \
    "$C_BOLD" "$C_DCYAN" \
    "$w_ns" "NAMESPACE" "$w_name" "NAME" "$w_type" "TYPE" \
    "$w_cip" "CLUSTER-IP" "$w_eip" "EXTERNAL-IP" \
    "$w_ports" "PORTS" "$w_age" "AGE" \
    "$C_RESET"
  _eol
  _hline $(( start_row+1 )) 1 "$TERM_COLS" "-" "$C_GRAY"

  local row=$(( start_row+2 ))
  local filtered=()
  mapfile -t filtered < <(_filtered_lines)
  local _vis=$(( TERM_ROWS - 4 - start_row ))
  local _end=$(( SCROLL_OFFSET + _vis ))
  (( _end > ${#filtered[@]} )) && _end=${#filtered[@]}

  local idx
  for (( idx=SCROLL_OFFSET; idx<_end; idx++ )); do
    local line="${filtered[$idx]}"
    (( row > TERM_ROWS - 4 )) && break
    IFS=$'\t' read -r ns name type cip eip ports age <<< "$line"

    local tc="$C_WHITE"
    [[ "$type" == "LoadBalancer" ]] && tc="$C_GREEN"
    [[ "$type" == "NodePort"     ]] && tc="$C_YELLOW"
    [[ "$type" == "ExternalName" ]] && tc="$C_CYAN"

    # Truncate plain value first, then colorize — avoids ANSI mid-sequence cuts
    local eip_plain="${eip:-"-"}"
    local eip_color="$C_LGRAY"
    [[ "$eip_plain" != "-" && "$eip_plain" != "<none>" ]] && eip_color="$C_GREEN"

    _at "$row" 1
    local _rsel="" _rrst="$C_RESET"
    if (( idx == SELECTED_IDX )); then
      printf '%b' "$BG_SEL"
      _rsel="$BG_SEL"
      _rrst="$SEL_RST$BG_SEL"
    fi

    printf ' %b%-*s%b %b%-*s%b %b%-*s%b %-*s %b%-*s%b %-*s %-*s' \
      "$C_GRAY"    "$w_ns"    "${ns:0:$w_ns}" \
      "$_rrst"   "$C_WHITE" "$w_name"  "${name:0:$w_name}" \
      "$_rrst"   "$tc"      "$w_type"  "${type:0:$w_type}" \
      "$_rrst"              "$w_cip"   "${cip:0:$w_cip}" \
      "$eip_color"            "$w_eip"   "${eip_plain:0:$w_eip}" \
      "$_rrst"              "$w_ports" "${ports:0:$w_ports}" \
                              "$w_age"   "${age:0:$w_age}"

    printf '%b' "$_rrst"; _eol; printf '%b' "$C_RESET"
    (( row++ ))
  done

  (( ${#filtered[@]} == 0 )) && {
    _at $(( start_row+4 )) $(( TERM_COLS/2-10 ))
    printf '%bNo services found%b' "$C_GRAY" "$C_RESET"
  }

  _at $(( TERM_ROWS-2 )) 2
  printf '%b%d services%b' "$C_LGRAY" "${#filtered[@]}" "$C_RESET"
}

_render_helm() {
  local start_row=4
  TERM_COLS=$(tput cols 2>/dev/null || echo 120)
  local w_name=28 w_ns=16 w_rev=5 w_status=12 w_chart=28 w_appver=12

  _at $start_row 1
  printf '%b%b %-*s %-*s %-*s %-*s %-*s %-*s%b' \
    "$C_BOLD" "$C_DCYAN" \
    "$w_name" "NAME" "$w_ns" "NAMESPACE" "$w_rev" "REV" \
    "$w_status" "STATUS" "$w_chart" "CHART" "$w_appver" "APP VERSION" \
    "$C_RESET"
  _eol
  _hline $(( start_row+1 )) 1 "$TERM_COLS" "-" "$C_GRAY"

  local row=$(( start_row+2 )) idx=0
  local filtered=()
  mapfile -t filtered < <(_filtered_lines)

  if [[ ${#filtered[@]} -eq 1 && "${filtered[0]}" == "N/A"* ]]; then
    _at $(( start_row+4 )) $(( TERM_COLS/2-16 ))
    printf '%bHelm not found or no releases in this namespace%b' "$C_GRAY" "$C_RESET"
    return
  fi

  local deployed=0 failed=0
  local _vis=$(( TERM_ROWS - 4 - start_row ))
  local _end=$(( SCROLL_OFFSET + _vis ))
  (( _end > ${#filtered[@]} )) && _end=${#filtered[@]}

  local idx
  for (( idx=SCROLL_OFFSET; idx<_end; idx++ )); do
    local line="${filtered[$idx]}"
    (( row > TERM_ROWS - 4 )) && break
    IFS=$'\t' read -r name ns rev status chart appver <<< "$line"
    [[ -z "$name" ]] && continue

    local sc="$C_WHITE"
    [[ "$status" == "deployed"   ]] && sc="$C_GREEN"  && (( deployed++ ))
    [[ "$status" == "failed"     ]] && sc="$C_RED"    && (( failed++ ))
    [[ "$status" == "superseded" ]] && sc="$C_GRAY"
    [[ "$status" == "pending"*   ]] && sc="$C_YELLOW"

    _at "$row" 1
    local _rsel="" _rrst="$C_RESET"
    if (( idx == SELECTED_IDX )); then
      printf '%b' "$BG_SEL"
      _rsel="$BG_SEL"
      _rrst="$SEL_RST$BG_SEL"
    fi

    printf ' %b%-*s%b %b%-*s%b %b%-*s%b %b%-*s%b %-*s %-*s' \
      "$C_WHITE"  "$w_name"   "${name:0:$w_name}" \
      "$_rrst"  "$C_YELLOW" "$w_ns"     "${ns:0:$w_ns}" \
      "$_rrst"  "$C_LGRAY"  "$w_rev"    "${rev:0:$w_rev}" \
      "$_rrst"  "$sc"       "$w_status" "${status:0:$w_status}" \
      "$_rrst"              "$w_chart"  "${chart:0:$w_chart}" \
                              "$w_appver" "${appver:0:$w_appver}"

    printf '%b' "$_rrst"; _eol; printf '%b' "$C_RESET"
    (( row++ ))
  done

  (( ${#filtered[@]} == 0 )) && {
    _at $(( start_row+4 )) $(( TERM_COLS/2-10 ))
    printf '%bNo Helm releases found%b' "$C_GRAY" "$C_RESET"
  }

  _at $(( TERM_ROWS-2 )) 2
  printf '%b%d releases%b  %bDeployed: %b%b%d%b  %bFailed: %b%b%d%b' \
    "$C_LGRAY" "${#filtered[@]}" "$C_RESET" \
    "$C_GRAY"  "$C_RESET" "$C_GREEN"  "$deployed" "$C_RESET" \
    "$C_GRAY"  "$C_RESET" "$C_RED"    "$failed"   "$C_RESET"
}

_render_configmaps() {
  local start_row=4
  TERM_COLS=$(tput cols 2>/dev/null || echo 120)
  local w_ns=16 w_name=48 w_keys=6 w_age=12

  _at $start_row 1
  printf '%b%b %-*s %-*s %-*s %-*s%b' \
    "$C_BOLD" "$C_DCYAN" \
    "$w_ns" "NAMESPACE" "$w_name" "NAME" "$w_keys" "KEYS" "$w_age" "AGE" \
    "$C_RESET"
  _eol
  _hline $(( start_row+1 )) 1 "$TERM_COLS" "-" "$C_GRAY"

  local row=$(( start_row+2 ))
  local filtered=(); mapfile -t filtered < <(_filtered_lines)
  local _vis=$(( TERM_ROWS - 4 - start_row ))
  local _end=$(( SCROLL_OFFSET + _vis ))
  (( _end > ${#filtered[@]} )) && _end=${#filtered[@]}

  local idx
  for (( idx=SCROLL_OFFSET; idx<_end; idx++ )); do
    local line="${filtered[$idx]}"
    (( row > TERM_ROWS - 4 )) && break
    IFS=$'\t' read -r ns name keys age <<< "$line"
    local kc="$C_LGRAY"; (( ${keys:-0} > 0 )) && kc="$C_WHITE"
    _at "$row" 1
    local _rsel="" _rrst="$C_RESET"
    if (( idx == SELECTED_IDX )); then
      printf '%b' "$BG_SEL"
      _rsel="$BG_SEL"
      _rrst="$SEL_RST$BG_SEL"
    fi
    printf ' %b%-*s%b %b%-*s%b %b%-*s%b %-*s' \
      "$C_GRAY"  "$w_ns"   "${ns:0:$w_ns}" \
      "$_rrst" "$C_WHITE" "$w_name" "${name:0:$w_name}" \
      "$_rrst" "$kc"     "$w_keys" "${keys:-0}" \
      "$_rrst"           "$w_age"  "${age:0:$w_age}"
    printf '%b' "$_rrst"; _eol; printf '%b' "$C_RESET"
    (( row++ ))
  done
  (( ${#filtered[@]} == 0 )) && { _at $(( start_row+4 )) $(( TERM_COLS/2-10 )); printf '%bNo configmaps found%b' "$C_GRAY" "$C_RESET"; }
  _at $(( TERM_ROWS-2 )) 2
  printf '%b%d configmaps%b' "$C_LGRAY" "${#filtered[@]}" "$C_RESET"
}

_render_pvcs() {
  local start_row=4
  TERM_COLS=$(tput cols 2>/dev/null || echo 120)
  local w_ns=14 w_name=30 w_status=10 w_vol=28 w_cap=8 w_sc=16 w_age=10

  _at $start_row 1
  printf '%b%b %-*s %-*s %-*s %-*s %-*s %-*s %-*s%b' \
    "$C_BOLD" "$C_DCYAN" \
    "$w_ns" "NAMESPACE" "$w_name" "NAME" "$w_status" "STATUS" \
    "$w_vol" "VOLUME" "$w_cap" "CAP" "$w_sc" "STORAGECLASS" "$w_age" "AGE" \
    "$C_RESET"
  _eol
  _hline $(( start_row+1 )) 1 "$TERM_COLS" "-" "$C_GRAY"

  local row=$(( start_row+2 ))
  local filtered=(); mapfile -t filtered < <(_filtered_lines)
  local _vis=$(( TERM_ROWS - 4 - start_row ))
  local _end=$(( SCROLL_OFFSET + _vis ))
  (( _end > ${#filtered[@]} )) && _end=${#filtered[@]}

  local idx
  for (( idx=SCROLL_OFFSET; idx<_end; idx++ )); do
    local line="${filtered[$idx]}"
    (( row > TERM_ROWS - 4 )) && break
    IFS=$'\t' read -r ns name status vol cap access sc age <<< "$line"
    local sc_color; sc_color=$(_status_color "$status")
    _at "$row" 1
    local _rsel="" _rrst="$C_RESET"
    if (( idx == SELECTED_IDX )); then
      printf '%b' "$BG_SEL"
      _rsel="$BG_SEL"
      _rrst="$SEL_RST$BG_SEL"
    fi
    printf ' %b%-*s%b %b%-*s%b %b%-*s%b %-*s %-*s %-*s %-*s' \
      "$C_GRAY"  "$w_ns"     "${ns:0:$w_ns}" \
      "$_rrst" "$C_WHITE"  "$w_name"   "${name:0:$w_name}" \
      "$_rrst" "$sc_color" "$w_status" "${status:0:$w_status}" \
      "$_rrst"             "$w_vol"    "${vol:0:$w_vol}" \
                             "$w_cap"    "${cap:0:$w_cap}" \
                             "$w_sc"     "${sc:0:$w_sc}" \
                             "$w_age"    "${age:0:$w_age}"
    printf '%b' "$_rrst"; _eol; printf '%b' "$C_RESET"
    (( row++ ))
  done
  (( ${#filtered[@]} == 0 )) && { _at $(( start_row+4 )) $(( TERM_COLS/2-10 )); printf '%bNo PVCs found%b' "$C_GRAY" "$C_RESET"; }
  local pending=0
  for _l in "${filtered[@]}"; do [[ "$_l" == *"Pending"* ]] && (( pending++ )) || true; done
  _at $(( TERM_ROWS-2 )) 2
  printf '%b%d PVCs%b  %bPending: %b%b%d%b' \
    "$C_LGRAY" "${#filtered[@]}" "$C_RESET" \
    "$C_GRAY" "$C_RESET" "$C_YELLOW" "$pending" "$C_RESET"
}

_render_ingresses() {
  local start_row=4
  TERM_COLS=$(tput cols 2>/dev/null || echo 120)
  local w_ns=14 w_name=28 w_class=12 w_hosts=30 w_addr=16 w_age=10

  _at $start_row 1
  printf '%b%b %-*s %-*s %-*s %-*s %-*s %-*s%b' \
    "$C_BOLD" "$C_DCYAN" \
    "$w_ns" "NAMESPACE" "$w_name" "NAME" "$w_class" "CLASS" \
    "$w_hosts" "HOSTS" "$w_addr" "ADDRESS" "$w_age" "AGE" \
    "$C_RESET"
  _eol
  _hline $(( start_row+1 )) 1 "$TERM_COLS" "-" "$C_GRAY"

  local row=$(( start_row+2 ))
  local filtered=(); mapfile -t filtered < <(_filtered_lines)
  local _vis=$(( TERM_ROWS - 4 - start_row ))
  local _end=$(( SCROLL_OFFSET + _vis ))
  (( _end > ${#filtered[@]} )) && _end=${#filtered[@]}

  local idx
  for (( idx=SCROLL_OFFSET; idx<_end; idx++ )); do
    local line="${filtered[$idx]}"
    (( row > TERM_ROWS - 4 )) && break
    IFS=$'\t' read -r ns name class hosts addr ports age <<< "$line"
    local ac="$C_LGRAY"; [[ -n "$addr" && "$addr" != "<none>" ]] && ac="$C_GREEN"
    _at "$row" 1
    local _rsel="" _rrst="$C_RESET"
    if (( idx == SELECTED_IDX )); then
      printf '%b' "$BG_SEL"
      _rsel="$BG_SEL"
      _rrst="$SEL_RST$BG_SEL"
    fi
    printf ' %b%-*s%b %b%-*s%b %-*s %b%-*s%b %b%-*s%b %-*s' \
      "$C_GRAY"  "$w_ns"    "${ns:0:$w_ns}" \
      "$_rrst" "$C_WHITE" "$w_name"  "${name:0:$w_name}" \
      "$_rrst"            "$w_class" "${class:0:$w_class}" \
      "$C_CYAN"             "$w_hosts" "${hosts:0:$w_hosts}" \
      "$_rrst" "$ac"      "$w_addr"  "${addr:0:$w_addr}" \
      "$_rrst"            "$w_age"   "${age:0:$w_age}"
    printf '%b' "$_rrst"; _eol; printf '%b' "$C_RESET"
    (( row++ ))
  done
  (( ${#filtered[@]} == 0 )) && { _at $(( start_row+4 )) $(( TERM_COLS/2-10 )); printf '%bNo ingresses found%b' "$C_GRAY" "$C_RESET"; }
  _at $(( TERM_ROWS-2 )) 2
  printf '%b%d ingresses%b' "$C_LGRAY" "${#filtered[@]}" "$C_RESET"
}

_render_jobs() {
  local start_row=4
  TERM_COLS=$(tput cols 2>/dev/null || echo 120)
  local w_ns=14 w_name=36 w_comp=12 w_status=10 w_dur=24 w_age=10

  _at $start_row 1
  printf '%b%b %-*s %-*s %-*s %-*s %-*s %-*s%b' \
    "$C_BOLD" "$C_DCYAN" \
    "$w_ns" "NAMESPACE" "$w_name" "NAME" \
    "$w_comp" "COMPLETIONS" "$w_status" "STATUS" "$w_dur" "STARTED" "$w_age" "AGE" \
    "$C_RESET"
  _eol
  _hline $(( start_row+1 )) 1 "$TERM_COLS" "-" "$C_GRAY"

  local row=$(( start_row+2 ))
  local filtered=(); mapfile -t filtered < <(_filtered_lines)
  local complete=0 failed=0
  local _vis=$(( TERM_ROWS - 4 - start_row ))
  local _end=$(( SCROLL_OFFSET + _vis ))
  (( _end > ${#filtered[@]} )) && _end=${#filtered[@]}

  local idx
  for (( idx=SCROLL_OFFSET; idx<_end; idx++ )); do
    local line="${filtered[$idx]}"
    (( row > TERM_ROWS - 4 )) && break
    IFS=$'\t' read -r ns name comp status dur age <<< "$line"
    local sc="$C_YELLOW"
    [[ "$status" == "Complete" ]] && sc="$C_GREEN"  && (( complete++ ))
    [[ "$status" == "Failed"   ]] && sc="$C_RED"    && (( failed++ ))
    _at "$row" 1
    local _rsel="" _rrst="$C_RESET"
    if (( idx == SELECTED_IDX )); then
      printf '%b' "$BG_SEL"
      _rsel="$BG_SEL"
      _rrst="$SEL_RST$BG_SEL"
    fi
    printf ' %b%-*s%b %b%-*s%b %b%-*s%b %b%-*s%b %-*s %-*s' \
      "$C_GRAY"  "$w_ns"   "${ns:0:$w_ns}" \
      "$_rrst" "$C_WHITE" "$w_name"   "${name:0:$w_name}" \
      "$_rrst" "$C_LGRAY" "$w_comp"   "${comp:0:$w_comp}" \
      "$_rrst" "$sc"      "$w_status" "${status:0:$w_status}" \
      "$_rrst"            "$w_dur"    "${dur:0:$w_dur}" \
                            "$w_age"    "${age:0:$w_age}"
    printf '%b' "$_rrst"; _eol; printf '%b' "$C_RESET"
    (( row++ ))
  done
  (( ${#filtered[@]} == 0 )) && { _at $(( start_row+4 )) $(( TERM_COLS/2-10 )); printf '%bNo jobs found%b' "$C_GRAY" "$C_RESET"; }
  _at $(( TERM_ROWS-2 )) 2
  printf '%b%d jobs%b  %bComplete: %b%b%d%b  %bFailed: %b%b%d%b' \
    "$C_LGRAY" "${#filtered[@]}" "$C_RESET" \
    "$C_GRAY" "$C_RESET" "$C_GREEN" "$complete" "$C_RESET" \
    "$C_GRAY" "$C_RESET" "$C_RED"   "$failed"   "$C_RESET"
}

_render_cronjobs() {
  local start_row=4
  TERM_COLS=$(tput cols 2>/dev/null || echo 120)
  local w_ns=14 w_name=32 w_sched=18 w_susp=8 w_active=8 w_last=22 w_age=10

  _at $start_row 1
  printf '%b%b %-*s %-*s %-*s %-*s %-*s %-*s %-*s%b' \
    "$C_BOLD" "$C_DCYAN" \
    "$w_ns" "NAMESPACE" "$w_name" "NAME" "$w_sched" "SCHEDULE" \
    "$w_susp" "SUSPEND" "$w_active" "ACTIVE" "$w_last" "LAST RUN" "$w_age" "AGE" \
    "$C_RESET"
  _eol
  _hline $(( start_row+1 )) 1 "$TERM_COLS" "-" "$C_GRAY"

  local row=$(( start_row+2 ))
  local filtered=(); mapfile -t filtered < <(_filtered_lines)
  local _vis=$(( TERM_ROWS - 4 - start_row ))
  local _end=$(( SCROLL_OFFSET + _vis ))
  (( _end > ${#filtered[@]} )) && _end=${#filtered[@]}

  local idx
  for (( idx=SCROLL_OFFSET; idx<_end; idx++ )); do
    local line="${filtered[$idx]}"
    (( row > TERM_ROWS - 4 )) && break
    IFS=$'\t' read -r ns name sched susp active last age <<< "$line"
    local sc="$C_WHITE"; [[ "$susp" == "Yes" ]] && sc="$C_YELLOW"
    local ac="$C_LGRAY"; (( ${active:-0} > 0 )) && ac="$C_GREEN"
    _at "$row" 1
    local _rsel="" _rrst="$C_RESET"
    if (( idx == SELECTED_IDX )); then
      printf '%b' "$BG_SEL"
      _rsel="$BG_SEL"
      _rrst="$SEL_RST$BG_SEL"
    fi
    printf ' %b%-*s%b %b%-*s%b %b%-*s%b %b%-*s%b %b%-*s%b %-*s %-*s' \
      "$C_GRAY"  "$w_ns"    "${ns:0:$w_ns}" \
      "$_rrst" "$C_WHITE" "$w_name"   "${name:0:$w_name}" \
      "$_rrst" "$C_CYAN"  "$w_sched"  "${sched:0:$w_sched}" \
      "$_rrst" "$sc"      "$w_susp"   "${susp:0:$w_susp}" \
      "$_rrst" "$ac"      "$w_active" "${active:-0}" \
      "$_rrst"            "$w_last"   "${last:0:$w_last}" \
                            "$w_age"    "${age:0:$w_age}"
    printf '%b' "$_rrst"; _eol; printf '%b' "$C_RESET"
    (( row++ ))
  done
  (( ${#filtered[@]} == 0 )) && { _at $(( start_row+4 )) $(( TERM_COLS/2-10 )); printf '%bNo cronjobs found%b' "$C_GRAY" "$C_RESET"; }
  _at $(( TERM_ROWS-2 )) 2
  printf '%b%d cronjobs%b' "$C_LGRAY" "${#filtered[@]}" "$C_RESET"
}

_render_hpa() {
  local start_row=4
  TERM_COLS=$(tput cols 2>/dev/null || echo 120)
  local w_ns=14 w_name=32 w_ref=24 w_min=6 w_max=6 w_cur=8 w_age=10

  _at $start_row 1
  printf '%b%b %-*s %-*s %-*s %-*s %-*s %-*s %-*s%b' \
    "$C_BOLD" "$C_DCYAN" \
    "$w_ns" "NAMESPACE" "$w_name" "NAME" "$w_ref" "REFERENCE" \
    "$w_min" "MIN" "$w_max" "MAX" "$w_cur" "CURRENT" "$w_age" "AGE" \
    "$C_RESET"
  _eol
  _hline $(( start_row+1 )) 1 "$TERM_COLS" "-" "$C_GRAY"

  local row=$(( start_row+2 ))
  local filtered=(); mapfile -t filtered < <(_filtered_lines)
  local _vis=$(( TERM_ROWS - 4 - start_row ))
  local _end=$(( SCROLL_OFFSET + _vis ))
  (( _end > ${#filtered[@]} )) && _end=${#filtered[@]}

  local idx
  for (( idx=SCROLL_OFFSET; idx<_end; idx++ )); do
    local line="${filtered[$idx]}"
    (( row > TERM_ROWS - 4 )) && break
    IFS=$'\t' read -r ns name ref min max cur age <<< "$line"
    local cc="$C_WHITE"
    (( ${cur:-0} >= ${max:-0} && ${max:-0} > 0 )) && cc="$C_RED"
    (( ${cur:-0} <= ${min:-0} && ${min:-0} > 0 )) && cc="$C_LGRAY"
    _at "$row" 1
    local _rsel="" _rrst="$C_RESET"
    if (( idx == SELECTED_IDX )); then
      printf '%b' "$BG_SEL"
      _rsel="$BG_SEL"
      _rrst="$SEL_RST$BG_SEL"
    fi
    printf ' %b%-*s%b %b%-*s%b %-*s %b%-*s%b %b%-*s%b %b%-*s%b %-*s' \
      "$C_GRAY"  "$w_ns"    "${ns:0:$w_ns}" \
      "$_rrst" "$C_WHITE" "$w_name" "${name:0:$w_name}" \
      "$_rrst"            "$w_ref"  "${ref:0:$w_ref}" \
      "$C_CYAN"             "$w_min"  "${min:0:$w_min}" \
      "$_rrst" "$C_CYAN"  "$w_max"  "${max:0:$w_max}" \
      "$_rrst" "$cc"      "$w_cur"  "${cur:-0}" \
      "$_rrst"            "$w_age"  "${age:0:$w_age}"
    printf '%b' "$_rrst"; _eol; printf '%b' "$C_RESET"
    (( row++ ))
  done
  (( ${#filtered[@]} == 0 )) && { _at $(( start_row+4 )) $(( TERM_COLS/2-10 )); printf '%bNo HPAs found%b' "$C_GRAY" "$C_RESET"; }
  _at $(( TERM_ROWS-2 )) 2
  printf '%b%d HPAs%b' "$C_LGRAY" "${#filtered[@]}" "$C_RESET"
}

_render_namespaces() {
  local start_row=4
  TERM_COLS=$(tput cols 2>/dev/null || echo 120)
  local w_name=24 w_status=22 w_age=12

  _at $start_row 1
  printf '%b%b %-*s %-*s %-*s  %s%b' \
    "$C_BOLD" "$C_DCYAN" \
    "$w_name" "NAME" "$w_status" "STATUS" "$w_age" "AGE" \
    "[Enter] scope all views to namespace" \
    "$C_RESET"
  _eol
  _hline $(( start_row+1 )) 1 "$TERM_COLS" "-" "$C_GRAY"

  local row=$(( start_row+2 ))
  local filtered=(); mapfile -t filtered < <(_filtered_lines)
  local _vis=$(( TERM_ROWS - 4 - start_row ))
  local _end=$(( SCROLL_OFFSET + _vis ))
  (( _end > ${#filtered[@]} )) && _end=${#filtered[@]}

  local idx
  for (( idx=SCROLL_OFFSET; idx<_end; idx++ )); do
    local line="${filtered[$idx]}"
    (( row > TERM_ROWS - 4 )) && break
    IFS=$'\t' read -r name status age <<< "$line"
    local sc; sc=$(_status_color "$status")

    _at "$row" 1
    local _rsel="" _rrst="$C_RESET"
    if (( idx == SELECTED_IDX )); then
      printf '%b' "$BG_SEL"
      _rsel="$BG_SEL"
      _rrst="$SEL_RST$BG_SEL"
    fi

    # Mark active namespace with green bullet — restore bg after if selected
    local nc="$C_WHITE"
    local bullet="  "
    if [[ "$name" == "$CURRENT_NS" ]]; then
      nc="$C_GREEN"
      bullet="${C_GREEN}●${C_RESET}${_rsel} "
    fi
    printf ' %b%b%-*s%b %b%-*s%b %-*s' \
      "$bullet" "$nc"      "$w_name"   "${name:0:$w_name}" \
      "$_rrst" "$sc"     "$w_status" "${status:0:$w_status}" \
      "$_rrst"           "$w_age"    "${age:0:$w_age}"
    printf '%b' "$_rrst"; _eol; printf '%b' "$C_RESET"
    (( row++ ))
  done

  (( ${#filtered[@]} == 0 )) && {
    _at $(( start_row+4 )) $(( TERM_COLS/2-10 ))
    printf '%bNo namespaces found%b' "$C_GRAY" "$C_RESET"
  }
  _at $(( TERM_ROWS-2 )) 2
  printf '%b%d namespaces%b  %bActive: %b%b%s%b' \
    "$C_LGRAY" "${#filtered[@]}" "$C_RESET" \
    "$C_GRAY" "$C_RESET" "$C_GREEN" "$CURRENT_NS" "$C_RESET"
}

_show_top() {
  local target="${1:-pods}"   # pods or nodes
  local ns="$2"

  _term_restore_silent
  printf '\n%b kube-dash › top › %s %b\n\n' "$C_CYAN" "$target" "$C_RESET"

  if ! command -v kubectl &>/dev/null; then
    printf '%bkubectl not found%b\n' "$C_RED" "$C_RESET"
  elif [[ "$target" == "nodes" ]]; then
    kubectl top nodes 2>&1
  else
    local ns_flag="-n $ns"
    [[ "$ns" == "all" || -z "$ns" ]] && ns_flag="-A"
    kubectl top pods $ns_flag 2>&1
  fi

  printf '\n%bPress any key to return...%b' "$C_GRAY" "$C_RESET"
  stty -echo 2>/dev/null; stty cbreak 2>/dev/null
  _drain_input; read -rsn1; _drain_input
  _term_init
}

# ── Prev-logs pager globals ────────────────────────────────
_PL_POD="" _PL_TOTAL=0 _PL_OFFSET=0
declare -a _PL_LINES=()

_render_pl() {
  TERM_ROWS=$(tput lines 2>/dev/null || echo 40)
  TERM_COLS=$(tput cols  2>/dev/null || echo 120)
  local view_h=$(( TERM_ROWS - 3 ))
  _clear
  _at 1 1
  printf '%b%b kube-dash › prev-logs › %s %b' "$BG_HDR" "$C_CYAN" "$_PL_POD" "$C_RESET"; _eol
  _at 2 1
  printf '%b%b[q]%b back  %b[↑↓/j/k]%b scroll  %b[g]%b top  %b[G]%b bottom%b' \
    "$BG_BAR" "$C_CYAN" "$C_RESET$BG_BAR" "$C_CYAN" "$C_RESET$BG_BAR" \
    "$C_CYAN" "$C_RESET$BG_BAR" "$C_CYAN" "$C_RESET$BG_BAR" "$C_RESET"; _eol
  local i
  for (( i=0; i<view_h; i++ )); do
    local li=$(( _PL_OFFSET + i ))
    _at $(( i + 3 )) 1
    if (( li < _PL_TOTAL )); then
      local l="${_PL_LINES[$li]}"
      if   [[ "$l" =~ ERROR|error|Error|FATAL|panic ]]; then printf '%b%s%b' "$C_RED"    "$l" "$C_RESET"
      elif [[ "$l" =~ WARN|warn|WARNING              ]]; then printf '%b%s%b' "$C_YELLOW" "$l" "$C_RESET"
      else printf '%s' "$l"; fi
    fi; _eol
  done
  _at "$TERM_ROWS" 1
  printf '%b%b line %d/%d%b' "$BG_BAR" "$C_GRAY" "$(( _PL_OFFSET+1 ))" "$_PL_TOTAL" "$C_RESET"
}

# ── Previous container logs (crashed pods) ─────────────────

_show_prev_logs() {
  local pod="$1" ns="$2"

  local all_lines=()
  local output
  output=$(kubectl logs --previous --tail=200 "$pod" -n "$ns" 2>&1)

  while IFS= read -r line; do all_lines+=("$line"); done <<< "$output"
  local total_lines=${#all_lines[@]}
  local offset=0

  # Store state in globals so _render_pl (top-level) can access them
  _PL_POD="$pod"
  _PL_LINES=("${all_lines[@]}")
  _PL_TOTAL=$total_lines
  _PL_OFFSET=0

  _render_pl; _drain_input
  while true; do
    local key=""; IFS= read -rsn1 key
    local view_h=$(( TERM_ROWS - 3 ))
    case "$key" in
      q|Q) _clear; return ;;
      g)   _PL_OFFSET=0 ;;
      G)   _PL_OFFSET=$(( _PL_TOTAL - view_h )); (( _PL_OFFSET < 0 )) && _PL_OFFSET=0 ;;
      j)   (( _PL_OFFSET + view_h < _PL_TOTAL )) && (( _PL_OFFSET++ )) ;;
      k)   (( _PL_OFFSET > 0 )) && (( _PL_OFFSET-- )) ;;
      $'\x1b')
        local seq=""; read -rsn2 -t 0.15 seq || seq=""; _drain_input
        case "$seq" in
          "[A") (( _PL_OFFSET > 0 )) && (( _PL_OFFSET-- )) ;;
          "[B") (( _PL_OFFSET + view_h < _PL_TOTAL )) && (( _PL_OFFSET++ )) ;;
          "") _clear; return ;;
        esac ;;
    esac
    _render_pl
  done
}

# ── Port-forward ───────────────────────────────────────────

_port_forward() {
  local resource="$1" name="$2" ns="$3"

  TERM_ROWS=$(tput lines 2>/dev/null || echo 40)
  local mid=$(( TERM_ROWS / 2 ))

  # Ask for local and remote ports
  _at "$mid" 3
  printf '%bLocal port (e.g. 8080): %b' "$C_YELLOW" "$C_RESET"
  tput cnorm 2>/dev/null; stty echo 2>/dev/null
  local local_port; read -r local_port
  stty -echo 2>/dev/null; tput civis 2>/dev/null

  [[ -z "$local_port" ]] && { _drain_input; return; }

  _at $(( mid+1 )) 3
  printf '%bRemote port (e.g. 8080): %b' "$C_YELLOW" "$C_RESET"
  tput cnorm 2>/dev/null; stty echo 2>/dev/null
  local remote_port; read -r remote_port
  stty -echo 2>/dev/null; tput civis 2>/dev/null

  [[ -z "$remote_port" ]] && { _drain_input; return; }

  _at $(( mid+2 )) 3
  printf '%bStarting port-forward %s:%s -> %s:%s ...%b' \
    "$C_CYAN" "$name" "$remote_port" "localhost" "$local_port" "$C_RESET"

  # Run in background, store PID
  kubectl port-forward "$resource/$name" \
    "${local_port}:${remote_port}" \
    -n "$ns" \
    --address 0.0.0.0 \
    &>/tmp/kube-dash-pf.log &
  local pf_pid=$!
  sleep 0.5

  if kill -0 "$pf_pid" 2>/dev/null; then
    _at $(( mid+3 )) 3
    printf '%b✓ Port-forward active (PID %d) — localhost:%s -> %s:%s%b' \
      "$C_GREEN" "$pf_pid" "$local_port" "$name" "$remote_port" "$C_RESET"
    _at $(( mid+4 )) 3
    printf '%b  Stop with: kill %d%b' "$C_GRAY" "$pf_pid" "$C_RESET"
  else
    _at $(( mid+3 )) 3
    printf '%b✗ Port-forward failed — check /tmp/kube-dash-pf.log%b' "$C_RED" "$C_RESET"
  fi

  _at $(( mid+6 )) 3
  printf '%bPress any key to continue...%b' "$C_GRAY" "$C_RESET"
  _drain_input; read -rsn1; _drain_input
  LAST_REFRESH=0
}

# ── Detail / describe view ─────────────────────────────────
# Blocks until the user presses q/Esc, so the main loop never sees
# stray keypresses from inside the describe view (fixes auto-select).

_show_detail() {
  local resource="$1" name="$2" ns="$3"
  DETAIL_RESOURCE="$resource"
  DETAIL_NAME="$name"
  DETAIL_NS="$ns"

  # Fetch once up front
  local output
  output=$(kubectl describe "$resource" "$name" -n "$ns" 2>&1)

  # Split into array of lines for indexed scrolling
  local all_lines=()
  while IFS= read -r line; do
    all_lines+=("$line")
  done <<< "$output"
  local total_lines=${#all_lines[@]}

  local offset=0   # first visible line index

  # ── Inner render ─────────────────────────────────────────
  _render_detail() {
    TERM_ROWS=$(tput lines 2>/dev/null || echo 40)
    TERM_COLS=$(tput cols  2>/dev/null || echo 120)
    local view_h=$(( TERM_ROWS - 3 ))  # rows available for content

    _clear

    # Header
    _at 1 1
    printf '%b%b kube-dash › describe › %b%s/%s%b' \
      "$BG_HDR" "$C_CYAN" "$C_WHITE" "$resource" "$name" "$C_RESET"
    _eol

    # Key bar — show only relevant actions for resource type
    _at 2 1
    if [[ "$resource" == "pods" || "$resource" == "pod" ]]; then
      printf '%b%b[Esc]%b back  %b[↑↓/j/k]%b scroll  %b[g]%b top  %b[G]%b bottom  %b[l]%b logs  %b[e]%b exec  %b[r]%b restart%b' \
        "$BG_BAR" \
        "$C_CYAN" "$C_RESET$BG_BAR" \
        "$C_CYAN" "$C_RESET$BG_BAR" \
        "$C_CYAN" "$C_RESET$BG_BAR" \
        "$C_CYAN" "$C_RESET$BG_BAR" \
        "$C_CYAN" "$C_RESET$BG_BAR" \
        "$C_CYAN" "$C_RESET$BG_BAR" \
        "$C_CYAN" "$C_RESET$BG_BAR" \
        "$C_RESET"
    elif [[ "$resource" == "deployment" ]]; then
      printf '%b%b[Esc]%b back  %b[↑↓/j/k]%b scroll  %b[g]%b top  %b[G]%b bottom  %b[r]%b restart%b' \
        "$BG_BAR" \
        "$C_CYAN" "$C_RESET$BG_BAR" \
        "$C_CYAN" "$C_RESET$BG_BAR" \
        "$C_CYAN" "$C_RESET$BG_BAR" \
        "$C_CYAN" "$C_RESET$BG_BAR" \
        "$C_CYAN" "$C_RESET$BG_BAR" \
        "$C_RESET"
    else
      printf '%b%b[Esc]%b back  %b[↑↓/j/k]%b scroll  %b[g]%b top  %b[G]%b bottom%b' \
        "$BG_BAR" \
        "$C_CYAN" "$C_RESET$BG_BAR" \
        "$C_CYAN" "$C_RESET$BG_BAR" \
        "$C_CYAN" "$C_RESET$BG_BAR" \
        "$C_CYAN" "$C_RESET$BG_BAR" \
        "$C_RESET"
    fi
    _eol

    # Content
    local i
    for (( i=0; i<view_h; i++ )); do
      local li=$(( offset + i ))
      local out_row=$(( i + 3 ))
      _at "$out_row" 1
      if (( li < total_lines )); then
        local line="${all_lines[$li]}"
        if [[ "$line" =~ ^[A-Z][a-zA-Z\ ]*: ]]; then
          printf '%b%b%s%b' "$C_CYAN" "$C_BOLD" "$line" "$C_RESET"
        elif [[ "$line" =~ Running|Ready|True|Healthy|Succeeded ]]; then
          printf '%b%s%b' "$C_GREEN" "$line" "$C_RESET"
        elif [[ "$line" =~ Error|Failed|CrashLoop|OOMKilled ]]; then
          printf '%b%s%b' "$C_RED" "$line" "$C_RESET"
        elif [[ "$line" =~ Warning|Pending ]]; then
          printf '%b%s%b' "$C_YELLOW" "$line" "$C_RESET"
        else
          printf '%s' "$line"
        fi
      fi
      _eol
    done

    # Scroll position indicator in status bar
    _at "$TERM_ROWS" 1
    printf '%b%-*s%b' "$BG_BAR" "$TERM_COLS" "" "$C_RESET"
    _at "$TERM_ROWS" 2
    local pct=0
    (( total_lines > 0 )) && pct=$(( (offset + view_h) * 100 / total_lines ))
    (( pct > 100 )) && pct=100
    printf '%b line %d/%d  %d%%%b' \
      "$C_GRAY" "$(( offset + 1 ))" "$total_lines" "$pct" "$C_RESET"
  }

  # ── Pager input loop ─────────────────────────────────────
  # This loop BLOCKS here — the main loop never receives these keys.
  # Drain first so any keys pressed during the kubectl describe call
  # don't immediately fire an action.
  _render_detail
  _drain_input
  while true; do
    local key=""
    IFS= read -rsn1 key

    case "$key" in
      g)
        # Jump to top
        offset=0
        ;;
      G)
        # Jump to bottom
        local view_h=$(( TERM_ROWS - 3 ))
        offset=$(( total_lines - view_h ))
        (( offset < 0 )) && offset=0
        ;;
      j)
        # Scroll down one line
        local view_h=$(( TERM_ROWS - 3 ))
        (( offset + view_h < total_lines )) && (( offset++ ))
        ;;
      k)
        # Scroll up one line
        (( offset > 0 )) && (( offset-- ))
        ;;
      # Page down — half screen at a time
      'd')
        local view_h=$(( TERM_ROWS - 3 ))
        local half=$(( view_h / 2 ))
        offset=$(( offset + half ))
        (( offset + view_h > total_lines )) && offset=$(( total_lines - view_h ))
        (( offset < 0 )) && offset=0
        ;;
      # Page up — half screen at a time
      'u')
        local half=$(( (TERM_ROWS - 3) / 2 ))
        offset=$(( offset - half ))
        (( offset < 0 )) && offset=0
        ;;
      $'\x1b')
        local seq=""
        read -rsn2 -t 0.15 seq || seq=""
        _drain_input
        local view_h=$(( TERM_ROWS - 3 ))
        case "$seq" in
          "[A") # Up arrow
            (( offset > 0 )) && (( offset-- ))
            ;;
          "[B") # Down arrow
            (( offset + view_h < total_lines )) && (( offset++ ))
            ;;
          "[5") # PgUp (reads one more byte)
            read -rsn1 -t 0.1 _ || true
            offset=$(( offset - view_h ))
            (( offset < 0 )) && offset=0
            ;;
          "[6") # PgDn
            read -rsn1 -t 0.1 _ || true
            offset=$(( offset + view_h ))
            (( offset + view_h > total_lines )) && offset=$(( total_lines - view_h ))
            (( offset < 0 )) && offset=0
            ;;
          "") # Plain ESC — also exit
            DETAIL_MODE=false
            _clear
            return
            ;;
        esac
        ;;
      l|L)
        # Hand off to log viewer if resource is a pod
        if [[ "$resource" == "pods" || "$resource" == "pod" ]]; then
          _show_logs "$name" "$ns"
          _render_detail
        fi
        ;;
      e|E)
        if [[ "$resource" == "pods" || "$resource" == "pod" ]]; then
          _exec_shell "$name" "$ns"
          _render_detail
        fi
        ;;
      r)
        if [[ "$resource" == "deployment" ]]; then
          _rolling_restart "deployment" "$name" "$ns"
          _render_detail
        fi
        ;;
    esac

    _render_detail
  done
}

# ── Log viewer ─────────────────────────────────────────────

_show_logs() {
  local pod="$1" ns="$2" container="${3:-}"
  local container_flag=""
  [[ -n "$container" ]] && container_flag="-c $container"

  # Fetch logs into a local buffer so we do not clobber list view data
  _clear
  _at 1 1
  printf '%b%b kube-dash › logs › %s %b' "$BG_HDR" "$C_CYAN" "$pod" "$C_RESET"
  _eol
  _at 2 1
  printf '%b%b Loading logs...%b' "$BG_BAR" "$C_GRAY" "$C_RESET"
  _eol

  # Capture logs into array
  local tail_lines=200
  local LOG_LINES=()
  mapfile -t LOG_LINES < <(
    kubectl logs --tail=$tail_lines $container_flag "$pod" -n "$ns" 2>&1
  )

  local SCROLL_OFFSET_LOGS=0
  local FILTER_LOGS=""

  # Render logs loop
  _render_logs() {
    _clear
    _at 1 1
    printf '%b%b kube-dash › logs › %s %b' "$BG_HDR" "$C_CYAN" "$pod" "$C_RESET"
    _eol
    _at 2 1
    printf '%b%b[Esc]%b back  %b[↑↓/j/k]%b scroll  %b[/]%b filter  %b[g]%b top  %b[G]%b bottom%b' \
      "$BG_BAR" "$C_CYAN" "$C_RESET$BG_BAR" "$C_CYAN" "$C_RESET$BG_BAR" \
      "$C_CYAN" "$C_RESET$BG_BAR" "$C_CYAN" "$C_RESET$BG_BAR" "$C_CYAN" "$C_RESET$BG_BAR" "$C_RESET"
    _eol

    # Filter indicator
    if [[ -n "$FILTER_LOGS" ]]; then
      _at 2 80
      printf '%b/%s%b' "$C_YELLOW" "$FILTER_LOGS" "$C_RESET"
    fi

    local filtered=()
    if [[ -z "$FILTER_LOGS" ]]; then
      filtered=("${LOG_LINES[@]}")
    else
      local line
      for line in "${LOG_LINES[@]}"; do
        grep -i "$FILTER_LOGS" <<< "$line" &>/dev/null && filtered+=("$line")
      done
    fi

    local view_h=$(( TERM_ROWS - 3 ))
    local total_lines=${#filtered[@]}

    # Clamp scroll offset
    (( SCROLL_OFFSET_LOGS >= total_lines )) && SCROLL_OFFSET_LOGS=$(( total_lines - view_h ))
    (( SCROLL_OFFSET_LOGS < 0 )) && SCROLL_OFFSET_LOGS=0

    # Render visible lines
    local i
    for (( i=0; i<view_h; i++ )); do
      local li=$(( SCROLL_OFFSET_LOGS + i ))
      local out_row=$(( i + 3 ))
      _at "$out_row" 1
      if (( li < total_lines )); then
        local line="${filtered[$li]}"
        if [[ "$line" =~ ERROR|error|Error|FATAL|panic ]]; then
          printf '%b%s%b' "$C_RED" "$line" "$C_RESET"
        elif [[ "$line" =~ WARN|warn|WARNING ]]; then
          printf '%b%s%b' "$C_YELLOW" "$line" "$C_RESET"
        else
          printf '%s' "$line"
        fi
      fi
      _eol
    done

    # Status bar
    _at "$TERM_ROWS" 1
    printf '%b%-*s%b' "$BG_BAR" "$TERM_COLS" "" "$C_RESET"
    _at "$TERM_ROWS" 2
    local pct=0
    (( total_lines > 0 )) && pct=$(( (SCROLL_OFFSET_LOGS + view_h) * 100 / total_lines ))
    (( pct > 100 )) && pct=100
    printf '%b line %d/%d  %d%%%b' \
      "$C_GRAY" "$(( SCROLL_OFFSET_LOGS + 1 ))" "$total_lines" "$pct" "$C_RESET"
  }

  # Prepare for interactive mode
  tput cnorm 2>/dev/null
  stty -echo 2>/dev/null
  stty cbreak 2>/dev/null || true

  _render_logs
  _drain_input

  while true; do
    local key=""
    IFS= read -rsn1 key

    case "$key" in
      g)
        SCROLL_OFFSET_LOGS=0
        ;;
      G)
        local view_h=$(( TERM_ROWS - 3 ))
        local filtered=()
        if [[ -z "$FILTER_LOGS" ]]; then
          filtered=("${LOG_LINES[@]}")
        else
          local line
          for line in "${LOG_LINES[@]}"; do
            grep -i "$FILTER_LOGS" <<< "$line" &>/dev/null && filtered+=("$line")
          done
        fi
        SCROLL_OFFSET_LOGS=$(( ${#filtered[@]} - view_h ))
        (( SCROLL_OFFSET_LOGS < 0 )) && SCROLL_OFFSET_LOGS=0
        ;;
      j)
        local view_h=$(( TERM_ROWS - 3 ))
        local filtered=()
        if [[ -z "$FILTER_LOGS" ]]; then
          filtered=("${LOG_LINES[@]}")
        else
          local line
          for line in "${LOG_LINES[@]}"; do
            grep -i "$FILTER_LOGS" <<< "$line" &>/dev/null && filtered+=("$line")
          done
        fi
        (( SCROLL_OFFSET_LOGS + view_h < ${#filtered[@]} )) && (( SCROLL_OFFSET_LOGS++ ))
        ;;
      k)
        (( SCROLL_OFFSET_LOGS > 0 )) && (( SCROLL_OFFSET_LOGS-- ))
        ;;
      '/')
        _input_filter_logs
        ;;
      $'\x1b')
        local seq=""
        read -rsn2 -t 0.15 seq || seq=""
        _drain_input

        # Plain Esc: go back from logs view
        if [[ -z "$seq" ]]; then
          FILTER_LOGS=""
          DETAIL_MODE=false
          _clear
          return
        fi

        local view_h=$(( TERM_ROWS - 3 ))
        local filtered=()
        if [[ -z "$FILTER_LOGS" ]]; then
          filtered=("${LOG_LINES[@]}")
        else
          local line
          for line in "${LOG_LINES[@]}"; do
            grep -i "$FILTER_LOGS" <<< "$line" &>/dev/null && filtered+=("$line")
          done
        fi
        case "$seq" in
          "[A")
            (( SCROLL_OFFSET_LOGS > 0 )) && (( SCROLL_OFFSET_LOGS-- ))
            ;;
          "[B")
            (( SCROLL_OFFSET_LOGS + view_h < ${#filtered[@]} )) && (( SCROLL_OFFSET_LOGS++ ))
            ;;
          "[5")
            read -rsn1 -t 0.1 _ || true
            SCROLL_OFFSET_LOGS=$(( SCROLL_OFFSET_LOGS - view_h ))
            (( SCROLL_OFFSET_LOGS < 0 )) && SCROLL_OFFSET_LOGS=0
            ;;
          "[6")
            read -rsn1 -t 0.1 _ || true
            SCROLL_OFFSET_LOGS=$(( SCROLL_OFFSET_LOGS + view_h ))
            (( SCROLL_OFFSET_LOGS + view_h > ${#filtered[@]} )) && SCROLL_OFFSET_LOGS=$(( ${#filtered[@]} - view_h ))
            (( SCROLL_OFFSET_LOGS < 0 )) && SCROLL_OFFSET_LOGS=0
            ;;
        esac
        ;;
    esac
    _render_logs
  done
}

# ── Filter input for logs ──────────────────────────────────

_input_filter_logs() {
  tput cnorm 2>/dev/null
  stty echo 2>/dev/null

  _at "$TERM_ROWS" 1
  printf '%b%-*s%b' "$BG_BAR" "$TERM_COLS" "" "$C_RESET"
  _at "$TERM_ROWS" 2
  printf '%b/%b' "$C_YELLOW" "$C_RESET"

  local input=""
  local char
  while IFS= read -rsn1 char; do
    case "$char" in
      $'\x1b') break ;;
      $'\x0a'|$'\r'|'') FILTER_LOGS="$input"; break ;;
      $'\x7f'|$'\b') [[ -n "$input" ]] && input="${input%?}" ;;
      *) input+="$char" ;;
    esac
    _at "$TERM_ROWS" 2
    printf '%b/%b%-40s' "$C_YELLOW" "$C_RESET" "$input"
  done

  stty -echo 2>/dev/null
  tput civis 2>/dev/null
}

# ── Exec shell ─────────────────────────────────────────────

_exec_shell() {
  local pod="$1" ns="$2"

  # Silently restore terminal so the shell feels normal.
  # Do NOT print the exit message — we are coming back.
  _term_restore_silent

  printf '\n%b kube-dash › exec › %s %b\n' "$C_CYAN" "$pod" "$C_RESET"
  printf '%b Tip: type "exit" to return to kube-dash %b\n\n' "$C_GRAY" "$C_RESET"

  # Disable the EXIT/INT/TERM trap for the duration of exec.
  # Otherwise Ctrl-C inside the shell fires _term_restore and
  # prints "kube-dash exited" before we have a chance to recover.
  trap '' INT TERM

  # Try shells in order, showing all output including errors
  local _exec_rc=0
  printf '%b Attempting: kubectl exec -it %s -n %s -- sh %b\n\n' \
    "$C_GRAY" "$pod" "$ns" "$C_RESET"

  kubectl exec -it "$pod" -n "$ns" -- sh
  _exec_rc=$?

  if (( _exec_rc != 0 && _exec_rc != 130 )); then
    printf '\n%b sh failed (exit %d), trying bash... %b\n\n' \
      "$C_YELLOW" "$_exec_rc" "$C_RESET"
    kubectl exec -it "$pod" -n "$ns" -- bash
    _exec_rc=$?
  fi

  if (( _exec_rc != 0 && _exec_rc != 130 )); then
    printf '\n%b bash failed (exit %d) %b\n' \
      "$C_RED" "$_exec_rc" "$C_RESET"
    printf '%b This container may have no shell (distroless/scratch image). %b\n' \
      "$C_YELLOW" "$C_RESET"
    printf '%b Try: kubectl debug -it %s --image=busybox -n %s %b\n' \
      "$C_GRAY" "$pod" "$ns" "$C_RESET"
  fi

  # Restore trap
  trap '_term_restore; exit 0' EXIT INT TERM

  printf '\n%bPress any key to return to kube-dash...%b' "$C_GRAY" "$C_RESET"
  # Use cooked read so the keypress echoes naturally
  stty echo 2>/dev/null || true
  read -rsn1
  stty -echo 2>/dev/null || true

  # Re-initialise TUI
  _term_init
  _drain_input
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
        local seq; read -rsn2 -t 0.15 seq || seq=""
        _drain_input
        [[ "$seq" == "[A" ]] && (( idx > 0 )) && (( idx-- ))
        [[ "$seq" == "[B" ]] && (( idx < count-1 )) && (( idx++ ))
        ;;
      k) (( idx > 0 )) && (( idx-- )) ;;
      j) (( idx < count-1 )) && (( idx++ )) ;;
      '')
        local new_ns="${namespaces[$idx]}"
        if [[ "$new_ns" != "$CURRENT_NS" ]]; then
          CURRENT_NS="$new_ns"
          # Invalidate all view caches — data is now stale for new namespace
          VIEW_LOADED=()
          LAST_REFRESH=0
        fi
        SELECTED_IDX=0
        return ;;
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
        local seq; read -rsn2 -t 0.15 seq || seq=""
        _drain_input
        [[ "$seq" == "[A" ]] && (( idx > 0 )) && (( idx-- ))
        [[ "$seq" == "[B" ]] && (( idx < count-1 )) && (( idx++ ))
        ;;
      k) (( idx > 0 )) && (( idx-- )) ;;
      j) (( idx < count-1 )) && (( idx++ )) ;;
      '')
        kubectl config use-context "${contexts[$idx]}" &>/dev/null
        CURRENT_CTX="${contexts[$idx]}"
        CURRENT_NS="all"
        SELECTED_IDX=0
        VIEW_LOADED=()
        LAST_REFRESH=0
        return
        ;;
      q|Q) return ;;
    esac
  done
}

# ── Help helpers (top-level to avoid set -u nested function issue) ─────────
_help_row() {
  _at "$_help_row_num" "$_help_col1"
  printf '%b%-22s%b %s' "$C_CYAN" "$1" "$C_RESET" "$2"
  _help_row_num=$(( _help_row_num + 1 ))
}

_help_section() {
  _help_row_num=$(( _help_row_num + 1 ))
  _at "$_help_row_num" "$_help_col1"
  printf '%b%b%s%b' "$C_YELLOW" "$C_BOLD" "$1" "$C_RESET"
  _help_row_num=$(( _help_row_num + 1 ))
  _hline "$_help_row_num" "$_help_col1" 50 "-" "$C_GRAY"
  _help_row_num=$(( _help_row_num + 1 ))
}

# ── Help screen ────────────────────────────────────────────

_show_help() {
  _clear
  _at 1 1
  printf '%b%b kube-dash v%s › help %b' "$BG_HDR" "$C_CYAN" "$VERSION" "$C_RESET"

  local col1=4
  _help_row_num=3
  _help_col1=$col1

  _help_section "Navigation"
  _help_row "↑↓ / j k"     "Move selection up/down"
  _help_row "Enter"        "Describe / drill into selected resource"
  _help_row "Tab"          "Next view (cycles all 15)"
  _help_row "Shift-Tab"    "Previous view"
  _help_row "n"            "Pick namespace"
  _help_row "C"            "Pick context"
  _help_row "/"            "Filter current view"
  _help_row "Esc"          "Back to Pods (or clear filter in Pods)"

  _help_section "Actions (Pods)"
  _help_row "l"            "Logs"
  _help_row "L"            "Toggle follow logs"
  _help_row "v"            "Previous logs (crashed container)"
  _help_row "e"            "Exec shell into pod"
  _help_row "t"            "kubectl top (pods or nodes)"
  _help_row "f"            "Port-forward (pods or services)"
  _help_row "r"            "Rolling restart (deployments)"
  _help_row "D"            "Delete resource"
  _help_row "d"            "Describe selected resource"

  _help_section "Actions (Other views)"
  _help_row "x"            "Decode secret (Secrets view)"
  _help_row "f"            "Port-forward (Services view)"
  _help_row "t"            "kubectl top nodes (Nodes view)"

  _help_section "Views — Row 1 (1-9)"
  _help_row "1 / p"        "Pods"
  _help_row "2"            "Deployments"
  _help_row "3"            "Nodes"
  _help_row "4"            "Events (all namespaces)"
  _help_row "5 / a"        "ArgoCD Applications"
  _help_row "6"            "cert-manager Certificates"
  _help_row "7 / s"        "Secrets"
  _help_row "8"            "Services"
  _help_row "9"            "Helm Releases"

  _help_section "Views — Row 2 (: command palette)"
  _help_row ":"              "Open command palette"
  _help_row "po / pod"       "Pods"
  _help_row "dep / deploy"   "Deployments"
  _help_row "no / node"      "Nodes"
  _help_row "ev / event"     "Events"
  _help_row "app"            "ArgoCD Applications"
  _help_row "cert"           "Certificates"
  _help_row "sec / secret"   "Secrets"
  _help_row "svc / service"  "Services"
  _help_row "helm / hr"      "Helm Releases"
  _help_row "cm / configmap" "ConfigMaps"
  _help_row "pvc"            "PVCs"
  _help_row "ing / ingress"  "Ingresses"
  _help_row "ns / namespace" "Namespaces"
  _help_row "job"            "Jobs"
  _help_row "cj / cronjob"   "CronJobs"
  _help_row "hpa"            "HPA"

  _help_section "General"
  _help_row "w"            "Toggle watch mode (auto-refresh every 5s)"
  _help_row "?"            "This help screen"
  _help_row "R"            "Force refresh"
  _help_row "q / Ctrl-C"   "Quit / go back"

  (( _help_row_num += 2 ))
  _at "$_help_row_num" "$_help_col1"
  printf '%bPress any key to return...%b' "$C_GRAY" "$C_RESET"
  _drain_input
  read -rsn1
  _drain_input
}

# ── Command palette (:) ────────────────────────────────────
# Type an alias and jump to that view — just like k9s

# Adjust SCROLL_OFFSET so SELECTED_IDX is always visible
# Adjust SCROLL_OFFSET so SELECTED_IDX is always visible
_clamp_scroll() {
  # Must match the _vis formula used in every renderer:
  # _vis = TERM_ROWS - 4 - start_row, where start_row=4
  # Content rows run from start_row+2 to TERM_ROWS-4 inclusive
  local start_row=4
  local visible=$(( TERM_ROWS - 4 - start_row ))
  (( visible < 1 )) && visible=1
  # Scroll down if selection is below visible window
  if (( SELECTED_IDX >= SCROLL_OFFSET + visible )); then
    SCROLL_OFFSET=$(( SELECTED_IDX - visible + 1 ))
  fi
  # Scroll up if selection is above visible window
  if (( SELECTED_IDX < SCROLL_OFFSET )); then
    SCROLL_OFFSET=$SELECTED_IDX
  fi
  # Never go negative
  (( SCROLL_OFFSET < 0 )) && SCROLL_OFFSET=0
}

# Switch to a view — fetch on first visit, use cache on revisit
_switch_view() {
  local view="$1"
  CURRENT_VIEW="$view"
  SELECTED_IDX=0
  SCROLL_OFFSET=0
  FILTER=""
  DETAIL_MODE=false
  WATCH_MODE=false   # reset watch mode — you were watching the previous view
  # DATA_LINES is a shared buffer across views; always force a refresh
  # when switching so the new renderer never sees stale rows.
  LAST_REFRESH=0
}
# Palette aliases → kubectl resource type (used for generic fetch)
# The rich pre-built views are still on 1-9 keys
declare -A KX_ALIASES=(
  [po]="pods"              [pod]="pods"            [pods]="pods"
  [dep]="deployments"      [deploy]="deployments"  [deploys]="deployments"  [deployment]="deployments"
  [no]="nodes"             [node]="nodes"           [nodes]="nodes"
  [ev]="events"            [event]="events"         [events]="events"
  [app]="applications"     [apps]="applications"    [application]="applications"
  [cert]="certificates"    [certs]="certificates"   [certificate]="certificates"
  [sec]="secrets"          [secret]="secrets"       [secrets]="secrets"
  [svc]="services"         [service]="services"     [services]="services"
  [cm]="configmaps"        [configmap]="configmaps" [configmaps]="configmaps"
  [pvc]="persistentvolumeclaims" [pvcs]="persistentvolumeclaims"
  [ing]="ingresses"        [ingress]="ingresses"    [ingresses]="ingresses"
  [job]="jobs"             [jobs]="jobs"
  [cj]="cronjobs"          [cronjob]="cronjobs"     [cronjobs]="cronjobs"
  [ns]="namespaces"        [namespace]="namespaces" [namespaces]="namespaces"
  [hpa]="horizontalpodautoscalers"
  [rs]="replicasets"       [replicaset]="replicasets"
  [sts]="statefulsets"     [statefulset]="statefulsets"
  [ds]="daemonsets"        [daemonset]="daemonsets"
  [sa]="serviceaccounts"   [serviceaccount]="serviceaccounts"
  [rb]="rolebindings"      [role]="roles"
  [crd]="crds"
)

# Display order and labels for the palette suggestions
declare -A KX_LABELS=(
  [po]="pods"               [dep]="deployments"      [no]="nodes"
  [ev]="events"             [app]="applications"     [cert]="certificates"
  [sec]="secrets"           [svc]="services"         [cm]="configmaps"
  [pvc]="persistentvolumeclaims" [ing]="ingresses"   [job]="jobs"
  [cj]="cronjobs"           [ns]="namespaces"        [hpa]="horizontalpodautoscalers"
  [rs]="replicasets"        [sts]="statefulsets"     [ds]="daemonsets"
  [sa]="serviceaccounts"    [rb]="rolebindings"      [crd]="crds"
)

KX_ALIAS_DISPLAY=(po dep no ev app cert sec svc cm pvc ing job cj hpa ns rs sts ds sa rb crd)
_draw_palette() {
  local inp="$1"
  TERM_ROWS=$(tput lines 2>/dev/null || echo 40)
  TERM_COLS=$(tput cols  2>/dev/null || echo 120)

  local prompt_row=$(( TERM_ROWS - 1 ))
  local hint_row=$TERM_ROWS

  local first_alias=""
  local first_label=""
  local match_count=0
  local ak
  local hint_list=""

  for ak in "${KX_ALIAS_DISPLAY[@]}"; do
    local target="${KX_ALIASES[$ak]:-}"
    local label="${KX_LABELS[$ak]:-$target}"
    [[ -z "$target" ]] && continue
    if [[ -z "$inp" || "$ak" == "$inp"* || "$label" == "$inp"* || "$target" == "$inp"* ]]; then
      (( match_count++ ))
      if [[ -z "$first_alias" ]]; then
        first_alias="$ak"
        first_label="$label"
      fi
      if (( match_count <= 3 )); then
        [[ -n "$hint_list" ]] && hint_list+="  "
        hint_list+="$ak:$label"
      fi
    fi
  done

  _at "$prompt_row" 1
  printf '\e[48;5;236m%-*s\e[0m' "$TERM_COLS" ""
  _at "$prompt_row" 2
  printf '\e[48;5;236m\e[38;5;220m:\e[38;5;51m%s\e[38;5;51m_\e[0m' "$inp"
  _eol

  _at "$hint_row" 1
  printf '\e[48;5;234m%-*s\e[0m' "$TERM_COLS" ""
  _at "$hint_row" 2
  if (( match_count == 0 )); then
    printf '\e[48;5;234m\e[38;5;196mno match\e[38;5;240m  Enter=go  Tab=complete  Esc/:=cancel\e[0m'
  else
    printf '\e[48;5;234m\e[38;5;51m%s\e[38;5;248m  (%d match%s)\e[38;5;240m  Tab=%s  Enter=go  Esc/:=cancel\e[0m' \
      "$hint_list" "$match_count" "$( (( match_count == 1 )) && echo "" || echo "es" )" "$first_alias"
  fi
  _eol
}

_command_palette() {
  local input=""

  _draw_palette "$input"
  _drain_input

  while true; do
    local key=""
    IFS= read -rsn1 key
    case "$key" in
      $'\x1b')
        local seq=""; read -rsn2 -t 0.15 seq || seq=""
        _drain_input
        return
        ;;
      ':')
        return
        ;;
      $'\t')
        local ak
        for ak in "${KX_ALIAS_DISPLAY[@]}"; do
          local target="${KX_ALIASES[$ak]:-}"
          local label="${KX_LABELS[$ak]:-$target}"
          [[ -z "$target" ]] && continue
          if [[ -z "$input" || "$ak" == "$input"* || "$label" == "$input"* || "$target" == "$input"* ]]; then
            input="$ak"
            break
          fi
        done
        ;;
      $'\x7f'|$'\b')
        [[ -n "$input" ]] && input="${input%?}"
        ;;
      '')
        # Resolve input to a resource
        local resource=""
        if [[ -n "${KX_ALIASES[$input]:-}" ]]; then
          resource="${KX_ALIASES[$input]}"
        elif [[ -n "$input" ]]; then
          resource="$input"
        fi

        # Map well-known resources to rich pre-built views
        # Everything else goes to the generic kubectl view
        case "$resource" in
          pods)                    _switch_view "pods"       ;;
          deployments)             _switch_view "deploys"    ;;
          nodes)                   _switch_view "nodes"      ;;
          events)                  _switch_view "events"     ;;
          secrets)                 _switch_view "secrets"    ;;
          services)                _switch_view "services"   ;;
          configmaps)              _switch_view "configmaps" ;;
          persistentvolumeclaims)  _switch_view "pvcs"       ;;
          ingresses)               _switch_view "ingresses"  ;;
          jobs)                    _switch_view "jobs"       ;;
          cronjobs)                _switch_view "cronjobs"   ;;
          horizontalpodautoscalers) _switch_view "hpa"       ;;
          namespaces)              _switch_view "namespaces" ;;
          *)
            if [[ -n "$resource" ]]; then
              GENERIC_RESOURCE="$resource"
              CURRENT_VIEW="generic"
              SELECTED_IDX=0
              SCROLL_OFFSET=0
              FILTER=""
              DETAIL_MODE=false
              WATCH_MODE=false
              LAST_REFRESH=0
            fi
            ;;
        esac
        return
        ;;
      *)
        if [[ "$key" =~ [[:alnum:]_.-] ]]; then
          input+="$key"
        fi
        ;;
    esac
    _draw_palette "$input"
  done
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
      $'\x0a'|$'\r'|'') FILTER="$input"; break ;;  # Enter — apply
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

# ── Secret decoder ────────────────────────────────────────
# Fetches all data keys from a secret via kubectl and base64-decodes
# each value, then displays them in the scrollable pager.
# NOTE: Kubernetes secrets are base64 ENCODED not encrypted.
# Actual encryption-at-rest is a cluster-level config — this shows
# the decoded plaintext values just as k9s does.

_decode_secret() {
  local name="$1" ns="$2"

  # Pull the raw secret JSON and decode each key
  local raw
  raw=$(kubectl get secret "$name" -n "$ns" -o json 2>&1)

  if [[ "$raw" == *"Error"* || "$raw" == *"not found"* ]]; then
    _pager_text "secret decode error" "$raw"
    return
  fi

  # Build decoded output using kubectl + base64
  # Each key on its own labeled block
  local output=""
  output+="Secret: ${name}\n"
  output+="Namespace: ${ns}\n"

  # Get the type
  local stype
  stype=$(kubectl get secret "$name" -n "$ns" \
    -o jsonpath='{.type}' 2>/dev/null || echo "unknown")
  output+="Type: ${stype}\n"
  output+="$(printf '%0.s-' {1..60})\n\n"

  # Get all keys
  local keys=()
  mapfile -t keys < <(
    kubectl get secret "$name" -n "$ns" \
      -o jsonpath='{.data}' 2>/dev/null \
    | grep -o '"[^"]*":' \
    | tr -d '":'
  )

  if [[ ${#keys[@]} -eq 0 ]]; then
    output+="(no data keys found)\n"
  else
    for key in "${keys[@]}"; do
      local encoded decoded
      encoded=$(kubectl get secret "$name" -n "$ns" \
        -o jsonpath="{.data.${key}}" 2>/dev/null || echo "")

      if [[ -z "$encoded" ]]; then
        decoded="(empty)"
      else
        decoded=$(printf '%s' "$encoded" | base64 -d 2>/dev/null \
          || echo "(could not decode — may be binary data)")
      fi

      output+="[KEY] ${key}\n"

      # If value looks like it contains newlines (e.g. a cert or kubeconfig)
      # indent each line for readability
      while IFS= read -r dline; do
        output+="  ${dline}\n"
      done <<< "$decoded"
      output+="\n"
    done
  fi

  # Feed into the existing _show_detail pager by building a fake
  # all_lines array and calling the inner render directly
  _pager_text "decode › ${name}" "$(printf '%b' "$output")"
}

# Generic text pager — takes a title and a string, displays scrollably
_pager_text() {
  local title="$1"
  local content="$2"
  local back_label="${3:-[q]}"
  local q_action="${4:-back}"

  local all_lines=()
  while IFS= read -r line; do
    all_lines+=("$line")
  done <<< "$content"
  local total_lines=${#all_lines[@]}
  local offset=0

  _render_pt() {
    TERM_ROWS=$(tput lines 2>/dev/null || echo 40)
    TERM_COLS=$(tput cols  2>/dev/null || echo 120)
    local view_h=$(( TERM_ROWS - 3 ))
    _clear

    _at 1 1
    printf '%b%b kube-dash › %s %b' "$BG_HDR" "$C_CYAN" "$title" "$C_RESET"
    _eol

    _at 2 1
    if [[ "$q_action" == "quit" ]]; then
      printf '%b%b%s%b back  %b[q]%b quit  %b[↑↓/j/k]%b scroll  %b[g]%b top  %b[G]%b bottom%b' \
        "$BG_BAR" \
        "$C_CYAN" "$back_label" "$C_RESET$BG_BAR" \
        "$C_CYAN" "$C_RESET$BG_BAR" \
        "$C_CYAN" "$C_RESET$BG_BAR" \
        "$C_CYAN" "$C_RESET$BG_BAR" \
        "$C_CYAN" "$C_RESET$BG_BAR" \
        "$C_RESET"
    else
      printf '%b%b%s%b back  %b[↑↓/j/k]%b scroll  %b[g]%b top  %b[G]%b bottom%b' \
        "$BG_BAR" \
        "$C_CYAN" "$back_label" "$C_RESET$BG_BAR" \
        "$C_CYAN" "$C_RESET$BG_BAR" \
        "$C_CYAN" "$C_RESET$BG_BAR" \
        "$C_CYAN" "$C_RESET$BG_BAR" \
        "$C_RESET"
    fi
    _eol

    local i
    for (( i=0; i<view_h; i++ )); do
      local li=$(( offset + i ))
      _at $(( i + 3 )) 1
      if (( li < total_lines )); then
        local line="${all_lines[$li]}"
        # Syntax color
        if [[ "$line" =~ ^\[KEY\] ]]; then
          printf '%b%b%s%b' "$C_CYAN" "$C_BOLD" "${line/\[KEY\] /}" "$C_RESET"
        elif [[ "$line" =~ ^(Secret|Namespace|Type): ]]; then
          local k="${line%%:*}"
          local v="${line#*: }"
          printf '%b%s:%b %b%s%b' "$C_DCYAN" "$k" "$C_RESET" "$C_YELLOW" "$v" "$C_RESET"
        elif [[ "$line" =~ ^-{4,} ]]; then
          printf '%b%s%b' "$C_GRAY" "$line" "$C_RESET"
        elif [[ "$line" =~ ^\(empty\)$|\(could\ not ]]; then
          printf '%b%s%b' "$C_GRAY" "$line" "$C_RESET"
        else
          printf '%s' "$line"
        fi
      fi
      _eol
    done

    _at "$TERM_ROWS" 1
    printf '%b%-*s%b' "$BG_BAR" "$TERM_COLS" "" "$C_RESET"
    _at "$TERM_ROWS" 2
    local pct=0
    (( total_lines > 0 )) && pct=$(( (offset + view_h) * 100 / total_lines ))
    (( pct > 100 )) && pct=100
    printf '%b line %d/%d  %d%%%b' \
      "$C_GRAY" "$(( offset + 1 ))" "$total_lines" "$pct" "$C_RESET"
  }

  _render_pt
  _drain_input
  while true; do
    local key=""
    IFS= read -rsn1 key
    case "$key" in
      q|Q)
        if [[ "$q_action" == "quit" ]]; then
          if _confirm_quit; then
            exit 0
          fi
        else
          _clear
          return
        fi
        ;;
      g)   offset=0 ;;
      G)
        local view_h=$(( TERM_ROWS - 3 ))
        offset=$(( total_lines - view_h ))
        (( offset < 0 )) && offset=0
        ;;
      j)
        local view_h=$(( TERM_ROWS - 3 ))
        (( offset + view_h < total_lines )) && (( offset++ ))
        ;;
      k) (( offset > 0 )) && (( offset-- )) ;;
      $'\x1b')
        local seq=""; read -rsn2 -t 0.15 seq || seq=""
        _drain_input
        local view_h=$(( TERM_ROWS - 3 ))
        case "$seq" in
          "[A") (( offset > 0 )) && (( offset-- )) ;;
          "[B") (( offset + view_h < total_lines )) && (( offset++ )) ;;
          "") _clear; return ;;
        esac
        ;;
    esac
    _render_pt
  done
}

_render_view() {
  local now
  now=$(date +%s)

  # Fetch if: first load, OR watch mode is on and interval has elapsed
  if (( LAST_REFRESH == 0 )) || \
     ( $WATCH_MODE && (( now - LAST_REFRESH >= REFRESH_INTERVAL )) ); then
    _refresh_data
  fi

  _clear
  _clamp_scroll
  _draw_header
  _draw_tabs

  case "$CURRENT_VIEW" in
    pods)       _render_pods       ;;
    deploys)    _render_deploys    ;;
    nodes)      _render_nodes      ;;
    events)     _render_events     ;;
    argocd)     _render_argocd     ;;
    certs)      _render_certs      ;;
    secrets)    _render_secrets    ;;
    services)   _render_services   ;;
    helm)       _render_helm       ;;
    configmaps) _render_configmaps ;;
    pvcs)       _render_pvcs       ;;
    ingresses)  _render_ingresses  ;;
    jobs)       _render_jobs       ;;
    cronjobs)   _render_cronjobs   ;;
    hpa)        _render_hpa        ;;
    namespaces) _render_namespaces ;;
    generic)    _render_generic    ;;
  esac

  _draw_statusbar
}

# ── Main input loop ────────────────────────────────────────

_main_loop() {
  while true; do
    # Re-read terminal size on each frame
    TERM_ROWS=$(tput lines 2>/dev/null || echo 40)
    TERM_COLS=$(tput cols  2>/dev/null || echo 120)

    _render_view

    # Drain any buffered input before blocking
    _drain_input

    # Timeout depends on watch mode:
    # - watch mode on: short timeout so we re-render and re-fetch on schedule
    # - watch mode off: long keepalive just to update the clock
    local _timeout=60
    $WATCH_MODE && _timeout=$REFRESH_INTERVAL

    local key=""
    local _read_rc=0
    IFS= read -rsn1 -t "$_timeout" key || _read_rc=$?

    # Timeout — just loop to re-render (watch mode will trigger fetch in _render_view)
    (( _read_rc > 0 )) && continue

    case "$key" in

      # ── Quit ──────────────────────────────────────────────
      q|Q)
        if _confirm_quit; then
          exit 0
        fi
        ;;

      # ── Help ──────────────────────────────────────────────
      '?') _show_help; _clear; DETAIL_MODE=false ;;

      # ── View switching ─────────────────────────────────────
      1|p) _switch_view "pods"      ;;
      2)   _switch_view "deploys"   ;;
      3)   _switch_view "nodes"     ;;
      4)   _switch_view "events"; [[ "$CURRENT_NS" != "all" ]] && CURRENT_NS="all" && LAST_REFRESH=0 ;;
      5|a) _switch_view "argocd"    ;;
      6)   _switch_view "certs"     ;;
      7|s) _switch_view "secrets"   ;;
      8)   _switch_view "services"  ;;
      9|h) _switch_view "helm"      ;;

      # ── Command palette ───────────────────────────────────
      ':')
        _command_palette
        _clear
        ;;

      # ── Tab navigation ────────────────────────────────────
      $'\t')
        local views=("pods" "deploys" "nodes" "events" "argocd" "certs" "secrets" "services" "helm" "configmaps" "pvcs" "ingresses" "jobs" "cronjobs" "hpa" "namespaces")
        local cur_idx=0
        for i in "${!views[@]}"; do [[ "${views[$i]}" == "$CURRENT_VIEW" ]] && cur_idx=$i; done
        _switch_view "${views[$(( (cur_idx+1) % ${#views[@]} ))]}"
        ;;

      # ── Navigation ────────────────────────────────────────
      $'\x1b')
        # Use a slightly longer timeout to ensure the full sequence arrives
        local seq; read -rsn2 -t 0.15 seq || seq=""
        # Drain any trailing bytes (e.g. from modifier keys or partial seqs)
        _drain_input
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
          "") # Plain ESC — return to Pods, or clear filter if already there
            if [[ "$CURRENT_VIEW" != "pods" ]]; then
              _switch_view "pods"
            elif [[ -n "$FILTER" ]]; then
              FILTER=""
            fi
            ;;
          "[Z") # Shift-Tab
            local views=("pods" "deploys" "nodes" "events" "argocd" "certs" "secrets" "services" "helm" "configmaps" "pvcs" "ingresses" "jobs" "cronjobs" "hpa" "namespaces")
            local cur_idx=0
            for i in "${!views[@]}"; do [[ "${views[$i]}" == "$CURRENT_VIEW" ]] && cur_idx=$i; done
            _switch_view "${views[$(( (cur_idx-1+${#views[@]}) % ${#views[@]} ))]}"
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

        # Events are not a describable resource in a useful way —
        # show the full event detail including the untruncated message
        if [[ "$CURRENT_VIEW" == "events" ]]; then
          IFS=$'\t' read -r ev_ns ev_last ev_type ev_reason ev_obj ev_msg <<< "$line"
          local ev_detail
          ev_detail="Namespace:  ${ev_ns}\n"
          ev_detail+="Last Seen:  ${ev_last}\n"
          ev_detail+="Type:       ${ev_type}\n"
          ev_detail+="Reason:     ${ev_reason}\n"
          ev_detail+="Object:     ${ev_obj}\n"
          ev_detail+="$(printf '%0.s-' {1..60})\n"
          ev_detail+="Message:\n\n"
          # Full message from kubectl (not truncated like custom-columns)
          local full_msg
          full_msg=$(kubectl get events -n "$ev_ns" \
            --field-selector "involvedObject.name=${ev_obj},reason=${ev_reason}" \
            --sort-by='.lastTimestamp' \
            -o jsonpath='{.items[-1].message}' 2>/dev/null \
            || echo "$ev_msg")
          # Word-wrap at 80 chars for readability
          ev_detail+=$(printf '%s' "$full_msg" | fold -s -w 80)
          _pager_text "event › ${ev_obj}" "$(printf '%b' "$ev_detail")" "[Esc]" "quit"
          LAST_REFRESH=0
          continue
        fi

        # Namespaces view — Enter switches to that namespace and goes to pods
        if [[ "$CURRENT_VIEW" == "namespaces" ]]; then
          IFS=$'\t' read -r ns_name _ <<< "$line"
          if [[ "$ns_name" != "$CURRENT_NS" ]]; then
            CURRENT_NS="$ns_name"
            VIEW_LOADED=()
          fi
          _switch_view "pods"
          continue
        fi

        local res="pods"
        [[ "$CURRENT_VIEW" == "deploys"    ]] && res="deployment"
        [[ "$CURRENT_VIEW" == "argocd"     ]] && res="application.argoproj.io"
        [[ "$CURRENT_VIEW" == "certs"      ]] && res="certificate.cert-manager.io"
        [[ "$CURRENT_VIEW" == "secrets"    ]] && res="secret"
        [[ "$CURRENT_VIEW" == "services"   ]] && res="service"
        [[ "$CURRENT_VIEW" == "configmaps" ]] && res="configmap"
        [[ "$CURRENT_VIEW" == "pvcs"       ]] && res="persistentvolumeclaim"
        [[ "$CURRENT_VIEW" == "ingresses"  ]] && res="ingress"
        [[ "$CURRENT_VIEW" == "jobs"       ]] && res="job"
        [[ "$CURRENT_VIEW" == "cronjobs"   ]] && res="cronjob"
        [[ "$CURRENT_VIEW" == "hpa"        ]] && res="horizontalpodautoscaler"
        [[ "$CURRENT_VIEW" == "generic"    ]] && res="$GENERIC_RESOURCE"

        # Nodes and generic have no namespace column or different layout
        if [[ "$CURRENT_VIEW" == "nodes" ]]; then
          IFS=$'\t' read -r name _ <<< "$line"
          ns="default"
          res="node"
        elif [[ "$CURRENT_VIEW" == "generic" ]]; then
          # kubectl -o wide output: NAME ... (no namespace prefix unless -A)
          # With -A: NAMESPACE NAME ...
          if [[ "$CURRENT_NS" == "all" ]]; then
            read -r ns name _ <<< "$line"
          else
            read -r name _ <<< "$line"
            ns="$CURRENT_NS"
          fi
        fi
        [[ "$CURRENT_VIEW" == "helm"     ]] && {
          IFS=$'\t' read -r helm_name helm_ns helm_rev helm_status helm_chart helm_appver <<< "$line"
          # Build a comprehensive view: status header + values + notes
          local helm_out=""
          helm_out+="Release:    ${helm_name}\n"
          helm_out+="Namespace:  ${helm_ns}\n"
          helm_out+="Chart:      ${helm_chart}\n"
          helm_out+="App Ver:    ${helm_appver}\n"
          helm_out+="Revision:   ${helm_rev}\n"
          helm_out+="Status:     ${helm_status}\n"
          helm_out+="$(printf '%0.s-' {1..60})\n"
          helm_out+="\n"

          # helm get all gives values + hooks + manifest + notes in one call
          local helm_content
          helm_content=$(helm get all "$helm_name" -n "$helm_ns" 2>&1)
          helm_out+="$helm_content"

          _pager_text "helm › ${helm_name} (${helm_ns})" "$(printf '%b' "$helm_out")"
          LAST_REFRESH=0
          continue
        }
        DETAIL_MODE=true
        _show_detail "$res" "$name" "$ns"
        DETAIL_MODE=false
        LAST_REFRESH=0
        _clear
        ;;

      # ── Decode secret ─────────────────────────────────────
      x|X)
        if [[ "$CURRENT_VIEW" == "secrets" ]]; then
          local line; line=$(_selected_line) || continue
          IFS=$'\t' read -r ns name _ <<< "$line"
          _decode_secret "$name" "$ns"
          LAST_REFRESH=0
        fi
        ;;

      # ── Logs ──────────────────────────────────────────────
      l)
        if [[ "$CURRENT_VIEW" == "pods" ]]; then
          local pod ns
          pod=$(_selected_pod_name) && ns=$(_selected_pod_ns) && \
            _show_logs "$pod" "$ns"
          _clear; DETAIL_MODE=false
        fi
        ;;

      # ── Exec ──────────────────────────────────────────────
      e|E)
        if $READONLY; then
          _at $(( TERM_ROWS/2 )) $(( TERM_COLS/2 - 15 ))
          printf '%b  read-only mode — exec disabled  %b' "$C_YELLOW" "$C_RESET"
          sleep 1; continue
        fi
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
        local res="pods"
        local desc_name desc_ns
        if [[ "$CURRENT_VIEW" == "nodes" ]]; then
          # nodes: name\tstatus\trole\tversion\tarch\tage  (no namespace)
          IFS=$'\t' read -r desc_name _ <<< "$line"
          desc_ns="default"
          res="node"
        elif [[ "$CURRENT_VIEW" == "deploys" ]]; then
          IFS=$'\t' read -r desc_ns desc_name _ <<< "$line"
          res="deployment"
        else
          IFS=$'\t' read -r desc_ns desc_name _ <<< "$line"
        fi
        DETAIL_MODE=true
        _show_detail "$res" "$desc_name" "$desc_ns"
        DETAIL_MODE=false
        LAST_REFRESH=0
        _clear
        ;;

      # ── Rolling restart ───────────────────────────────────
      r)
        if $READONLY; then
          _at $(( TERM_ROWS/2 )) $(( TERM_COLS/2 - 15 ))
          printf '%b  read-only mode — restart disabled  %b' "$C_YELLOW" "$C_RESET"
          sleep 1; continue
        fi
        if [[ "$CURRENT_VIEW" == "deploys" ]]; then
          local line; line=$(_selected_line) || continue
          IFS=$'\t' read -r ns name _ <<< "$line"
          _rolling_restart "deployment" "$name" "$ns"
          LAST_REFRESH=0
        fi
        ;;

      # ── Delete ────────────────────────────────────────────
      D)
        if $READONLY; then
          _at $(( TERM_ROWS/2 )) $(( TERM_COLS/2 - 15 ))
          printf '%b  read-only mode — delete disabled  %b' "$C_YELLOW" "$C_RESET"
          sleep 1; continue
        fi
        local line; line=$(_selected_line) || continue
        IFS=$'\t' read -r ns name _ <<< "$line"
        local res="pod"
        [[ "$CURRENT_VIEW" == "deploys" ]] && res="deployment"
        _delete_resource "$res" "$name" "$ns"
        ;;

      # ── Filter ────────────────────────────────────────────
      '/')
        _input_filter
        # Clamp selection to filtered result count
        local _fc=0
        mapfile -t _tmp < <(_filtered_lines)
        _fc=${#_tmp[@]}
        (( _fc == 0 )) && SELECTED_IDX=0
        (( SELECTED_IDX >= _fc && _fc > 0 )) && SELECTED_IDX=$(( _fc - 1 ))
        ;;

      # ── kubectl top ───────────────────────────────────────
      t|T)
        if [[ "$CURRENT_VIEW" == "nodes" ]]; then
          _show_top "nodes" ""
        else
          _show_top "pods" "$CURRENT_NS"
        fi
        _clear; LAST_REFRESH=0
        ;;

      # ── Previous logs (crashed containers) ───────────────
      v)
        if [[ "$CURRENT_VIEW" == "pods" ]]; then
          local pod ns
          pod=$(_selected_pod_name) && ns=$(_selected_pod_ns) && \
            _show_prev_logs "$pod" "$ns"
          _clear
        fi
        ;;

      # ── Port-forward ──────────────────────────────────────
      f|F)
        if [[ "$CURRENT_VIEW" == "pods" || "$CURRENT_VIEW" == "services" ]]; then
          local line; line=$(_selected_line) || continue
          IFS=$'\t' read -r ns name _ <<< "$line"
          local res="pod"
          [[ "$CURRENT_VIEW" == "services" ]] && res="service"
          _port_forward "$res" "$name" "$ns"
          _clear
        fi
        ;;

      # ── Context picker ─── (was c, moved to C) ───────────
      C)
        _pick_context
        _clear; DETAIL_MODE=false
        ;;

      # ── Namespace picker ──────────────────────────────────
      n|N)
        _pick_namespace
        _clear; DETAIL_MODE=false
        ;;

      # ── Watch mode toggle ─────────────────────────────────
      w|W)
        if $WATCH_MODE; then
          WATCH_MODE=false
        else
          WATCH_MODE=true
          LAST_REFRESH=0   # immediate fetch when enabling
        fi
        ;;
      # ── Force refresh ─────────────────────────────────────
      R)
        # Invalidate cache for current view only
        unset "VIEW_LOADED[${CURRENT_VIEW}:${CURRENT_NS}]"
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
  # ── Environment checks ────────────────────────────────────

  # Bash version — requires 4+ for associative arrays, mapfile, etc.
  if (( BASH_VERSINFO[0] < 4 )); then
    echo ""
    echo "  ✗ kube-dash requires bash 4 or newer."
    echo "    You have: bash $BASH_VERSION"
    echo ""
    echo "  macOS fix:  brew install bash"
    echo "              then run as: /usr/local/bin/bash kube-dash"
    echo ""
    exit 1
  fi

  # stty cbreak — required for single-keypress TUI input.
  # Fails on Git Bash (MINGW) and some restricted environments.
  if ! stty cbreak 2>/dev/null; then
    echo ""
    echo "  ✗ kube-dash requires stty cbreak support."
    echo "    Your terminal does not support it."
    echo ""
    echo "  Git Bash is not supported — use WSL2 or a native Linux terminal."
    echo ""
    stty sane 2>/dev/null
    exit 1
  fi
  stty sane 2>/dev/null  # restore after test

  # tput — needed for cursor control and screen management
  if ! tput cols &>/dev/null; then
    echo ""
    echo "  ✗ kube-dash requires tput (ncurses)."
    echo "    Install ncurses and ensure TERM is set."
    echo ""
    exit 1
  fi

  # kubectl — required
  if ! command -v kubectl &>/dev/null; then
    echo ""
    echo "  ✗ kubectl not found in PATH."
    echo "    Install kubectl: https://kubernetes.io/docs/tasks/tools/"
    echo ""
    exit 1
  fi

  # ── Startup ───────────────────────────────────────────────

  # Default to all namespaces on startup — k9s behaviour
  CURRENT_CTX=$(kubectl config current-context 2>/dev/null || echo "none")
  CURRENT_NS="all"

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
  -n, --namespace <ns>    Start in namespace (default: all)
  --context <ctx>         Use context
  --interval <secs>       Watch mode refresh interval (default: 5)
  -v, --view <view>       Start view: pods|deploys|nodes|events|argocd|certs
  --readonly              Disable destructive actions (delete, restart, exec)
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
