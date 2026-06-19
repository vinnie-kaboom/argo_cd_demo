#!/usr/bin/env bash
# argocd-doctor.sh — environment health check for ArgoCD on Kind/Codespaces

set -uo pipefail

# ─── colours & formatting ────────────────────────────────────────────────────
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ─── state ───────────────────────────────────────────────────────────────────
PASS=0
FAIL=0
WARN=0
FAILURES=()

# ─── helpers ─────────────────────────────────────────────────────────────────
ts() { date '+%H:%M:%S'; }

header() {
  echo
  echo -e "${BOLD}${CYAN}== ArgoCD Doctor  [$(ts)] ==${NC}"
  echo
}

section() {
  echo
  echo -e "${BOLD}── $* ──${NC}"
}

check() {
  # check "label" cmd [args...]
  local label="$1"; shift
  printf "  %-50s" "$label"
  local output
  if output=$("$@" 2>&1); then
    echo -e "${GREEN}✔ ok${NC}"
    ((PASS++)) || true
    return 0
  else
    echo -e "${RED}✘ FAILED${NC}"
    echo -e "    ${RED}↳ ${output}${NC}"
    ((FAIL++)) || true
    FAILURES+=("$label")
    return 1
  fi
}

warn() {
  local label="$1"; shift
  printf "  %-50s" "$label"
  local output
  if output=$("$@" 2>&1); then
    echo -e "${GREEN}✔ ok${NC}"
    ((PASS++)) || true
  else
    echo -e "${YELLOW}⚠ warn${NC}"
    echo -e "    ${YELLOW}↳ ${output}${NC}"
    ((WARN++)) || true
  fi
}

info() {
  # info "label" — just prints the label indented (for display-only blocks)
  echo -e "  ${CYAN}▸ $*${NC}"
}

fatal_check() {
  # like check() but exits the whole script on failure
  if ! check "$@"; then
    echo
    echo -e "${RED}${BOLD}Fatal: cannot continue. Fix the above and re-run.${NC}"
    exit 1
  fi
}

rollout_ok() {
  local deploy="$1"
  kubectl rollout status deployment/"$deploy" -n argocd --timeout=10s >/dev/null 2>&1
}

# ─── script ──────────────────────────────────────────────────────────────────
header

# ── 1. Local tooling ──────────────────────────────────────────────────────────
section "1/9  Local tooling"

fatal_check "kubectl binary present"        kubectl version --client
fatal_check "cluster reachable"             kubectl cluster-info

warn        "argocd CLI present"            which argocd
warn        "argocd CLI logged in"          argocd account get-user-info --grpc-web 2>/dev/null

echo
info "kubectl client version: $(kubectl version --client --short 2>/dev/null || kubectl version --client | head -n1)"

# ── 2. Namespace & core objects ───────────────────────────────────────────────
section "2/9  Namespace & core objects"

fatal_check "argocd namespace exists"       kubectl get ns argocd
check       "argocd-server Service"         kubectl get svc -n argocd argocd-server
check       "argocd-repo-server Service"    kubectl get svc -n argocd argocd-repo-server
check       "argocd-redis Service"          kubectl get svc -n argocd argocd-redis
warn        "initial-admin-secret present"  kubectl get secret -n argocd argocd-initial-admin-secret

# ── 3. Deployment rollout health ──────────────────────────────────────────────
section "3/9  Deployment rollout health"

for deploy in argocd-server argocd-repo-server argocd-application-controller argocd-dex-server argocd-redis; do
  check "rollout: $deploy" rollout_ok "$deploy"
done

# ── 4. Pod summary ────────────────────────────────────────────────────────────
section "4/9  Pod summary (argocd namespace)"
echo
kubectl get pods -n argocd \
  -o custom-columns='NAME:.metadata.name,READY:.status.containerStatuses[*].ready,STATUS:.status.phase,RESTARTS:.status.containerStatuses[*].restartCount,AGE:.metadata.creationTimestamp' \
  2>/dev/null || kubectl get pods -n argocd

# ── 5. Pods with restarts or bad phase ───────────────────────────────────────
section "5/9  Restart / bad-phase warnings"
echo
UNHEALTHY=$(kubectl get pods -n argocd --no-headers 2>/dev/null \
  | awk '$3 != "Running" && $3 != "Completed" { print }')
RESTARTS=$(kubectl get pods -n argocd --no-headers 2>/dev/null \
  | awk '$4 > 0 { print "  restarts=" $4, $1 }')

if [[ -z "$UNHEALTHY" && -z "$RESTARTS" ]]; then
  echo -e "  ${GREEN}✔ all pods healthy, no unexpected restarts${NC}"
else
  [[ -n "$UNHEALTHY" ]] && echo -e "${RED}  Unhealthy pods:${NC}\n$UNHEALTHY"
  [[ -n "$RESTARTS" ]] && echo -e "${YELLOW}  Pods with restarts:${NC}\n$RESTARTS"
  ((WARN++)) || true
fi

# ── 6. repo-server diagnostics ───────────────────────────────────────────────
section "6/9  repo-server diagnostics"
echo
REPO_PODS=$(kubectl get pods -n argocd -l app.kubernetes.io/name=argocd-repo-server -o name 2>/dev/null)
if [[ -z "$REPO_PODS" ]]; then
  echo -e "  ${RED}No repo-server pods found.${NC}"
  ((FAIL++)) || true
  FAILURES+=("repo-server pods present")
else
  for pod in $REPO_PODS; do
    phase=$(kubectl get "$pod" -n argocd -o jsonpath='{.status.phase}' 2>/dev/null || echo "unknown")
    color=$GREEN
    [[ "$phase" != "Running" ]] && color=$RED
    echo -e "  ${BOLD}$pod${NC}  →  phase: ${color}${phase}${NC}"
    echo
    echo "  Last 20 lines of describe events:"
    kubectl describe "$pod" -n argocd 2>/dev/null \
      | awk '/^Events:/,0' \
      | tail -n 20 \
      | sed 's/^/    /'
    echo
  done
fi

# ── 7. cert-manager (optional) ───────────────────────────────────────────────
section "7/9  cert-manager (optional)"
if kubectl get ns cert-manager >/dev/null 2>&1; then
  check "cert-manager namespace"          kubectl get ns cert-manager
  check "cert-manager deployment healthy" rollout_ok cert-manager
  warn  "argocd Certificate resource"     kubectl get certificate -n argocd
else
  echo -e "  ${YELLOW}⚠ cert-manager namespace not found — skipping TLS checks${NC}"
fi

# ── 8. Port-forward status ────────────────────────────────────────────────────
section "8/9  Port-forward & local listeners"
echo

if [[ -f /tmp/argocd-portforward.log ]]; then
  info "Last 20 lines of /tmp/argocd-portforward.log:"
  tail -n 20 /tmp/argocd-portforward.log | sed 's/^/    /'
else
  echo -e "  ${YELLOW}⚠ /tmp/argocd-portforward.log not found (port-forward not started?)${NC}"
fi

echo
for port in 8080 8081 8443; do
  if ss -ltn 2>/dev/null | grep -q ":${port} "; then
    echo -e "  ${GREEN}✔ listener on :${port}${NC}"
  else
    echo -e "  ${YELLOW}–  no listener on :${port}${NC}"
  fi
done

# ── 9. ArgoCD Applications ────────────────────────────────────────────────────
section "9/9  ArgoCD Applications"
echo
if kubectl get applications -n argocd >/dev/null 2>&1; then
  APP_COUNT=$(kubectl get applications -n argocd --no-headers 2>/dev/null | wc -l)
  if [[ "$APP_COUNT" -eq 0 ]]; then
    echo -e "  ${YELLOW}⚠ No ArgoCD Applications found${NC}"
  else
    kubectl get applications -n argocd \
      -o custom-columns='NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status,REPO:.spec.source.repoURL' \
      2>/dev/null || kubectl get applications -n argocd
  fi
else
  echo -e "  ${YELLOW}⚠ ArgoCD CRDs not installed or no access${NC}"
fi

# ─── summary ─────────────────────────────────────────────────────────────────
echo
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD} Doctor complete  [$(ts)]${NC}"
echo -e "  ${GREEN}✔ passed : $PASS${NC}"
echo -e "  ${YELLOW}⚠ warned : $WARN${NC}"
echo -e "  ${RED}✘ failed : $FAIL${NC}"

if [[ ${#FAILURES[@]} -gt 0 ]]; then
  echo
  echo -e "${RED}${BOLD} Failed checks:${NC}"
  for f in "${FAILURES[@]}"; do
    echo -e "  ${RED}✘ $f${NC}"
  done
fi

echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo

[[ $FAIL -eq 0 ]]   # exit 0 if no failures, exit 1 if any
