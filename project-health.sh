#!/usr/bin/env bash

set -u

PASS_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0
REQUEST_TIMEOUT="10s"

DEFAULT_NAMESPACES=(
  "argocd"
  "my-app-dev"
  "my-app-staging"
  "my-app-prod"
)

TARGET_NAMESPACES=()
SHOW_APP_TABLE=false

usage() {
  cat <<'EOF'
Usage:
  ./project-health.sh [options]

Options:
  -n, --namespace <name>   Add namespace health check (repeatable)
  -A, --all-namespaces     Check all namespaces with workloads
  -t, --timeout <value>    kubectl request timeout (default: 10s)
  -a, --apps               Print full Argo CD applications table
  -h, --help               Show this help

Examples:
  ./project-health.sh
  ./project-health.sh -n my-app-dev -n my-app-staging
  ./project-health.sh -A -a
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

check_cluster_reachable() {
  local ctx
  ctx="$(kubectl config current-context 2>/dev/null || true)"
  if [[ -z "$ctx" ]]; then
    fail "No active kubectl context"
    return
  fi
  pass "Current context: $ctx"

  if kubectl version --request-timeout="$REQUEST_TIMEOUT" >/dev/null 2>&1; then
    pass "Kubernetes API reachable"
  else
    fail "Cannot reach Kubernetes API"
  fi
}

collect_target_namespaces() {
  local all_ns

  if [[ "${#TARGET_NAMESPACES[@]}" -gt 0 ]]; then
    return
  fi

  if [[ "$CHECK_ALL_NAMESPACES" == "true" ]]; then
    mapfile -t all_ns < <(kubectl get ns --no-headers 2>/dev/null | awk '{print $1}')
    TARGET_NAMESPACES=("${all_ns[@]}")
  else
    TARGET_NAMESPACES=("${DEFAULT_NAMESPACES[@]}")
  fi
}

check_namespace_exists() {
  local ns="$1"
  if kubectl get ns "$ns" >/dev/null 2>&1; then
    pass "Namespace exists: $ns"
  else
    warn "Namespace missing: $ns"
  fi
}

check_namespace_workloads() {
  local ns="$1"
  local bad_pods deploy_unready sts_unready ds_unready

  if ! kubectl get ns "$ns" >/dev/null 2>&1; then
    return
  fi

  bad_pods="$(kubectl -n "$ns" get pods --no-headers 2>/dev/null | awk '$3 !~ /Running|Completed/ {print $1"("$3")"}')"
  deploy_unready="$(kubectl -n "$ns" get deploy --no-headers -o custom-columns='NAME:.metadata.name,READY:.status.readyReplicas,DESIRED:.spec.replicas' 2>/dev/null | awk '{r=($2=="<none>"||$2==""?0:$2); d=($3=="<none>"||$3==""?0:$3); if (r != d) print $1"("r"/"d")"}')"
  sts_unready="$(kubectl -n "$ns" get statefulset --no-headers -o custom-columns='NAME:.metadata.name,READY:.status.readyReplicas,DESIRED:.spec.replicas' 2>/dev/null | awk '{r=($2=="<none>"||$2==""?0:$2); d=($3=="<none>"||$3==""?0:$3); if (r != d) print $1"("r"/"d")"}')"
  ds_unready="$(kubectl -n "$ns" get daemonset --no-headers -o custom-columns='NAME:.metadata.name,READY:.status.numberReady,DESIRED:.status.desiredNumberScheduled' 2>/dev/null | awk '{r=($2=="<none>"||$2==""?0:$2); d=($3=="<none>"||$3==""?0:$3); if (r != d) print $1"("r"/"d")"}')"

  if [[ -z "$bad_pods" && -z "$deploy_unready" && -z "$sts_unready" && -z "$ds_unready" ]]; then
    pass "Workloads healthy in namespace: $ns"
  else
    fail "Workload issues in namespace: $ns"
    [[ -n "$bad_pods" ]] && printf '       pods:   %s\n' "$(echo "$bad_pods" | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
    [[ -n "$deploy_unready" ]] && printf '       deploy: %s\n' "$(echo "$deploy_unready" | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
    [[ -n "$sts_unready" ]] && printf '       sts:    %s\n' "$(echo "$sts_unready" | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
    [[ -n "$ds_unready" ]] && printf '       ds:     %s\n' "$(echo "$ds_unready" | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
  fi
}

check_argocd_apps() {
  local app_lines
  local bad_lines

  if ! kubectl get ns argocd >/dev/null 2>&1; then
    warn "argocd namespace not present, skipping Argo CD application checks"
    return
  fi

  if ! kubectl get applications -n argocd >/dev/null 2>&1; then
    warn "Argo CD Application CRD not found or not accessible"
    return
  fi

  mapfile -t app_lines < <(kubectl get applications -n argocd --no-headers -o custom-columns='NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status,REVISION:.status.sync.revision' 2>/dev/null)

  if [[ "${#app_lines[@]}" -eq 0 ]]; then
    warn "No Argo CD applications found"
    return
  fi

  bad_lines="$(printf '%s\n' "${app_lines[@]}" | awk '$2 != "Synced" || $3 != "Healthy" {print $1"(sync="$2",health="$3")"}')"

  if [[ -z "$bad_lines" ]]; then
    pass "All Argo CD applications are Synced and Healthy (${#app_lines[@]} total)"
  else
    fail "Argo CD applications with issues: $(echo "$bad_lines" | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
  fi

  if [[ "$SHOW_APP_TABLE" == "true" ]]; then
    echo
    echo "Argo CD applications:"
    kubectl get applications -n argocd -o custom-columns='NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status,REVISION:.status.sync.revision' 2>/dev/null || true
  fi
}

check_events_warnings() {
  local warning_count
  warning_count="$(kubectl get events -A --field-selector type=Warning --no-headers 2>/dev/null | wc -l | tr -d ' ')"

  if [[ "$warning_count" == "0" ]]; then
    pass "No Warning events in cluster"
  else
    warn "Cluster has $warning_count Warning events"
  fi
}

CHECK_ALL_NAMESPACES=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--namespace)
      [[ -z "${2:-}" ]] && { echo "Missing value for $1"; usage; exit 2; }
      TARGET_NAMESPACES+=("$2")
      shift 2
      ;;
    -A|--all-namespaces)
      CHECK_ALL_NAMESPACES=true
      shift
      ;;
    -t|--timeout)
      [[ -z "${2:-}" ]] && { echo "Missing value for $1"; usage; exit 2; }
      REQUEST_TIMEOUT="$2"
      shift 2
      ;;
    -a|--apps)
      SHOW_APP_TABLE=true
      shift
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

echo "== Project health check =="
echo "Timestamp: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
echo

require_cmd kubectl

if [[ "$FAIL_COUNT" -eq 0 ]]; then
  check_cluster_reachable
fi

if [[ "$FAIL_COUNT" -eq 0 ]]; then
  collect_target_namespaces

  # De-duplicate names while preserving insertion order.
  seen=" "
  for ns in "${TARGET_NAMESPACES[@]}"; do
    if [[ -n "$ns" && "$seen" != *" $ns "* ]]; then
      check_namespace_exists "$ns"
      check_namespace_workloads "$ns"
      seen+="$ns "
    fi
  done

  check_argocd_apps
  check_events_warnings
fi

echo
echo "Summary: pass=$PASS_COUNT warn=$WARN_COUNT fail=$FAIL_COUNT"

if [[ "$FAIL_COUNT" -gt 0 ]]; then
  exit 1
fi

exit 0