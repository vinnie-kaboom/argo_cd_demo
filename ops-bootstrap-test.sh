#!/usr/bin/env bash

set -euo pipefail

NAMESPACE="${1:-agent-ops-dev}"
APP_NAME="${2:-agent-ops-dev}"
MODE="${3:-remediate}"
GH_TOKEN_VALUE="${GH_TOKEN_VALUE:-}"

usage() {
  cat <<'EOF'
Usage:
  GH_TOKEN_VALUE=ghp_xxx ./ops-bootstrap-test.sh [namespace] [argocd_app_name] [mode]

Modes:
  remediate    Send payload to /agent/remediate (default)
  alerts       Send Alertmanager payload to /agent/alerts

Examples:
  GH_TOKEN_VALUE=ghp_xxx ./ops-bootstrap-test.sh
  GH_TOKEN_VALUE=ghp_xxx ./ops-bootstrap-test.sh agent-ops-dev agent-ops-dev alerts
EOF
}

case "$MODE" in
  remediate|alerts) ;;
  -h|--help)
    usage
    exit 0
    ;;
  *)
    echo "Unsupported mode: $MODE" >&2
    usage >&2
    exit 1
    ;;
esac

if [[ -z "$GH_TOKEN_VALUE" ]]; then
  echo "Set GH_TOKEN_VALUE first (GitHub PAT)"
  echo "Example: GH_TOKEN_VALUE=ghp_xxx ./ops-bootstrap-test.sh"
  exit 1
fi

echo "[1/4] Create or update GitHub token secret in ${NAMESPACE}"
kubectl -n "$NAMESPACE" create secret generic agent-ops-github \
  --from-literal=token="$GH_TOKEN_VALUE" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "[2/4] Trigger Argo CD sync for ${APP_NAME}"
kubectl -n argocd annotate applications.argoproj.io "$APP_NAME" \
  argocd.argoproj.io/refresh=hard --overwrite

echo "[3/4] Port-forward agent webhook service"
kubectl -n "$NAMESPACE" port-forward svc/agent-webhook-eventsource-svc 12000:12000 >/tmp/agent-webhook-portforward.log 2>&1 &
PF_PID=$!
trap 'kill "$PF_PID" 2>/dev/null || true' EXIT

sleep 3

if [[ "$MODE" == "remediate" ]]; then
  echo "[4/4] Send test open-fix-pr event to /agent/remediate"
  ./ops-event.sh \
    --url http://127.0.0.1:12000/agent/remediate \
    --action open-fix-pr \
    --environment dev \
    --app-name my-app-dev \
    --app-namespace my-app-dev \
    --replicas 3 \
    --summary "AIOps demo: propose replicaCount increase"
else
  echo "[4/4] Send Alertmanager-style event to /agent/alerts"
  ./ops-event.sh \
    --url http://127.0.0.1:12000/agent/alerts \
    --payload-file apps/ops/agent-ops/examples/alertmanager-sample-payload.json
fi

echo "Done. Check workflow runs in namespace ${NAMESPACE} and GitHub Actions for 'AIOps - Propose GitOps Fix'."