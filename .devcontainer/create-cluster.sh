#!/bin/bash
set -e

CLUSTER_NAME=${1:-"argocd-demo"}
ARGOCD_CHART_VERSION="7.8.3"

ensure_k8s_connectivity() {
  local retries=6
  local wait_seconds=5

  if ! docker info >/dev/null 2>&1; then
    echo "❌ Docker daemon is not reachable. In Codespaces, restart/rebuild the container and rerun this script."
    exit 1
  fi

  kind export kubeconfig --name "$CLUSTER_NAME" >/dev/null 2>&1 || true

  for ((i=1; i<=retries; i++)); do
    if kubectl cluster-info >/dev/null 2>&1; then
      return 0
    fi
    echo "⏳ Waiting for Kubernetes API (${i}/${retries})..."
    sleep "$wait_seconds"
  done

  return 1
}

echo "================================================"
echo " Setting up cluster: $CLUSTER_NAME"
echo "================================================"

# ── Check if cluster already exists ───────────────
if kind get clusters | grep -q "^$CLUSTER_NAME$"; then
  echo "✅ Cluster '$CLUSTER_NAME' already exists, skipping creation"
else
  echo "🚀 Creating kind cluster (2 control-plane + 2 workers)..."
  kind create cluster --name $CLUSTER_NAME --config .devcontainer/4-node-cluster.yaml
  echo "✅ Cluster '$CLUSTER_NAME' created"
fi

if ! ensure_k8s_connectivity; then
  echo "⚠️ Cluster exists but API server is unreachable. Recreating cluster '$CLUSTER_NAME'..."
  kind delete cluster --name "$CLUSTER_NAME" || true
  kind create cluster --name "$CLUSTER_NAME" --config .devcontainer/4-node-cluster.yaml
  if ! ensure_k8s_connectivity; then
    echo "❌ Kubernetes API is still unreachable after cluster recreation."
    exit 1
  fi
fi

echo ""
echo "Nodes:"
kubectl get nodes
echo ""

# ── Ensure kubectl Argo Rollouts plugin exists ────
if command -v kubectl-argo-rollouts >/dev/null 2>&1; then
  echo "✅ kubectl argo rollouts plugin already installed"
else
  echo "🚀 Installing kubectl argo rollouts plugin..."
  curl -sSL -o /tmp/kubectl-argo-rollouts https://github.com/argoproj/argo-rollouts/releases/latest/download/kubectl-argo-rollouts-linux-amd64
  sudo install -m 555 /tmp/kubectl-argo-rollouts /usr/local/bin/kubectl-argo-rollouts
  rm /tmp/kubectl-argo-rollouts
  echo "✅ kubectl argo rollouts plugin installed"
fi

# ── Reconcile ArgoCD install (repairs partial installs too) ──
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -

# ── Remove previously-created empty TLS secrets. ArgoCD components expect a
#    valid cert/key pair when these secrets exist; placeholder values cause
#    startup failures while the chart can run without them. ─────────────────
for secret in argocd-dex-server-tls argocd-repo-server-tls argocd-server-tls; do
  if ! kubectl get secret "$secret" -n argocd &>/dev/null; then
    continue
  fi

  crt=$(kubectl get secret "$secret" -n argocd -o jsonpath='{.data.tls\.crt}' 2>/dev/null || true)
  key=$(kubectl get secret "$secret" -n argocd -o jsonpath='{.data.tls\.key}' 2>/dev/null || true)

  if [ -z "$crt" ] || [ -z "$key" ]; then
    echo "🧹 Deleting incomplete TLS secret '$secret'..."
    kubectl delete secret "$secret" -n argocd
    echo "✅ Removed incomplete secret '$secret'"
  fi
done

echo "🚀 Reconciling ArgoCD Helm release..."
helm upgrade --install argocd argo/argo-cd \
  --version "$ARGOCD_CHART_VERSION" \
  --namespace argocd \
  --set server.service.type=NodePort \
  --set configs.params."server\.insecure"=true \
  --set dex.enabled=true \
  --wait
kubectl rollout status deployment/argocd-server -n argocd --timeout=180s
kubectl rollout status deployment/argocd-repo-server -n argocd --timeout=180s
kubectl rollout status statefulset/argocd-application-controller -n argocd --timeout=180s || true
echo "✅ ArgoCD release is healthy"

wait_for_app() {
  local app_name="$1"
  local timeout_seconds="${2:-300}"
  local interval=5
  local elapsed=0

  echo "⏳ Waiting for Argo CD app '$app_name' to become Synced/Healthy..."
  while [ "$elapsed" -lt "$timeout_seconds" ]; do
    local sync_status
    local health_status

    sync_status=$(kubectl get application "$app_name" -n argocd -o jsonpath='{.status.sync.status}' 2>/dev/null || true)
    health_status=$(kubectl get application "$app_name" -n argocd -o jsonpath='{.status.health.status}' 2>/dev/null || true)

    if [ "$sync_status" = "Synced" ] && [ "$health_status" = "Healthy" ]; then
      echo "✅ $app_name is Synced/Healthy"
      return 0
    fi

    sleep "$interval"
    elapsed=$((elapsed + interval))
  done

  echo "⚠️ Timed out waiting for '$app_name' (continuing)."
  kubectl get application "$app_name" -n argocd -o wide 2>/dev/null || true
  return 1
}

wait_for_secret() {
  local namespace="$1"
  local secret_name="$2"
  local timeout_seconds="${3:-300}"
  local interval=5
  local elapsed=0

  echo "⏳ Waiting for secret '$secret_name' in namespace '$namespace'..."
  while [ "$elapsed" -lt "$timeout_seconds" ]; do
    if kubectl get secret "$secret_name" -n "$namespace" &>/dev/null; then
      local db_url
      local api_key
      db_url=$(kubectl get secret "$secret_name" -n "$namespace" -o jsonpath='{.data.DATABASE_URL}' 2>/dev/null || true)
      api_key=$(kubectl get secret "$secret_name" -n "$namespace" -o jsonpath='{.data.API_KEY}' 2>/dev/null || true)

      if [ -n "$db_url" ] && [ -n "$api_key" ]; then
        echo "✅ Secret '$secret_name' is present in '$namespace' with expected keys"
        return 0
      fi
    fi

    sleep "$interval"
    elapsed=$((elapsed + interval))
  done

  echo "⚠️ Timed out waiting for secret '$secret_name' in namespace '$namespace' (continuing)."
  kubectl get secret "$secret_name" -n "$namespace" 2>/dev/null || true
  return 1
}

# ── Bootstrap the app-of-apps tree ──────────────────
echo "🚀 Applying root App-of-Apps manifest..."
kubectl apply -f apps/root-app.yaml
wait_for_app root-app 240 || true
wait_for_app vault 360 || true
wait_for_app external-secrets 360 || true
wait_for_app my-app-dev 420 || true
wait_for_app my-app-staging 420 || true
wait_for_app my-app-prod 420
wait_for_secret my-app-dev my-app-secrets 420 || true
wait_for_secret my-app-staging my-app-secrets 420 || true
wait_for_secret my-app my-app-secrets 420
echo "✅ root-app manifest applied"

# ── Check if Argo Rollouts is already installed ───
if kubectl get crd rollouts.argoproj.io &>/dev/null && \
   kubectl get pods -n argo-rollouts &>/dev/null; then
  echo "✅ Argo Rollouts already exists, skipping install"
else
  echo "🚀 Installing Argo Rollouts controller and CRDs..."
  kubectl create namespace argo-rollouts --dry-run=client -o yaml | kubectl apply -f -
  kubectl apply -n argo-rollouts -f https://github.com/argoproj/argo-rollouts/releases/latest/download/install.yaml
  kubectl rollout status deployment/argo-rollouts -n argo-rollouts --timeout=180s
  echo "✅ Argo Rollouts installed"
fi

# ── Start port-forward in background ──────────────
echo ""
echo "🚀 Starting ArgoCD port-forward..."
pkill -f "kubectl port-forward svc/argocd-server -n argocd" 2>/dev/null || true

if ss -ltn | grep -q ':8080 '; then
  echo "⚠️ Port 8080 is in use by a non-ArgoCD process; trying 8081"
  nohup kubectl port-forward svc/argocd-server -n argocd 8081:80 --address 0.0.0.0 > /tmp/argocd-portforward.log 2>&1 &
  sleep 3
  if ss -ltn | grep -q ':8081 '; then
    echo "✅ Port-forward started on 8081"
  else
    echo "⚠️ Port-forward did not bind to 8081; check /tmp/argocd-portforward.log"
  fi
else
  nohup kubectl port-forward svc/argocd-server -n argocd 8080:80 --address 0.0.0.0 > /tmp/argocd-portforward.log 2>&1 &
  sleep 3
  if ss -ltn | grep -q ':8080 '; then
    echo "✅ Port-forward started on 8080"
  else
    echo "⚠️ Port-forward did not bind to 8080; check /tmp/argocd-portforward.log"
  fi
fi

# ── Print access instructions ──────────────────────
echo ""
echo "================================================"
echo " ✅ Environment is ready!"
echo "================================================"
echo ""
echo " ArgoCD uses port 8080 when available."
echo " If port 8080 is busy, this script auto-falls back to 8081."
echo " Manual fallback: kubectl port-forward svc/argocd-server -n argocd 8081:80 --address 0.0.0.0"
echo ""
echo " On Windows/Mac — open:"
echo "   http://localhost:8080 (or http://localhost:8081 if fallback was used)"
echo ""
echo " On iPad — open the Ports tab in VS Code"
echo " and click the 🌐 globe icon next to port 8080"
echo " URL will look like:"
echo "   http://YOUR-CODESPACE-NAME-8080.app.github.dev"
echo ""
echo " Get admin password:"
echo "   kubectl get secret argocd-initial-admin-secret \\"
echo "   -n argocd -o jsonpath='{.data.password}' | base64 -d"
echo ""
echo " Username: admin"
echo ""
echo " If the UI accepts your password but does not finish logging in,"
echo " open the forwarded URL in a private/incognito window or clear site data"
echo " for the ArgoCD port URL. Rebuilds can rotate server.secretkey and"
echo " invalidate stored browser sessions."
echo ""
echo " Verify Argo Rollouts:"
echo "   kubectl get crd rollouts.argoproj.io"
echo "   kubectl get pods -n argo-rollouts"
echo ""
echo " Verify Argo CD + Vault + External Secrets:"
echo "   kubectl get applications -n argocd"
echo "   kubectl get pods -n vault"
echo "   kubectl get pods -n external-secrets"
echo "   kubectl get externalsecret -A"
echo "   kubectl get secret my-app-secrets -n my-app-dev"
echo "   kubectl get secret my-app-secrets -n my-app-staging"
echo "   kubectl get secret my-app-secrets -n my-app"
echo "================================================"
