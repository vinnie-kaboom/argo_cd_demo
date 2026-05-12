#!/usr/bin/env bash

set -euo pipefail

URL="${AGENT_OPS_URL:-http://localhost:12000/agent/remediate}"
ACTION="record-only"
SUMMARY="manual event"
APP_NAME="my-app-dev"
APP_NAMESPACE="my-app-dev"
ROLLOUT_NAME=""
ENVIRONMENT="dev"
PROPOSED_REPLICA_COUNT=""
PAYLOAD_FILE=""

usage() {
  cat <<'EOF'
Usage:
  ./ops-event.sh [options]

Options:
  --url URL                     Agent webhook URL
  --action ACTION               record-only | refresh-app | pause-rollout | resume-rollout | open-fix-pr
  --summary TEXT                Human-readable event summary
  --app-name NAME               Argo CD Application name
  --app-namespace NAMESPACE     Target application namespace
  --rollout-name NAME           Rollout name for pause/resume actions
  --environment NAME            dev | staging | prod
  --replicas COUNT              Proposed replica count for open-fix-pr
  --payload-file FILE           Send the given JSON payload as-is
  -h, --help                    Show this help

Examples:
  ./ops-event.sh --action refresh-app --summary "manual refresh"
  ./ops-event.sh --action open-fix-pr --environment dev --replicas 3 --summary "scale up after retries"
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --url)
      URL="$2"
      shift 2
      ;;
    --action)
      ACTION="$2"
      shift 2
      ;;
    --summary)
      SUMMARY="$2"
      shift 2
      ;;
    --app-name)
      APP_NAME="$2"
      shift 2
      ;;
    --app-namespace)
      APP_NAMESPACE="$2"
      shift 2
      ;;
    --rollout-name)
      ROLLOUT_NAME="$2"
      shift 2
      ;;
    --environment)
      ENVIRONMENT="$2"
      shift 2
      ;;
    --replicas)
      PROPOSED_REPLICA_COUNT="$2"
      shift 2
      ;;
    --payload-file)
      PAYLOAD_FILE="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ -n "$PAYLOAD_FILE" ]]; then
  curl --fail --show-error --silent \
    -X POST \
    -H "Content-Type: application/json" \
    --data @"$PAYLOAD_FILE" \
    "$URL"
  echo
  exit 0
fi

PAYLOAD="$(python3 - <<'PY'
import json
import os

payload = {
    "action": os.environ["ACTION"],
    "summary": os.environ["SUMMARY"],
    "appName": os.environ["APP_NAME"],
    "appNamespace": os.environ["APP_NAMESPACE"],
    "rolloutName": os.environ["ROLLOUT_NAME"],
    "environment": os.environ["ENVIRONMENT"],
}

replicas = os.environ["PROPOSED_REPLICA_COUNT"]
if replicas:
    payload["proposedReplicaCount"] = replicas

print(json.dumps(payload))
PY
)"

curl --fail --show-error --silent \
  -X POST \
  -H "Content-Type: application/json" \
  --data "$PAYLOAD" \
  "$URL"
echo