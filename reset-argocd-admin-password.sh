#!/usr/bin/env bash

set -euo pipefail

NAMESPACE="${NAMESPACE:-argocd}"
SECRET_NAME="${SECRET_NAME:-argocd-secret}"
DEPLOYMENT_NAME="${DEPLOYMENT_NAME:-argocd-server}"
ARGOCD_IMAGE="${ARGOCD_IMAGE:-quay.io/argoproj/argocd:v2.14.2}"
RESTART_SERVER=true

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Resets Argo CD admin password by patching admin.password and admin.passwordMtime
on the Argo CD secret.

Options:
  -n, --namespace <ns>       Namespace (default: ${NAMESPACE})
  -s, --secret <name>        Secret name (default: ${SECRET_NAME})
  -d, --deployment <name>    Deployment to restart (default: ${DEPLOYMENT_NAME})
      --image <image>        Argo CD image used for bcrypt generation
                              (default: ${ARGOCD_IMAGE})
      --no-restart           Do not restart the Argo CD server deployment
  -h, --help                 Show this help

Environment overrides:
  NAMESPACE, SECRET_NAME, DEPLOYMENT_NAME, ARGOCD_IMAGE
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--namespace)
      NAMESPACE="$2"
      shift 2
      ;;
    -s|--secret)
      SECRET_NAME="$2"
      shift 2
      ;;
    -d|--deployment)
      DEPLOYMENT_NAME="$2"
      shift 2
      ;;
    --image)
      ARGOCD_IMAGE="$2"
      shift 2
      ;;
    --no-restart)
      RESTART_SERVER=false
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if ! command -v kubectl >/dev/null 2>&1; then
  echo "Error: kubectl is required but not found in PATH." >&2
  exit 1
fi

if ! kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
  echo "Error: namespace '$NAMESPACE' not found or inaccessible." >&2
  exit 1
fi

if ! kubectl -n "$NAMESPACE" get secret "$SECRET_NAME" >/dev/null 2>&1; then
  echo "Error: secret '$SECRET_NAME' not found in namespace '$NAMESPACE'." >&2
  exit 1
fi

read -rsp "New Argo CD admin password: " NEW_PASS
printf '\n'
read -rsp "Confirm new password: " NEW_PASS_CONFIRM
printf '\n'

if [[ "$NEW_PASS" != "$NEW_PASS_CONFIRM" ]]; then
  echo "Error: passwords do not match." >&2
  unset NEW_PASS NEW_PASS_CONFIRM
  exit 1
fi

if [[ -z "$NEW_PASS" ]]; then
  echo "Error: password cannot be empty." >&2
  unset NEW_PASS NEW_PASS_CONFIRM
  exit 1
fi

echo "Generating bcrypt hash using temporary pod..."
HASH="$({
  kubectl -n "$NAMESPACE" run argocd-passgen \
    --rm -i --restart=Never \
    --image "$ARGOCD_IMAGE" \
    --command -- argocd account bcrypt --password "$NEW_PASS"
} | tail -n 1)"

if [[ -z "$HASH" || "$HASH" != '$2'* ]]; then
  echo "Error: failed to generate bcrypt hash." >&2
  unset NEW_PASS NEW_PASS_CONFIRM HASH
  exit 1
fi

echo "Patching secret '$SECRET_NAME' in namespace '$NAMESPACE'..."
kubectl -n "$NAMESPACE" patch secret "$SECRET_NAME" --type merge -p \
  "{\"stringData\":{\"admin.password\":\"$HASH\",\"admin.passwordMtime\":\"$(date -u +%FT%TZ)\"}}"

if [[ "$RESTART_SERVER" == true ]]; then
  echo "Restarting deployment '$DEPLOYMENT_NAME'..."
  kubectl -n "$NAMESPACE" rollout restart "deploy/$DEPLOYMENT_NAME"
  kubectl -n "$NAMESPACE" rollout status "deploy/$DEPLOYMENT_NAME" --timeout=180s
fi

echo "Verifying stored hash..."
STORED_HASH="$(kubectl -n "$NAMESPACE" get secret "$SECRET_NAME" -o jsonpath='{.data.admin\.password}' | base64 -d)"
if [[ "$STORED_HASH" == '$2'* ]]; then
  echo "Success: admin password hash updated."
else
  echo "Warning: secret updated, but verification did not return a bcrypt hash." >&2
fi

unset NEW_PASS NEW_PASS_CONFIRM HASH STORED_HASH
