#!/usr/bin/env bash

# ax — Argo CD Application Navigator (No-Python Version)
set -u

# ── Config ──────────────────────────────────────────────────
AX_VERSION="1.0.1"
OLD_STTY=""
ARGO_NS="${ARGO_NAMESPACE:-argocd}"

# ── Colors ──────────────────────────────────────────────────
BOLD=$'\e[1m'; RESET=$'\e[0m'; GREEN=$'\e[32m'; CYAN=$'\e[36m'
WHITE=$'\e[37m'; GRAY=$'\e[90m'; BG_SELECT=$'\e[48;5;236m'; RED=$'\e[31m'
YELLOW=$'\e[33m'; BLUE=$'\e[34m'; MAGENTA=$'\e[35m'

# ── Helpers ─────────────────────────────────────────────────
die() { echo -e "\n${RED}✗ error:${RESET} $*" >&2; exit 1; }
ok() { echo -e "${GREEN}✓${RESET} $*"; }
info() { echo -e "${CYAN}→${RESET} $*"; }

require() { command -v "$1" &>/dev/null || die "'$1' is required."; }
require kubectl

# ── Argo Core Logic ─────────────────────────────────────────

all_apps() {
  # We try to use kubectl's built-in go-template to avoid python or jq dependencies
  kubectl get applications.argoproj.io -n "$ARGO_NS" -o go-template='{{range .items}}{{.metadata.name}}{{"\t"}}{{.status.health.status}}{{"\t"}}{{.status.sync.status}}{{"\t"}}{{.spec.destination.namespace}}{{"\n"}}{{end}}' 2>/dev/null | grep -v '^$'
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
  local apps
  apps=$(all_apps)
  if [[ -z "$apps" ]]; then
     info "No applications found in namespace '$ARGO_NS'."
     return
  fi

  echo -e "\n  ${BOLD}${WHITE}Argo CD Applications${RESET} ${GRAY}(ns: $ARGO_NS)${RESET}"
  echo -e "  ${GRAY}──────────────────────────────────────────────────────────────────${RESET}"
  printf "  ${CYAN}%-25s %-12s %-12s %s${RESET}\n" "NAME" "HEALTH" "SYNC" "DEST-NS"
  
  echo "$apps" | while IFS=$'\t' read -r name health sync dest; do
    local hc=$(health_color "$health")
    local sc=$(sync_color "$sync")
    printf "  %-25s %b%-12s%b %b%-12s%b %s\n" "$name" "$hc" "${health:-Unknown}" "$RESET" "$sc" "${sync:-Unknown}" "$RESET" "${dest:-unknown}"
  done
  echo ""
}

# ── Main ────────────────────────────────────────────────────
main() {
  local arg="${1:-}"

  case "$arg" in
    --help|-h)
      cat <<EOF
  ${BOLD}${MAGENTA}ax${RESET} v${AX_VERSION}
  ax                Interactive App picker
  ax <name>         Show App details
  ax --list | -l    List all Argo Apps
  ax --sync         Trigger manual sync
EOF
      ;;
    --list|-l) cmd_list ;;
    --sync) [[ -z "${2:-}" ]] && die "Need app name"; kubectl patch application "$2" -n "$ARGO_NS" --type merge -p '{"spec":{"source":{"targetRevision":"HEAD"}}}' ;;
    "")
      local list
      list=($(all_apps | awk '{print $1}'))
      if [[ ${#list[@]} -eq 0 ]]; then
        die "No Argo CD Applications found in namespace '$ARGO_NS'.\nIf Argo lives elsewhere, try: export ARGO_NAMESPACE=custom-ns"
      fi
      _picker "${list[@]}"
      if [[ -f "/tmp/ax_choice" ]]; then
        local chosen=$(cat /tmp/ax_choice); rm -f "/tmp/ax_choice"
        clear
        kubectl describe application "$chosen" -n "$ARGO_NS" | head -n 40
      fi
      ;;
    *)
      kubectl get application "$arg" -n "$ARGO_NS" -o yaml | head -n 50
      ;;
  esac
}

main "$@"
