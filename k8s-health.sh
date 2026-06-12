#!/usr/bin/env bash

set -u

TARGET_NAMESPACES=("argocd")
SHOW_WARNING_EVENTS=false
REQUEST_TIMEOUT="8s"

PASS_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0

usage() {
  cat <<'EOF'
Usage:
  ./k8s-health.sh [options]

Options:
  -n, --namespace <name>   Add namespace readiness check (repeatable)
  -A, --all-namespaces     Disable namespace-specific checks
  -w, --warnings           Show latest warning events (non-blocking)
  -t, --timeout <value>    kubectl request timeout (default: 8s)
  -h, --help               Show this help

Examples:
  ./k8s-health.sh
  ./k8s-health.sh -n my-app-dev -n my-app-staging
  ./k8s-health.sh -A -w
EOF
}

pass() {
  PASS_COUNT=$((PASS_COUNT + 1))
  printf '[PASS] %s\n' "$*"
}

warn() {
  WARN_COUNT=$((WARN_COUNT + 1))
  printf '[WARN] %s\n' "$*"
}

fail() {
  FAIL_COUNT=$((FAIL_COUNT + 1))
  printf '[FAIL] %s\n' "$*"
}

require_cmd() {
  if command -v "$1" >/dev/null 2>&1; then
    pass "Command found: $1"
  else
    fail "Missing required command: $1"
  fi
}

check_kubectl_context() {
  local ctx
  ctx="$(kubectl config current-context 2>/dev/null || true)"
  if [[ -n "$ctx" ]]; then
    pass "Current context: $ctx"
  else
    fail "No active kubectl context"
  fi
}

check_apiserver_health() {
  if kubectl version --request-timeout="$REQUEST_TIMEOUT" >/dev/null 2>&1; then
    pass "kubectl can reach Kubernetes API"
  else
    fail "Cannot reach Kubernetes API"
    return
  fi

  if kubectl get --raw='/readyz' --request-timeout="$REQUEST_TIMEOUT" >/dev/null 2>&1; then
    pass "API server /readyz is healthy"
  else
    warn "Could not verify API server /readyz endpoint"
  fi
}

check_nodes_ready() {
  local node_count not_ready
  node_count="$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  if [[ "$node_count" == "0" ]]; then
    fail "No nodes detected"
    return
  fi

  not_ready="$(kubectl get nodes --no-headers 2>/dev/null | awk '$2 !~ /Ready/ {print $1}')"
  if [[ -z "$not_ready" ]]; then
    pass "All nodes are Ready ($node_count total)"
  else
    fail "NotReady nodes detected: $(echo "$not_ready" | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
  fi
}

check_kube_system_pods() {
  local bad
  bad="$(kubectl get pods -n kube-system --no-headers 2>/dev/null | awk '$3 !~ /Running|Completed/ {print $1"("$3")"}')"
  if [[ -z "$bad" ]]; then
    pass "kube-system pods are healthy"
  else
    fail "Unhealthy pods in kube-system: $(echo "$bad" | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
  fi
}

check_core_dns() {
  local available
  available="$(kubectl get deploy -n kube-system coredns -o jsonpath='{.status.availableReplicas}' 2>/dev/null || true)"
  if [[ -n "$available" && "$available" != "0" ]]; then
    pass "CoreDNS available replicas: $available"
  else
    warn "CoreDNS deployment not detected or has zero available replicas"
  fi
}

check_cluster_workloads() {
  local bad
  bad="$(kubectl get pods -A --no-headers 2>/dev/null | awk '$4 !~ /Running|Completed/ {print $1"/"$2"("$4")"}')"
  if [[ -z "$bad" ]]; then
    pass "No globally unhealthy pods"
  else
    warn "Pods not Running/Completed found: $(echo "$bad" | head -n 8 | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
  fi
}

check_namespace_readiness() {
  local ns="$1"

  if ! kubectl get ns "$ns" >/dev/null 2>&1; then
    fail "Namespace missing: $ns"
    return
  fi

  local d_unready s_unready ds_unready

  d_unready="$(kubectl -n "$ns" get deploy --no-headers -o custom-columns='NAME:.metadata.name,READY:.status.readyReplicas,DESIRED:.spec.replicas' 2>/dev/null | awk '{r=($2=="<none>"||$2==""?0:$2); d=($3=="<none>"||$3==""?0:$3); if (r != d) print $1"("r"/"d")"}')"
  s_unready="$(kubectl -n "$ns" get statefulset --no-headers -o custom-columns='NAME:.metadata.name,READY:.status.readyReplicas,DESIRED:.spec.replicas' 2>/dev/null | awk '{r=($2=="<none>"||$2==""?0:$2); d=($3=="<none>"||$3==""?0:$3); if (r != d) print $1"("r"/"d")"}')"
  ds_unready="$(kubectl -n "$ns" get daemonset --no-headers -o custom-columns='NAME:.metadata.name,READY:.status.numberReady,DESIRED:.status.desiredNumberScheduled' 2>/dev/null | awk '{r=($2=="<none>"||$2==""?0:$2); d=($3=="<none>"||$3==""?0:$3); if (r != d) print $1"("r"/"d")"}')"

  if [[ -z "$d_unready" && -z "$s_unready" && -z "$ds_unready" ]]; then
    pass "Namespace ready: $ns"
  else
    fail "Namespace not fully ready: $ns"
    [[ -n "$d_unready" ]] && printf '       deploy: %s\n' "$(echo "$d_unready" | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
    [[ -n "$s_unready" ]] && printf '       sts:    %s\n' "$(echo "$s_unready" | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
    [[ -n "$ds_unready" ]] && printf '       ds:     %s\n' "$(echo "$ds_unready" | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
  fi
}

show_warning_events() {
  local lines
  lines="$(kubectl get events -A --field-selector type=Warning --sort-by=.lastTimestamp 2>/dev/null | tail -n 15 || true)"
  if [[ -n "$lines" ]]; then
    warn "Recent warning events (latest 15):"
    printf '%s\n' "$lines"
  else
    pass "No warning events found"
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--namespace)
      [[ -z "${2:-}" ]] && { echo "Missing value for $1"; usage; exit 2; }
      TARGET_NAMESPACES+=("$2")
      shift 2
      ;;
    -A|--all-namespaces)
      TARGET_NAMESPACES=()
      shift
      ;;
    -w|--warnings)
      SHOW_WARNING_EVENTS=true
      shift
      ;;
    -t|--timeout)
      [[ -z "${2:-}" ]] && { echo "Missing value for $1"; usage; exit 2; }
      REQUEST_TIMEOUT="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1"
      usage
      exit 2
      ;;
  esac
done

echo "== Kubernetes health check =="
echo "Timestamp: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
echo

require_cmd kubectl
check_kubectl_context
check_apiserver_health

if [[ "$FAIL_COUNT" -eq 0 ]]; then
  check_nodes_ready
  check_kube_system_pods
  check_core_dns
  check_cluster_workloads

  if [[ "${#TARGET_NAMESPACES[@]}" -gt 0 ]]; then
    seen=" "
    for ns in "${TARGET_NAMESPACES[@]}"; do
      if [[ "$seen" != *" $ns "* ]]; then
        check_namespace_readiness "$ns"
        seen+="$ns "
      fi
    done
  else
    pass "Namespace-specific checks skipped"
  fi

  if [[ "$SHOW_WARNING_EVENTS" == "true" ]]; then
    show_warning_events
  fi
fi

echo
echo "Summary: pass=$PASS_COUNT warn=$WARN_COUNT fail=$FAIL_COUNT"

if [[ "$FAIL_COUNT" -gt 0 ]]; then
  exit 1
fi

exit 0
