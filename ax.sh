#!/usr/bin/env bash

# ax — Argo CD Application Navigator
set -u

# ── Config ──────────────────────────────────────────────────
AX_VERSION="1.0.0"
OLD_STTY=""
# Argo CD usually lives in 'argocd' namespace
ARGO_NS="${ARGO_NAMESPACE:-argocd}"

# ── Colors ──────────────────────────────────────────────────
BOLD=$'\e[1m'; RESET=$'\e[0m'; GREEN=$'\e[32m'; CYAN=$'\e[36m'
WHITE=$'\e[37m'; GRAY=$'\e[90m'; BG_SELECT=$'\e[48;5;236m'; RED=$'\e[31m'
YELLOW=$'\e[33m'; BLUE=$'\e[34m'; MAGENTA=$'\e[35m'

# ── Helpers ─────────────────────────────────────────────────
die() { echo -e "${RED}✗ error:${RESET} $*" >&2; exit 1; }
ok() { echo -e "${GREEN}✓${RESET} $*"; }
info() { echo -e "${CYAN}→${RESET} $*"; }

require() { command -v "$1" &>/dev/null || die "'$1' is required."; }
require kubectl

# ── Argo Core Logic ─────────────────────────────────────────

all_apps() {
  # Returns: Name, Health Status, Sync Status, Destination Namespace
  kubectl get applications.argoproj.io -n "$ARGO_NS" -o json 2>/dev/null | \
  python3 -c "
import json,sys
try:
    data=json.load(sys.stdin)
    for r in data['items']:
        name = r['metadata']['name']
        health = r.get('status', {}).get('health', {}).get('status', 'Unknown')
        sync = r.get('status', {}).get('sync', {}).get('status', 'Unknown')
        dest = r.get('spec', {}).get('destination', {}).get('namespace', 'unknown')
        print(f\"{name}\t{health}\t{sync}\t{dest}\")
except Exception as e: pass"
}

health_color() {
  case "$1" in
    Healthy)   printf '%b' "$GREEN" ;;
    Degraded)  printf '%b' "$RED" ;;
    Progressing) printf '%b' "$BLUE" ;;
    *)         printf '%b' "$YELLOW" ;;
  esac
}

sync_color() {
  case "$1" in
    Synced)    printf '%b' "$GREEN" ;;
    OutOfSync) printf '%b' "$YELLOW" ;;
    *)         printf '%b' "$RED" ;;
  esac
}

# ── The Stable TUI Picker ───────────────────────────────────
_picker() {
  local items=("$@")
  local selected=0
  local query=""
  local tmp_choice="/tmp/ax_choice"
  local hr="──────────────────────────────────────────"
  rm -f "$tmp_choice"
  
  OLD_STTY=$(stty -g)
  stty -echo -icanon isig min 1 time 0
  
  exec 3>&1; exec 1>/dev/tty
  tput civis
  
  cleanup() {
    [[ -n "$OLD_STTY" ]] && stty "$OLD_STTY"
    tput cnorm; exec 1>&3
  }
  trap cleanup EXIT INT TERM

  while true; do
    local filtered=()
    for item in "${items[@]}"; do
      [[ -z "$query" ]] || [[ "$item" == *"$query"* ]] && filtered+=("$item")
    done
    local fcount=${#filtered[@]}
    (( selected >= fcount && fcount > 0 )) && selected=$(( fcount - 1 ))
    (( selected < 0 )) && selected=0

    clear
    printf "\n  ${BOLD}${WHITE}ARGO CD APP NAVIGATOR${RESET}\n"
    printf "  ${GRAY}${hr}${RESET}\n"
    printf "  ${CYAN}»${RESET} search: ${WHITE}%s${RESET}${CYAN}▌${RESET}\n" "$query"
    printf "  ${GRAY}${hr}${RESET}\n"

    for i in "${!filtered[@]}"; do
      (( i > 12 )) && break 
      local name="${filtered[$i]}"
      if (( i == selected )); then
        printf "${BG_SELECT}${CYAN}  ▶  ${BOLD}%-36s${RESET}\n" "$name"
      else
        printf "     %-36s \n" "$name"
      fi
    done

    printf "  ${GRAY}${hr}${RESET}\n"
    printf "  ${GRAY}arrows: move | enter: select | q: quit${RESET}\n"

    local char=$(dd bs=3 count=1 2>/dev/null)
    case "$char" in
      $'\x1b[A') (( selected > 0 )) && (( selected-- )) ;;
      $'\x1b[B') (( selected < fcount - 1 )) && (( selected++ )) ;;
      $'\x0a'|$'\r'|"") [[ $fcount -gt 0 ]] && { echo "${filtered[$selected]}" > "$tmp_choice"; break; } ;;
      $'\x1b'|q|Q) break ;;
      $'\x7f'|$'\b') query="${query%?}" ;;
      *) if [[ "$char" =~ [[:print:]] ]] && [[ ${#char} -eq 1 ]]; then query+="$char"; selected=0; fi ;;
    esac
  done
  cleanup
  trap - EXIT INT TERM
}

# ── Subcommands ─────────────────────────────────────────────

cmd_list() {
  echo -e "\n  ${BOLD}${WHITE}Argo CD Applications${RESET} ${GRAY}(ns: $ARGO_NS)${RESET}"
  echo -e "  ${GRAY}──────────────────────────────────────────────────────────────────${RESET}"
  printf "  ${CYAN}%-25s %-12s %-12s %s${RESET}\n" "NAME" "HEALTH" "SYNC" "DEST-NS"
  
  while IFS=$'\t' read -r name health sync dest; do
    local hc=$(health_color "$health")
    local sc=$(sync_color "$sync")
    printf "  %-25s %b%-12s%b %b%-12s%b %s\n" "$name" "$hc" "$health" "$RESET" "$sc" "$sync" "$RESET" "$dest"
  done < <(all_apps)
  echo ""
}

cmd_sync() {
  local name="$1"
  info "Patching App ${CYAN}$name${RESET} to initiate sync..."
  # This tells Argo CD to sync via kubectl patch
  kubectl patch application "$name" -n "$ARGO_NS" --type merge -p '{"spec":{"source":{"targetRevision":"HEAD"}}}' &>/dev/null
  ok "Sync signaled for $name"
}

# ── Main ────────────────────────────────────────────────────
main() {
  local arg="${1:-}"

  case "$arg" in
    --help|-h)
      cat <<EOF
  ${BOLD}${MAGENTA}ax${RESET} v${AX_VERSION}
  ax                Interactive App picker
  ax <name>         Show App details (YAML)
  ax --list | -l    List all Argo Apps
  ax --sync         Trigger a manual sync
  ax --delete       Remove an application
EOF
      ;;
    --list|-l) cmd_list ;;
    --sync) [[ -z "${2:-}" ]] && die "Need app name"; cmd_sync "$2" ;;
    --delete) [[ -z "${2:-}" ]] && die "Need app name"; kubectl delete application "$2" -n "$ARGO_NS" ;;
    "")
      local list=($(all_apps | awk '{print $1}'))
      if [[ ${#list[@]} -eq 0 ]]; then
        die "No Argo CD Applications found in namespace '$ARGO_NS'.\nTry: export ARGO_NAMESPACE=your-namespace"
      fi
      _picker "${list[@]}"
      if [[ -f "/tmp/ax_choice" ]]; then
        local chosen=$(cat /tmp/ax_choice); rm -f "/tmp/ax_choice"
        clear
        # Show a summary using describe
        kubectl describe application "$chosen" -n "$ARGO_NS" | head -n 30
      fi
      ;;
    *)
      kubectl get application "$arg" -n "$ARGO_NS" -o yaml | head -n 50
      ;;
  esac
}

main "$@"
