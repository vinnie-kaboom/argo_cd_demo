#!/usr/bin/env bash

# kx — Minimalist Kubernetes Context Navigator
set -u

# ── Colors ─────────────────────────────────────────────────
BOLD=$'\e[1m'; RESET=$'\e[0m'; GREEN=$'\e[32m'; CYAN=$'\e[36m'
WHITE=$'\e[37m'; GRAY=$'\e[90m'; BG_SELECT=$'\e[48;5;236m'; RED=$'\e[31m'

# Initialize global state for the trap to see
OLD_STTY=""

_picker() {
  local items=("$@")
  local selected=0
  local query=""
  local tmp_choice="/tmp/kx_choice"
  local hr="──────────────────────────────────────────"
  rm -f "$tmp_choice"
  
  # Set global state so cleanup trap works
  OLD_STTY=$(stty -g)
  stty -echo -icanon isig min 1 time 0
  
  exec 3>&1          
  exec 1>/dev/tty    

  tput civis
  
  cleanup() {
    # Only restore if we actually have a saved state
    [[ -n "$OLD_STTY" ]] && stty "$OLD_STTY"
    tput cnorm
    exec 1>&3
  }
  trap cleanup EXIT INT TERM

  while true; do
    local filtered=()
    for item in "${items[@]}"; do
      if [[ -z "$query" ]] || [[ "$item" == *"$query"* ]]; then
        filtered+=("$item")
      fi
    done
    local fcount=${#filtered[@]}
    
    (( selected >= fcount && fcount > 0 )) && selected=$(( fcount - 1 ))
    (( selected < 0 )) && selected=0

    clear
    printf "\n  ${BOLD}${WHITE}KUBERNETES CONTEXTS${RESET}\n"
    printf "  ${GRAY}${hr}${RESET}\n"
    printf "  ${CYAN}»${RESET} search: ${WHITE}%s${RESET}${CYAN}▌${RESET}\n" "$query"
    printf "  ${GRAY}${hr}${RESET}\n"

    for i in "${!filtered[@]}"; do
      (( i > 12 )) && break 
      local item_name="${filtered[$i]}"
      if (( i == selected )); then
        printf "${BG_SELECT}${CYAN}  ▶  ${BOLD}%-36s${RESET}\n" "$item_name"
      else
        printf "     %-36s \n" "$item_name"
      fi
    done

    printf "  ${GRAY}${hr}${RESET}\n"
    printf "  ${GRAY}arrows: navigate | enter: select | q: quit${RESET}\n"

    local char=$(dd bs=3 count=1 2>/dev/null)
    
    case "$char" in
      $'\x1b[A') (( selected > 0 )) && (( selected-- )) ;;
      $'\x1b[B') (( selected < fcount - 1 )) && (( selected++ )) ;;
      $'\x0a'|$'\r'|"") 
        if (( fcount > 0 )); then
          echo "${filtered[$selected]}" > "$tmp_choice"
          break
        fi ;;
      $'\x1b'|q|Q) break ;;
      $'\x7f'|$'\b') query="${query%?}" ;;
      *) if [[ "$char" =~ [[:print:]] ]]; then query+="$char"; selected=0; fi ;;
    esac
  done

  cleanup
  # Clear the trap so it doesn't run again on main exit
  trap - EXIT INT TERM
}

main() {
  if [[ -n "${1:-}" ]]; then
    kubectl config use-context "$1" &>/dev/null && echo -e "${GREEN}✓${RESET} Switched to $1" || echo "✗ Failed"
    exit 0
  fi

  # Robust context fetching
  local contexts
  mapfile -t contexts < <(kubectl config get-contexts -o name 2>/dev/null | sort)
  
  if [[ ${#contexts[@]} -eq 0 ]]; then
    echo "No contexts found."
    exit 1
  fi

  _picker "${contexts[@]}"
  
  if [[ -f "/tmp/kx_choice" ]]; then
    local chosen=$(cat /tmp/kx_choice)
    rm -f "/tmp/kx_choice"
    clear
    if kubectl config use-context "$chosen" &>/dev/null; then
      echo -e "${GREEN}✓${RESET} Context: ${CYAN}${BOLD}${chosen}${RESET}"
    fi
  else
    clear
    echo "Cancelled."
  fi
}

main "$@"
