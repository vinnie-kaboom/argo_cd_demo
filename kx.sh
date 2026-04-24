#!/usr/bin/env bash

# kx — Kubernetes Cluster & Namespace Navigator
set -u

# ── Config ──────────────────────────────────────────────────
KX_VERSION="1.1.6"
KX_ALIASES="${HOME}/.kx_aliases"
KX_HISTORY="${HOME}/.kx_history"
KUBECONFIG="${KUBECONFIG:-${HOME}/.kube/config}"
OLD_STTY=""

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
require kubectl

# ── State & Alias Management ────────────────────────────────
declare -A ALIAS_TO_CTX
declare -A CTX_TO_ALIAS

load_aliases() {
  ALIAS_TO_CTX=(); CTX_TO_ALIAS=()
  [[ -f "$KX_ALIASES" ]] || return 0
  while IFS='=' read -r al ctx; do
    [[ -z "$al" || "$al" == \#* ]] && continue
    local a_clean="${al// /}"
    local c_clean="${ctx// /}"
    ALIAS_TO_CTX["$a_clean"]="$c_clean"
    CTX_TO_ALIAS["$c_clean"]="$a_clean"
  done < "$KX_ALIASES"
}

save_alias() {
  local al="$1" ctx="$2"
  touch "$KX_ALIASES"
  local tmp=$(grep -v "^${al}=" "$KX_ALIASES" 2>/dev/null || true)
  echo "$tmp" > "$KX_ALIASES"
  echo "${al}=${ctx}" >> "$KX_ALIASES"
  ok "Alias ${YELLOW}${al}${RESET} → ${CYAN}${ctx}${RESET} saved"
}

push_history() {
  local current=$(kubectl config current-context 2>/dev/null || echo "")
  [[ -z "$current" ]] && return 0
  touch "$KX_HISTORY"
  local tmp=$(grep -v "^${current}$" "$KX_HISTORY" 2>/dev/null || true)
  { echo "$current"; echo "$tmp"; } | head -20 > "${KX_HISTORY}.tmp"
  mv "${KX_HISTORY}.tmp" "$KX_HISTORY"
}

# ── K8s Core Helpers ────────────────────────────────────────
current_context() { kubectl config current-context 2>/dev/null || echo ""; }
all_contexts() { kubectl config get-contexts -o name 2>/dev/null | sort; }
current_ns() { kubectl config view --minify --output 'jsonpath={..namespace}' 2>/dev/null || echo "default"; }

switch_context() {
  local ctx="$1"
  push_history
  kubectl config use-context "$ctx" &>/dev/null
  load_aliases
  local al=""
  [[ -n "${CTX_TO_ALIAS[$ctx]:-}" ]] && al=" ${GRAY}(${CTX_TO_ALIAS[$ctx]})${RESET}"
  ok "Context: ${CYAN}${BOLD}${ctx}${RESET}${al}"
  echo "  ${GRAY}namespace:${RESET} ${YELLOW}$(current_ns)${RESET}"
}

# ── TUI Picker ──────────────────────────────────────────────
_picker() {
  local items=("$@")
  local selected=0
  local query=""
  local tmp_choice="/tmp/kx_choice"
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
    printf "\n  ${BOLD}${WHITE}KUBERNETES NAVIGATOR${RESET}\n"
    printf "  ${GRAY}${hr}${RESET}\n"
    printf "  ${CYAN}»${RESET} search: ${WHITE}%s${RESET}${CYAN}▌${RESET}\n" "$query"
    printf "  ${GRAY}${hr}${RESET}\n"

    for i in "${!filtered[@]}"; do
      (( i > 12 )) && break 
      local name="${filtered[$i]}"
      local marker="   "
      [[ "$name" == "$(current_context)" ]] && marker="${GREEN}●  ${RESET}"

      if (( i == selected )); then
        printf "${BG_SELECT}${CYAN}  ▶ ${marker}${BOLD}%-34s${RESET}\n" "$name"
      else
        printf "    ${marker}%-34s \n" "$name"
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
  load_aliases
  local contexts=($(all_contexts))
  local current=$(current_context)
  local hr="──────────────────────────────────────────────────"

  echo -e "\n  ${BOLD}${WHITE}Kubernetes Contexts${RESET}"
  echo -e "  ${GRAY}${hr}${RESET}"

  for ctx in "${contexts[@]}"; do
    local marker="  "
    local color="$WHITE"
    [[ "$ctx" == "$current" ]] && marker="${GREEN}●${RESET} " && color="$GREEN"

    local al_label=""
    [[ -n "${CTX_TO_ALIAS[$ctx]:-}" ]] && al_label=" ${GRAY}[${CTX_TO_ALIAS[$ctx]}]${RESET}"

    # Extract cluster/user for more detail
    local cluster=$(kubectl config view -o jsonpath="{.contexts[?(@.name==\"$ctx\")].context.cluster}" 2>/dev/null)
    
    printf "  %b%b%-25s%b%b ${GRAY}(%s)${RESET}\n" "$marker" "$color" "$ctx" "$RESET" "$al_label" "$cluster"
  done
  echo -e "  ${GRAY}${hr}${RESET}\n"
}

cmd_info() {
  local ctx=$(current_context)
  [[ -z "$ctx" ]] && die "No active context"
  
  local cluster=$(kubectl config view -o jsonpath="{.contexts[?(@.name==\"$ctx\")].context.cluster}" 2>/dev/null)
  local server=$(kubectl config view -o jsonpath="{.clusters[?(@.name==\"$cluster\")].cluster.server}" 2>/dev/null)
  local user=$(kubectl config view -o jsonpath="{.contexts[?(@.name==\"$ctx\")].context.user}" 2>/dev/null)
  local ns=$(current_ns)

  echo -e "\n  ${BOLD}${WHITE}Active Context Details${RESET}"
  echo -e "  ${GRAY}──────────────────────────────────────────────────${RESET}"
  printf "  ${CYAN}%-12s${RESET} %s\n" "Context:"   "${BOLD}${ctx}${RESET}"
  printf "  ${CYAN}%-12s${RESET} %s\n" "Cluster:"   "$cluster"
  printf "  ${CYAN}%-12s${RESET} %s\n" "Server:"    "${BLUE}$server${RESET}"
  printf "  ${CYAN}%-12s${RESET} %s\n" "User:"      "$user"
  printf "  ${CYAN}%-12s${RESET} %s\n" "Namespace:" "${YELLOW}$ns${RESET}"
  echo -e "  ${GRAY}──────────────────────────────────────────────────${RESET}\n"
}

cmd_status() {
  local ctx=$(current_context)
  [[ -z "$ctx" ]] && die "No active context"
  info "Status for ${CYAN}${ctx}${RESET}..."
  echo -e "\n  ${BOLD}Nodes${RESET}"
  kubectl get nodes 2>/dev/null | sed 's/^/  /' || warn "API unreachable"
  echo -e "\n  ${BOLD}Unhealthy Pods${RESET}"
  local bad=$(kubectl get pods -A 2>/dev/null | grep -vE "Running|Completed" | grep -v "NAMESPACE" || true)
  [[ -z "$bad" ]] && ok "All pods healthy" || echo "$bad" | sed 's/^/  /'
}

cmd_ns() {
  local ns="${1:-}"
  if [[ -z "$ns" ]]; then
    local list=($(kubectl get ns -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' | sort))
    _picker "${list[@]}"
    [[ -f "/tmp/kx_choice" ]] && ns=$(cat /tmp/kx_choice) && rm -f "/tmp/kx_choice" || return
  fi
  [[ -n "$ns" ]] && kubectl config set-context "$(current_context)" --namespace="$ns" &>/dev/null && ok "Namespace → ${YELLOW}${ns}${RESET}"
}

# ── Main ────────────────────────────────────────────────────
main() {
  load_aliases
  local arg="${1:-}"

  case "$arg" in
    --help|-h)
      cat <<EOF
  ${BOLD}${CYAN}kx${RESET} v${KX_VERSION}
  kx                Interactive context switch
  kx <name|alias>   Switch by name
  kx -              Previous context
  kx --list | -l    List all contexts
  kx --info         Detailed current context info
  kx --ns | -n      Namespace picker
  kx --status       Quick health check
  kx --alias <c> <a> Set alias
  kx --delete <c>   Delete context
EOF
      ;;
    --list|-l) cmd_list ;;
    --info) cmd_info ;;
    --status) cmd_status ;;
    --ns|-n) cmd_ns "${2:-}" ;;
    --alias) [[ $# -lt 3 ]] && die "Use: kx --alias <context> <alias>"; save_alias "$3" "$2" ;;
    --delete) [[ $# -lt 2 ]] && die "Use: kx --delete <context>"; kubectl config delete-context "$2" && ok "Deleted $2" ;;
    -) local prev=$(head -1 "$KX_HISTORY" 2>/dev/null || echo ""); [[ -n "$prev" ]] && switch_context "$prev" || die "No history" ;;
    "")
      local ctxs=($(all_contexts))
      _picker "${ctxs[@]}"
      if [[ -f "/tmp/kx_choice" ]]; then
        local chosen=$(cat /tmp/kx_choice); rm -f "/tmp/kx_choice"
        clear; switch_context "$chosen"
      fi
      ;;
    *)
      local resolved="${ALIAS_TO_CTX[$arg]:-$arg}"
      kubectl config get-contexts "$resolved" &>/dev/null && switch_context "$resolved" || die "Unknown context: $arg"
      ;;
  esac
}

main "$@"
