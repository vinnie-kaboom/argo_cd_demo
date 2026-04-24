#!/usr/bin/env bash

# hx — Helm Release Navigator (Codespaces Edition)
set -u

# ── Config ──────────────────────────────────────────────────
HX_VERSION="1.1.0"
OLD_STTY=""
HX_NS="${HX_NAMESPACE:-}" # Scoped via -n or ENV

# ── Colors ──────────────────────────────────────────────────
BOLD=$'\e[1m'; RESET=$'\e[0m'; GREEN=$'\e[32m'; CYAN=$'\e[36m'
WHITE=$'\e[37m'; GRAY=$'\e[90m'; BG_SELECT=$'\e[48;5;236m'; RED=$'\e[31m'
YELLOW=$'\e[33m'; BLUE=$'\e[34m'; DIM=$'\e[2m'

# ── Helpers ─────────────────────────────────────────────────
die() { echo -e "${RED}✗ error:${RESET} $*" >&2; exit 1; }
ok() { echo -e "${GREEN}✓${RESET} $*"; }
info() { echo -e "${CYAN}→${RESET} $*"; }
warn() { echo -e "${YELLOW}⚠${RESET} $*"; }

require() { command -v "$1" &>/dev/null || die "'$1' is required."; }
require helm

# ── Helm Core Logic ─────────────────────────────────────────
ns_flags() { [[ -n "$HX_NS" ]] && echo "-n ${HX_NS}" || echo "--all-namespaces"; }

status_color() {
  case "$1" in
    deployed) printf '%b' "$GREEN" ;;
    failed)   printf '%b' "$RED" ;;
    pending*) printf '%b' "$YELLOW" ;;
    *)        printf '%b' "$GRAY" ;;
  esac
}

all_releases() {
  helm list $(ns_flags) --output json 2>/dev/null | \
  python3 -c "
import json,sys
try:
    data=json.load(sys.stdin)
    for r in data:
        print(f\"{r['name']}\t{r['namespace']}\t{r['status']}\t{r['chart']}\")
except: pass"
}

# ── The Stable TUI Picker ───────────────────────────────────
_picker() {
  local items=("$@")
  local selected=0
  local query=""
  local tmp_choice="/tmp/hx_choice"
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
    printf "\n  ${BOLD}${WHITE}HELM RELEASE NAVIGATOR${RESET}\n"
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
      *) if [[ "$char" =~ [[:print:]] ]]; then query+="$char"; selected=0; fi ;;
    esac
  done
  cleanup
  trap - EXIT INT TERM
}

# ── Subcommands ─────────────────────────────────────────────

cmd_list() {
  echo -e "\n  ${BOLD}${WHITE}Helm Releases${RESET} ${GRAY}($(ns_flags))${RESET}"
  echo -e "  ${GRAY}──────────────────────────────────────────────────────────────────${RESET}"
  printf "  ${CYAN}%-20s %-15s %-12s %s${RESET}\n" "NAME" "NAMESPACE" "STATUS" "CHART"
  
  while IFS=$'\t' read -r name ns status chart; do
    local sc=$(status_color "$status")
    printf "  %-20s %-15s %b%-12s%b %s\n" "$name" "$ns" "$sc" "$status" "$RESET" "$chart"
  done < <(all_releases)
  echo ""
}

cmd_history() {
  local name="$1"
  local ns=$(helm list --all-namespaces --output json | python3 -c "import json,sys; d=json.load(sys.stdin); print([r['namespace'] for r in d if r['name']=='$name'][0])" 2>/dev/null || echo "default")
  
  echo -e "\n  ${BOLD}${WHITE}History: ${CYAN}${name}${RESET}"
  echo -e "  ${GRAY}──────────────────────────────────────────────────────────────────${RESET}"
  helm history "$name" -n "$ns" --max 10 | sed 's/^/  /'
  echo ""
}

cmd_diff() {
  local name="$1"
  local ns=$(helm list --all-namespaces --output json | python3 -c "import json,sys; d=json.load(sys.stdin); print([r['namespace'] for r in d if r['name']=='$name'][0])" 2>/dev/null || echo "default")
  
  info "Diffing last two revisions for ${CYAN}${name}${RESET}..."
  local revs=$(helm history "$name" -n "$ns" --output json | python3 -c "import json,sys; print(len(json.load(sys.stdin)))" 2>/dev/null || echo 0)
  
  if (( revs < 2 )); then warn "Not enough revisions to diff."; return; fi
  
  local t1=$(mktemp); local t2=$(mktemp)
  helm get manifest "$name" -n "$ns" --revision $((revs-1)) > "$t1"
  helm get manifest "$name" -n "$ns" --revision "$revs" > "$t2"
  diff -u --color=always "$t1" "$t2" || echo "No changes found."
  rm -f "$t1" "$t2"
}

# ── Main ────────────────────────────────────────────────────
main() {
  # Parse -n early
  local temp_args=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -n|--namespace) HX_NS="$2"; shift 2 ;;
      *) temp_args+=("$1"); shift ;;
    esac
  done
  set -- "${temp_args[@]:-}"

  local arg="${1:-}"

  case "$arg" in
    --help|-h)
      cat <<EOF
  ${BOLD}${CYAN}hx${RESET} v${HX_VERSION}
  hx                Interactive release picker
  hx <name>         Quick status
  hx --list | -l    List all releases
  hx --history      Show revision history
  hx --diff         Diff last two revisions
  hx --values       Show merged values
  hx --uninstall    Remove a release
EOF
      ;;
    --list|-l) cmd_list ;;
    --history) [[ -z "${2:-}" ]] && die "Need release name"; cmd_history "$2" ;;
    --diff)    [[ -z "${2:-}" ]] && die "Need release name"; cmd_diff "$2" ;;
    --values)  [[ -z "${2:-}" ]] && die "Need release name"; helm get values "$2" $(ns_flags) ;;
    --uninstall) [[ -z "${2:-}" ]] && die "Need release name"; helm uninstall "$2" $(ns_flags) ;;
    "")
      local list=($(all_releases | awk '{print $1}'))
      _picker "${list[@]}"
      if [[ -f "/tmp/hx_choice" ]]; then
        local chosen=$(cat /tmp/hx_choice); rm -f "/tmp/hx_choice"
        clear; helm status "$chosen" $(ns_flags)
      fi
      ;;
    *)
      helm status "$arg" $(ns_flags) 2>/dev/null || die "Release not found: $arg"
      ;;
  esac
}

main "$@"
