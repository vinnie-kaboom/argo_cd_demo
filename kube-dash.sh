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

  # Row 2 — first 9 views
  _at 2 1
  printf '\e[48;5;235m%-*s\e[0m' "$TERM_COLS" ""
  _at 2 1

  local tabs1=("1:Pods" "2:Deploys" "3:Nodes" "4:Events" "5:ArgoCD" "6:Certs" "7:Secrets" "8:Services" "9:Helm")
  local views1=("pods"  "deploys"   "nodes"   "events"   "argocd"   "certs"   "secrets"   "services"   "helm")

  printf '\e[48;5;235m '
  for i in "${!tabs1[@]}"; do
    local tab="${tabs1[$i]}" view="${views1[$i]}"
    if [[ "$view" == "$CURRENT_VIEW" ]]; then
      printf '\e[0m\e[48;5;51m\e[38;5;232m\e[1m %s \e[0m\e[48;5;235m' "$tab"
    else
      printf '\e[38;5;248m %s \e[0m\e[48;5;235m' "$tab"
    fi
    printf '\e[38;5;240m|\e[0m\e[48;5;235m'
  done
  printf '\e[0m'

  # Row 3 — next 6 views
  _at 3 1
  printf '\e[48;5;233m%-*s\e[0m' "$TERM_COLS" ""
  _at 3 1

  local tabs2=("10:ConfigMaps" "11:PVCs" "12:Ingresses" "13:Jobs" "14:CronJobs" "15:HPA")
  local views2=("configmaps"   "pvcs"   "ingresses"    "jobs"   "cronjobs"    "hpa")

  printf '\e[48;5;233m '
  for i in "${!tabs2[@]}"; do
    local tab="${tabs2[$i]}" view="${views2[$i]}"
    if [[ "$view" == "$CURRENT_VIEW" ]]; then
      printf '\e[0m\e[48;5;51m\e[38;5;232m\e[1m %s \e[0m\e[48;5;233m' "$tab"
    else
      printf '\e[38;5;244m %s \e[0m\e[48;5;233m' "$tab"
    fi
    printf '\e[38;5;238m|\e[0m\e[48;5;233m'
  done
  printf '\e[0m'

  # Filter indicator on row 2
  if [[ -n "$FILTER" ]]; then
    _at 2 $(( TERM_COLS - 20 ))
    printf ' \e[38;5;220m/%s\e[0m' "$FILTER"
  fi

  # Refresh countdown
  local now elapsed next
  now=$(date +%s); elapsed=$(( now - LAST_REFRESH ))
  next=$(( REFRESH_INTERVAL - elapsed )); (( next < 0 )) && next=0
  _at 3 $(( TERM_COLS - 12 ))
  printf '\e[48;5;233m\e[38;5;240m refresh %-2ds\e[0m' "$next"
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

  if $DETAIL_MODE; then
    printf '%b[q]%b back  %b[↑↓/jk]%b scroll  %b[l]%b logs  %b[e]%b exec  %b[r]%b restart  %b[D]%b delete  %b[?]%b help' \
      "$C_CYAN" "$C_RESET" "$C_CYAN" "$C_RESET" "$C_CYAN" "$C_RESET" \
      "$C_CYAN" "$C_RESET" "$C_CYAN" "$C_RESET" "$C_RED"  "$C_RESET" \
      "$C_CYAN" "$C_RESET"
  else
    printf '%b[1-9,0]%b views  %b[P/i/J/W/A]%b more  %b[↑↓]%b nav  %b[Enter]%b detail  %b[l]%b logs  %b[v]%b prev-logs  %b[t]%b top  %b[f]%b fwd  %b[x]%b decode  %b[/]%b filter  %b[n]%b ns  %b[C]%b ctx  %b[?]%b help  %b[q]%b quit' \
      "$C_CYAN" "$C_RESET" "$C_CYAN" "$C_RESET" "$C_CYAN" "$C_RESET" \
      "$C_CYAN" "$C_RESET" "$C_CYAN" "$C_RESET" "$C_CYAN" "$C_RESET" \
      "$C_CYAN" "$C_RESET" "$C_CYAN" "$C_RESET" "$C_CYAN" "$C_RESET" \
      "$C_CYAN" "$C_RESET" "$C_CYAN" "$C_RESET" "$C_CYAN" "$C_RESET" \
      "$C_CYAN" "$C_RESET"
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
    age  = cm.get('metadata', {}).get('creationTimestamp', '')[:10]
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
  esac
  LAST_REFRESH=$(date +%s)
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
  local start_row=5
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

  _hline $(( start_row+1 )) 1 "$TERM_COLS" "-" "$C_GRAY"

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
  local start_row=5
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
  local idx=0
  local filtered=()
  mapfile -t filtered < <(_filtered_lines)

  for line in "${filtered[@]}"; do
    (( row > TERM_ROWS-3 )) && break
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
  local start_row=5
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
  local idx=0
  local filtered=()
  mapfile -t filtered < <(_filtered_lines)

  for line in "${filtered[@]}"; do
    (( row > TERM_ROWS-3 )) && break
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
  local start_row=5
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
  local idx=0
  local filtered=()
  mapfile -t filtered < <(_filtered_lines)

  # Show newest first
  local rev_filtered=()
  for (( i=${#filtered[@]}-1; i>=0; i-- )); do
    rev_filtered+=("${filtered[$i]}")
  done

  for line in "${rev_filtered[@]}"; do
    (( row > TERM_ROWS-3 )) && break
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
  local start_row=5
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
  local idx=0
  local filtered=()
  mapfile -t filtered < <(_filtered_lines)

  if [[ ${#filtered[@]} -eq 1 && "${filtered[0]}" == *"not-found"* ]]; then
    _at $(( start_row+4 )) $(( TERM_COLS/2-20 ))
    printf '%bArgoCD CRDs not found — is ArgoCD installed?%b' "$C_GRAY" "$C_RESET"
    return
  fi

  for line in "${filtered[@]}"; do
    (( row > TERM_ROWS-3 )) && break
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
  local start_row=5
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
  local idx=0
  local filtered=()
  mapfile -t filtered < <(_filtered_lines)

  if [[ ${#filtered[@]} -eq 1 && "${filtered[0]}" == *"not-found"* ]]; then
    _at $(( start_row+4 )) $(( TERM_COLS/2-20 ))
    printf '%bcert-manager CRDs not found — is cert-manager installed?%b' "$C_GRAY" "$C_RESET"
    return
  fi

  for line in "${filtered[@]}"; do
    (( row > TERM_ROWS-3 )) && break
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

_render_secrets() {
  local start_row=5
  TERM_COLS=$(tput cols 2>/dev/null || echo 120)
  local w_ns=16 w_name=40 w_type=32 w_keys=6 w_age=12

  _at $start_row 1
  printf '%b%b %-*s %-*s %-*s %-*s %-*s%b' \
    "$C_BOLD" "$C_DCYAN" \
    "$w_ns" "NAMESPACE" "$w_name" "NAME" \
    "$w_type" "TYPE" "$w_keys" "KEYS" "$w_age" "AGE" \
    "$C_RESET"
  _eol
  _hline $(( start_row+1 )) 1 "$TERM_COLS" "-" "$C_GRAY"

  local row=$(( start_row+2 )) idx=0
  local filtered=()
  mapfile -t filtered < <(_filtered_lines)

  for line in "${filtered[@]}"; do
    (( row > TERM_ROWS-3 )) && break
    IFS=$'\t' read -r ns name type keys age <<< "$line"

    # Color by secret type
    local tc="$C_WHITE"
    [[ "$type" == "kubernetes.io/service-account-token" ]] && tc="$C_GRAY"
    [[ "$type" == "kubernetes.io/tls"                   ]] && tc="$C_CYAN"
    [[ "$type" == "Opaque"                              ]] && tc="$C_YELLOW"
    [[ "$type" == *"helm"*                              ]] && tc="$C_MAGENTA"

    _at "$row" 1
    (( idx == SELECTED_IDX )) && printf '%b' "$BG_SEL"

    printf ' %b%-*s%b %b%-*s%b %b%-*s%b %b%-*s%b %-*s' \
      "$C_GRAY"  "$w_ns"   "${ns:0:$w_ns}" \
      "$C_RESET" "$C_WHITE" "$w_name" "${name:0:$w_name}" \
      "$C_RESET" "$tc"      "$w_type" "${type:0:$w_type}" \
      "$C_RESET" "$C_LGRAY" "$w_keys" "${keys}" \
      "$C_RESET"            "$w_age"  "${age:0:$w_age}"

    printf '%b'; _eol
    (( idx++ )); (( row++ ))
  done

  (( ${#filtered[@]} == 0 )) && {
    _at $(( start_row+4 )) $(( TERM_COLS/2-10 ))
    printf '%bNo secrets found%b' "$C_GRAY" "$C_RESET"
  }

  _at $(( TERM_ROWS-2 )) 2
  printf '%b%d secrets%b' "$C_LGRAY" "${#filtered[@]}" "$C_RESET"
}

_render_services() {
  local start_row=5
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

  local row=$(( start_row+2 )) idx=0
  local filtered=()
  mapfile -t filtered < <(_filtered_lines)

  for line in "${filtered[@]}"; do
    (( row > TERM_ROWS-3 )) && break
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
    (( idx == SELECTED_IDX )) && printf '%b' "$BG_SEL"

    printf ' %b%-*s%b %b%-*s%b %b%-*s%b %-*s %b%-*s%b %-*s %-*s' \
      "$C_GRAY"    "$w_ns"    "${ns:0:$w_ns}" \
      "$C_RESET"   "$C_WHITE" "$w_name"  "${name:0:$w_name}" \
      "$C_RESET"   "$tc"      "$w_type"  "${type:0:$w_type}" \
      "$C_RESET"              "$w_cip"   "${cip:0:$w_cip}" \
      "$eip_color"            "$w_eip"   "${eip_plain:0:$w_eip}" \
      "$C_RESET"              "$w_ports" "${ports:0:$w_ports}" \
                              "$w_age"   "${age:0:$w_age}"

    printf '%b'; _eol
    (( idx++ )); (( row++ ))
  done

  (( ${#filtered[@]} == 0 )) && {
    _at $(( start_row+4 )) $(( TERM_COLS/2-10 ))
    printf '%bNo services found%b' "$C_GRAY" "$C_RESET"
  }

  _at $(( TERM_ROWS-2 )) 2
  printf '%b%d services%b' "$C_LGRAY" "${#filtered[@]}" "$C_RESET"
}

_render_helm() {
  local start_row=5
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

  for line in "${filtered[@]}"; do
    (( row > TERM_ROWS-3 )) && break
    IFS=$'\t' read -r name ns rev status chart appver <<< "$line"
    [[ -z "$name" ]] && continue

    local sc="$C_WHITE"
    [[ "$status" == "deployed"   ]] && sc="$C_GREEN"  && (( deployed++ ))
    [[ "$status" == "failed"     ]] && sc="$C_RED"    && (( failed++ ))
    [[ "$status" == "superseded" ]] && sc="$C_GRAY"
    [[ "$status" == "pending"*   ]] && sc="$C_YELLOW"

    _at "$row" 1
    (( idx == SELECTED_IDX )) && printf '%b' "$BG_SEL"

    printf ' %b%-*s%b %b%-*s%b %b%-*s%b %b%-*s%b %-*s %-*s' \
      "$C_WHITE"  "$w_name"   "${name:0:$w_name}" \
      "$C_RESET"  "$C_YELLOW" "$w_ns"     "${ns:0:$w_ns}" \
      "$C_RESET"  "$C_LGRAY"  "$w_rev"    "${rev:0:$w_rev}" \
      "$C_RESET"  "$sc"       "$w_status" "${status:0:$w_status}" \
      "$C_RESET"              "$w_chart"  "${chart:0:$w_chart}" \
                              "$w_appver" "${appver:0:$w_appver}"

    printf '%b'; _eol
    (( idx++ )); (( row++ ))
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
  local start_row=5
  TERM_COLS=$(tput cols 2>/dev/null || echo 120)
  local w_ns=16 w_name=48 w_keys=6 w_age=12

  _at $start_row 1
  printf '%b%b %-*s %-*s %-*s %-*s%b' \
    "$C_BOLD" "$C_DCYAN" \
    "$w_ns" "NAMESPACE" "$w_name" "NAME" "$w_keys" "KEYS" "$w_age" "AGE" \
    "$C_RESET"
  _eol
  _hline $(( start_row+1 )) 1 "$TERM_COLS" "-" "$C_GRAY"

  local row=$(( start_row+2 )) idx=0
  local filtered=(); mapfile -t filtered < <(_filtered_lines)

  for line in "${filtered[@]}"; do
    (( row > TERM_ROWS-3 )) && break
    IFS=$'\t' read -r ns name keys age <<< "$line"
    local kc="$C_LGRAY"; (( ${keys:-0} > 0 )) && kc="$C_WHITE"
    _at "$row" 1
    (( idx == SELECTED_IDX )) && printf '%b' "$BG_SEL"
    printf ' %b%-*s%b %b%-*s%b %b%-*s%b %-*s' \
      "$C_GRAY"  "$w_ns"   "${ns:0:$w_ns}" \
      "$C_RESET" "$C_WHITE" "$w_name" "${name:0:$w_name}" \
      "$C_RESET" "$kc"     "$w_keys" "${keys:-0}" \
      "$C_RESET"           "$w_age"  "${age:0:$w_age}"
    printf '%b'; _eol
    (( idx++ )); (( row++ ))
  done
  (( ${#filtered[@]} == 0 )) && { _at $(( start_row+4 )) $(( TERM_COLS/2-10 )); printf '%bNo configmaps found%b' "$C_GRAY" "$C_RESET"; }
  _at $(( TERM_ROWS-2 )) 2
  printf '%b%d configmaps%b' "$C_LGRAY" "${#filtered[@]}" "$C_RESET"
}

_render_pvcs() {
  local start_row=5
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

  local row=$(( start_row+2 )) idx=0
  local filtered=(); mapfile -t filtered < <(_filtered_lines)

  for line in "${filtered[@]}"; do
    (( row > TERM_ROWS-3 )) && break
    IFS=$'\t' read -r ns name status vol cap access sc age <<< "$line"
    local sc_color; sc_color=$(_status_color "$status")
    _at "$row" 1
    (( idx == SELECTED_IDX )) && printf '%b' "$BG_SEL"
    printf ' %b%-*s%b %b%-*s%b %b%-*s%b %-*s %-*s %-*s %-*s' \
      "$C_GRAY"  "$w_ns"     "${ns:0:$w_ns}" \
      "$C_RESET" "$C_WHITE"  "$w_name"   "${name:0:$w_name}" \
      "$C_RESET" "$sc_color" "$w_status" "${status:0:$w_status}" \
      "$C_RESET"             "$w_vol"    "${vol:0:$w_vol}" \
                             "$w_cap"    "${cap:0:$w_cap}" \
                             "$w_sc"     "${sc:0:$w_sc}" \
                             "$w_age"    "${age:0:$w_age}"
    printf '%b'; _eol
    (( idx++ )); (( row++ ))
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
  local start_row=5
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

  local row=$(( start_row+2 )) idx=0
  local filtered=(); mapfile -t filtered < <(_filtered_lines)

  for line in "${filtered[@]}"; do
    (( row > TERM_ROWS-3 )) && break
    IFS=$'\t' read -r ns name class hosts addr ports age <<< "$line"
    local ac="$C_LGRAY"; [[ -n "$addr" && "$addr" != "<none>" ]] && ac="$C_GREEN"
    _at "$row" 1
    (( idx == SELECTED_IDX )) && printf '%b' "$BG_SEL"
    printf ' %b%-*s%b %b%-*s%b %-*s %b%-*s%b %b%-*s%b %-*s' \
      "$C_GRAY"  "$w_ns"    "${ns:0:$w_ns}" \
      "$C_RESET" "$C_WHITE" "$w_name"  "${name:0:$w_name}" \
      "$C_RESET"            "$w_class" "${class:0:$w_class}" \
      "$C_CYAN"             "$w_hosts" "${hosts:0:$w_hosts}" \
      "$C_RESET" "$ac"      "$w_addr"  "${addr:0:$w_addr}" \
      "$C_RESET"            "$w_age"   "${age:0:$w_age}"
    printf '%b'; _eol
    (( idx++ )); (( row++ ))
  done
  (( ${#filtered[@]} == 0 )) && { _at $(( start_row+4 )) $(( TERM_COLS/2-10 )); printf '%bNo ingresses found%b' "$C_GRAY" "$C_RESET"; }
  _at $(( TERM_ROWS-2 )) 2
  printf '%b%d ingresses%b' "$C_LGRAY" "${#filtered[@]}" "$C_RESET"
}

_render_jobs() {
  local start_row=5
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

  local row=$(( start_row+2 )) idx=0
  local filtered=(); mapfile -t filtered < <(_filtered_lines)
  local complete=0 failed=0

  for line in "${filtered[@]}"; do
    (( row > TERM_ROWS-3 )) && break
    IFS=$'\t' read -r ns name comp status dur age <<< "$line"
    local sc="$C_YELLOW"
    [[ "$status" == "Complete" ]] && sc="$C_GREEN"  && (( complete++ ))
    [[ "$status" == "Failed"   ]] && sc="$C_RED"    && (( failed++ ))
    _at "$row" 1
    (( idx == SELECTED_IDX )) && printf '%b' "$BG_SEL"
    printf ' %b%-*s%b %b%-*s%b %b%-*s%b %b%-*s%b %-*s %-*s' \
      "$C_GRAY"  "$w_ns"   "${ns:0:$w_ns}" \
      "$C_RESET" "$C_WHITE" "$w_name"   "${name:0:$w_name}" \
      "$C_RESET" "$C_LGRAY" "$w_comp"   "${comp:0:$w_comp}" \
      "$C_RESET" "$sc"      "$w_status" "${status:0:$w_status}" \
      "$C_RESET"            "$w_dur"    "${dur:0:$w_dur}" \
                            "$w_age"    "${age:0:$w_age}"
    printf '%b'; _eol
    (( idx++ )); (( row++ ))
  done
  (( ${#filtered[@]} == 0 )) && { _at $(( start_row+4 )) $(( TERM_COLS/2-10 )); printf '%bNo jobs found%b' "$C_GRAY" "$C_RESET"; }
  _at $(( TERM_ROWS-2 )) 2
  printf '%b%d jobs%b  %bComplete: %b%b%d%b  %bFailed: %b%b%d%b' \
    "$C_LGRAY" "${#filtered[@]}" "$C_RESET" \
    "$C_GRAY" "$C_RESET" "$C_GREEN" "$complete" "$C_RESET" \
    "$C_GRAY" "$C_RESET" "$C_RED"   "$failed"   "$C_RESET"
}

_render_cronjobs() {
  local start_row=5
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

  local row=$(( start_row+2 )) idx=0
  local filtered=(); mapfile -t filtered < <(_filtered_lines)

  for line in "${filtered[@]}"; do
    (( row > TERM_ROWS-3 )) && break
    IFS=$'\t' read -r ns name sched susp active last age <<< "$line"
    local sc="$C_WHITE"; [[ "$susp" == "Yes" ]] && sc="$C_YELLOW"
    local ac="$C_LGRAY"; (( ${active:-0} > 0 )) && ac="$C_GREEN"
    _at "$row" 1
    (( idx == SELECTED_IDX )) && printf '%b' "$BG_SEL"
    printf ' %b%-*s%b %b%-*s%b %b%-*s%b %b%-*s%b %b%-*s%b %-*s %-*s' \
      "$C_GRAY"  "$w_ns"    "${ns:0:$w_ns}" \
      "$C_RESET" "$C_WHITE" "$w_name"   "${name:0:$w_name}" \
      "$C_RESET" "$C_CYAN"  "$w_sched"  "${sched:0:$w_sched}" \
      "$C_RESET" "$sc"      "$w_susp"   "${susp:0:$w_susp}" \
      "$C_RESET" "$ac"      "$w_active" "${active:-0}" \
      "$C_RESET"            "$w_last"   "${last:0:$w_last}" \
                            "$w_age"    "${age:0:$w_age}"
    printf '%b'; _eol
    (( idx++ )); (( row++ ))
  done
  (( ${#filtered[@]} == 0 )) && { _at $(( start_row+4 )) $(( TERM_COLS/2-10 )); printf '%bNo cronjobs found%b' "$C_GRAY" "$C_RESET"; }
  _at $(( TERM_ROWS-2 )) 2
  printf '%b%d cronjobs%b' "$C_LGRAY" "${#filtered[@]}" "$C_RESET"
}

_render_hpa() {
  local start_row=5
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

  local row=$(( start_row+2 )) idx=0
  local filtered=(); mapfile -t filtered < <(_filtered_lines)

  for line in "${filtered[@]}"; do
    (( row > TERM_ROWS-3 )) && break
    IFS=$'\t' read -r ns name ref min max cur age <<< "$line"
    local cc="$C_WHITE"
    (( ${cur:-0} >= ${max:-0} && ${max:-0} > 0 )) && cc="$C_RED"
    (( ${cur:-0} <= ${min:-0} && ${min:-0} > 0 )) && cc="$C_LGRAY"
    _at "$row" 1
    (( idx == SELECTED_IDX )) && printf '%b' "$BG_SEL"
    printf ' %b%-*s%b %b%-*s%b %-*s %b%-*s%b %b%-*s%b %b%-*s%b %-*s' \
      "$C_GRAY"  "$w_ns"    "${ns:0:$w_ns}" \
      "$C_RESET" "$C_WHITE" "$w_name" "${name:0:$w_name}" \
      "$C_RESET"            "$w_ref"  "${ref:0:$w_ref}" \
      "$C_CYAN"             "$w_min"  "${min:0:$w_min}" \
      "$C_RESET" "$C_CYAN"  "$w_max"  "${max:0:$w_max}" \
      "$C_RESET" "$cc"      "$w_cur"  "${cur:-0}" \
      "$C_RESET"            "$w_age"  "${age:0:$w_age}"
    printf '%b'; _eol
    (( idx++ )); (( row++ ))
  done
  (( ${#filtered[@]} == 0 )) && { _at $(( start_row+4 )) $(( TERM_COLS/2-10 )); printf '%bNo HPAs found%b' "$C_GRAY" "$C_RESET"; }
  _at $(( TERM_ROWS-2 )) 2
  printf '%b%d HPAs%b' "$C_LGRAY" "${#filtered[@]}" "$C_RESET"
}

# ── kubectl top ────────────────────────────────────────────

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

# ── Previous container logs (crashed pods) ─────────────────

_show_prev_logs() {
  local pod="$1" ns="$2"

  local all_lines=()
  local output
  output=$(kubectl logs --previous --tail=200 "$pod" -n "$ns" 2>&1)

  while IFS= read -r line; do all_lines+=("$line"); done <<< "$output"
  local total_lines=${#all_lines[@]}
  local offset=0

  _render_pl() {
    TERM_ROWS=$(tput lines 2>/dev/null || echo 40)
    TERM_COLS=$(tput cols  2>/dev/null || echo 120)
    local view_h=$(( TERM_ROWS - 3 ))
    _clear
    _at 1 1
    printf '%b%b kube-dash › prev-logs › %s %b' "$BG_HDR" "$C_CYAN" "$pod" "$C_RESET"; _eol
    _at 2 1
    printf '%b%b[q]%b back  %b[↑↓/j/k]%b scroll  %b[g]%b top  %b[G]%b bottom%b' \
      "$BG_BAR" "$C_CYAN" "$C_RESET$BG_BAR" "$C_CYAN" "$C_RESET$BG_BAR" \
      "$C_CYAN" "$C_RESET$BG_BAR" "$C_CYAN" "$C_RESET$BG_BAR" "$C_RESET"; _eol
    for (( i=0; i<view_h; i++ )); do
      local li=$(( offset + i ))
      _at $(( i + 3 )) 1
      if (( li < total_lines )); then
        local l="${all_lines[$li]}"
        if   [[ "$l" =~ ERROR|error|Error|FATAL|panic ]]; then printf '%b%s%b' "$C_RED"    "$l" "$C_RESET"
        elif [[ "$l" =~ WARN|warn|WARNING              ]]; then printf '%b%s%b' "$C_YELLOW" "$l" "$C_RESET"
        else printf '%s' "$l"; fi
      fi; _eol
    done
    _at "$TERM_ROWS" 1
    printf '%b%b line %d/%d%b' "$BG_BAR" "$C_GRAY" "$(( offset+1 ))" "$total_lines" "$C_RESET"
  }

  _render_pl; _drain_input
  while true; do
    local key=""; IFS= read -rsn1 key
    local view_h=$(( TERM_ROWS - 3 ))
    case "$key" in
      q|Q) _clear; return ;;
      g)   offset=0 ;;
      G)   offset=$(( total_lines - view_h )); (( offset < 0 )) && offset=0 ;;
      j)   (( offset + view_h < total_lines )) && (( offset++ )) ;;
      k)   (( offset > 0 )) && (( offset-- )) ;;
      $'\x1b')
        local seq=""; read -rsn2 -t 0.15 seq || seq=""; _drain_input
        case "$seq" in
          "[A") (( offset > 0 )) && (( offset-- )) ;;
          "[B") (( offset + view_h < total_lines )) && (( offset++ )) ;;
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

    # Key bar
    _at 2 1
    printf '%b%b[q]%b back  %b[↑↓/j/k]%b scroll  %b[g]%b top  %b[G]%b bottom  %b[l]%b logs  %b[e]%b exec  %b[r]%b restart%b' \
      "$BG_BAR" \
      "$C_CYAN" "$C_RESET$BG_BAR" \
      "$C_CYAN" "$C_RESET$BG_BAR" \
      "$C_CYAN" "$C_RESET$BG_BAR" \
      "$C_CYAN" "$C_RESET$BG_BAR" \
      "$C_CYAN" "$C_RESET$BG_BAR" \
      "$C_CYAN" "$C_RESET$BG_BAR" \
      "$C_CYAN" "$C_RESET$BG_BAR" \
      "$C_RESET"
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
      q|Q)
        # Exit describe, return to list
        DETAIL_MODE=false
        _clear
        return
        ;;
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

  # Restore raw mode BEFORE reading the dismiss key so it is consumed
  # cleanly in cbreak and does not leak into the main loop
  stty -echo  2>/dev/null || true
  stty cbreak 2>/dev/null || true
  tput civis  2>/dev/null || true
  _drain_input
  read -rsn1
  _drain_input

  DETAIL_MODE=false
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
    _hline "$row" "$col1" 50 "-" "$C_GRAY"
    (( row++ ))
  }

  _help_section "Navigation"
  _help_row "↑↓ / j k"     "Move selection up/down"
  _help_row "Enter"        "Describe / drill into selected resource"
  _help_row "Tab"          "Next view (cycles all 15)"
  _help_row "Shift-Tab"    "Previous view"
  _help_row "n"            "Pick namespace"
  _help_row "C"            "Pick context"
  _help_row "/"            "Filter current view"
  _help_row "Esc"          "Clear filter"

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

  _help_section "Views — Row 2 (10-15)"
  _help_row "0"            "10: ConfigMaps"
  _help_row "P"            "11: PersistentVolumeClaims"
  _help_row "i"            "12: Ingresses"
  _help_row "J"            "13: Jobs"
  _help_row "W"            "14: CronJobs"
  _help_row "A"            "15: HorizontalPodAutoscalers"

  _help_section "General"
  _help_row "?"            "This help screen"
  _help_row "R"            "Force refresh"
  _help_row "q / Ctrl-C"   "Quit / go back"

  (( row += 2 ))
  _at "$row" "$col1"
  printf '%bPress any key to return...%b' "$C_GRAY" "$C_RESET"
  _drain_input
  read -rsn1
  _drain_input
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
    printf '%b%b[q]%b back  %b[↑↓/j/k]%b scroll  %b[g]%b top  %b[G]%b bottom%b' \
      "$BG_BAR" \
      "$C_CYAN" "$C_RESET$BG_BAR" \
      "$C_CYAN" "$C_RESET$BG_BAR" \
      "$C_CYAN" "$C_RESET$BG_BAR" \
      "$C_CYAN" "$C_RESET$BG_BAR" \
      "$C_RESET"
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
      q|Q) _clear; return ;;
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

  _clear

  if (( now - LAST_REFRESH >= REFRESH_INTERVAL )); then
    _draw_header
    _draw_tabs
    _at 6 3
    printf '%b  fetching %s...%b' "$C_GRAY" "$CURRENT_VIEW" "$C_RESET"
    _refresh_data
    _clear
  fi

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

    # Drain any buffered input before blocking — kills ghost selects
    # from keys pressed during renders, kubectl calls, or sub-screens
    _drain_input

    # Read input with timeout for auto-refresh.
    # IMPORTANT: capture read's exit code separately.
    # When the timer expires read returns 1 and key stays "".
    # That empty string is identical to Enter, so we must NOT
    # fall through to the case statement on a timeout.
    local key=""
    local _read_rc=0
    IFS= read -rsn1 -t "$REFRESH_INTERVAL" key || _read_rc=$?

    # Exit code 1 from read means timeout — just loop to re-render.
    # Exit code >1 means a real error. Either way, skip key handling.
    (( _read_rc > 0 )) && continue

    case "$key" in

      # ── Quit ──────────────────────────────────────────────
      q|Q) exit 0 ;;

      # ── Help ──────────────────────────────────────────────
      '?') _show_help; _clear; DETAIL_MODE=false ;;

      # ── View switching ─ row 1 (1-9) ─────────────────────
      1|p) CURRENT_VIEW="pods";     SELECTED_IDX=0; FILTER=""; LAST_REFRESH=0; DETAIL_MODE=false; _clear ;;
      2)   CURRENT_VIEW="deploys";  SELECTED_IDX=0; FILTER=""; LAST_REFRESH=0; DETAIL_MODE=false; _clear ;;
      3)   CURRENT_VIEW="nodes";    SELECTED_IDX=0; FILTER=""; LAST_REFRESH=0; DETAIL_MODE=false; _clear ;;
      4)   CURRENT_VIEW="events";   SELECTED_IDX=0; FILTER=""; LAST_REFRESH=0; DETAIL_MODE=false; CURRENT_NS="all"; _clear ;;
      5|a) CURRENT_VIEW="argocd";   SELECTED_IDX=0; FILTER=""; LAST_REFRESH=0; DETAIL_MODE=false; _clear ;;
      6)   CURRENT_VIEW="certs";    SELECTED_IDX=0; FILTER=""; LAST_REFRESH=0; DETAIL_MODE=false; _clear ;;
      7|s) CURRENT_VIEW="secrets";  SELECTED_IDX=0; FILTER=""; LAST_REFRESH=0; DETAIL_MODE=false; _clear ;;
      8)   CURRENT_VIEW="services"; SELECTED_IDX=0; FILTER=""; LAST_REFRESH=0; DETAIL_MODE=false; _clear ;;
      9|h) CURRENT_VIEW="helm";     SELECTED_IDX=0; FILTER=""; LAST_REFRESH=0; DETAIL_MODE=false; _clear ;;

      # ── View switching — row 2 (10-15) ───────────────────
      0)   CURRENT_VIEW="configmaps"; SELECTED_IDX=0; FILTER=""; LAST_REFRESH=0; DETAIL_MODE=false; _clear ;;
      P)   CURRENT_VIEW="pvcs";       SELECTED_IDX=0; FILTER=""; LAST_REFRESH=0; DETAIL_MODE=false; _clear ;;
      i)   CURRENT_VIEW="ingresses";  SELECTED_IDX=0; FILTER=""; LAST_REFRESH=0; DETAIL_MODE=false; _clear ;;
      J)   CURRENT_VIEW="jobs";       SELECTED_IDX=0; FILTER=""; LAST_REFRESH=0; DETAIL_MODE=false; _clear ;;
      W)   CURRENT_VIEW="cronjobs";   SELECTED_IDX=0; FILTER=""; LAST_REFRESH=0; DETAIL_MODE=false; _clear ;;
      A)   CURRENT_VIEW="hpa";        SELECTED_IDX=0; FILTER=""; LAST_REFRESH=0; DETAIL_MODE=false; _clear ;;

      # ── Tab navigation ────────────────────────────────────
      $'\t')
        local views=("pods" "deploys" "nodes" "events" "argocd" "certs" "secrets" "services" "helm" "configmaps" "pvcs" "ingresses" "jobs" "cronjobs" "hpa")
        local cur_idx=0
        for i in "${!views[@]}"; do [[ "${views[$i]}" == "$CURRENT_VIEW" ]] && cur_idx=$i; done
        CURRENT_VIEW="${views[$(( (cur_idx+1) % ${#views[@]} ))]}"
        SELECTED_IDX=0; FILTER=""; LAST_REFRESH=0; DETAIL_MODE=false; _clear
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
          "") # Plain ESC — clear filter or back
            if [[ -n "$FILTER" ]]; then
              FILTER=""
            fi
            ;;
          "[Z") # Shift-Tab
            local views=("pods" "deploys" "nodes" "events" "argocd" "certs" "secrets" "services" "helm" "configmaps" "pvcs" "ingresses" "jobs" "cronjobs" "hpa")
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
          _pager_text "event › ${ev_obj}" "$(printf '%b' "$ev_detail")"
          LAST_REFRESH=0
          continue
        fi

        local res="pods"
        [[ "$CURRENT_VIEW" == "deploys"    ]] && res="deployment"
        [[ "$CURRENT_VIEW" == "nodes"      ]] && res="node" && ns="default"
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
        DETAIL_MODE=true
        _show_detail "$res" "$name" "$ns"
        DETAIL_MODE=false
        LAST_REFRESH=0
        _clear
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

      # ── Follow logs toggle ────────────────────────────────
      L)
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
