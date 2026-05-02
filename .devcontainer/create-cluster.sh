#!/bin/bash
set -e

CLUSTER_NAME=${1:-"argocd-demo"}

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

# ── Create placeholder TLS secrets before reconciling the release. Dex is
#    disabled, so its secret is never auto-created; repo/server pods can fail
#    to start cleanly without these placeholders. ───────────────────────────
for secret in argocd-dex-server-tls argocd-repo-server-tls; do
  if kubectl get secret "$secret" -n argocd &>/dev/null; then
    echo "✅ Secret '$secret' already exists, skipping"
  else
    echo "🚀 Creating placeholder secret '$secret'..."
    kubectl create secret generic "$secret" -n argocd \
      --from-literal=tls.crt="" \
      --from-literal=tls.key=""
    echo "✅ Secret '$secret' created"
  fi
done

echo "🚀 Reconciling ArgoCD Helm release..."
helm upgrade --install argocd argo/argo-cd \
  --namespace argocd \
  --set server.service.type=NodePort \
  --set configs.params."server\.insecure"=true \
  --set dex.enabled=false \
  --wait
kubectl rollout status deployment/argocd-server -n argocd --timeout=180s
kubectl rollout status deployment/argocd-repo-server -n argocd --timeout=180s
echo "✅ ArgoCD release is healthy"

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
pkill -f "port-forward.*argocd-server" 2>/dev/null || true
nohup kubectl port-forward svc/argocd-server -n argocd 8080:80 --address 0.0.0.0 > /tmp/argocd-portforward.log 2>&1 &
sleep 3
echo "✅ Port-forward started"

# ── Print access instructions ──────────────────────
echo ""
echo "================================================"
echo " ✅ Environment is ready!"
echo "================================================"
echo ""
echo " ArgoCD port-forward is already running in the background."
echo " If port 8080 is busy, use a different local port, for example:"
echo "   kubectl port-forward svc/argocd-server -n argocd 8081:80 --address 0.0.0.0"
echo ""
echo " On Windows/Mac — open:"
echo "   http://localhost:8080"
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
echo " Verify Argo Rollouts:"
echo "   kubectl get crd rollouts.argoproj.io"
echo "   kubectl get pods -n argo-rollouts"
echo "================================================"
