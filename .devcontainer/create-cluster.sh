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

# ── Check if ArgoCD already installed ─────────────
if kubectl get namespace argocd &>/dev/null; then
  echo "✅ ArgoCD namespace already exists, skipping install"
else
  echo "🚀 Installing ArgoCD..."
  kubectl create namespace argocd
  helm install argocd argo/argo-cd \
    --namespace argocd \
    --set server.service.type=NodePort \
    --wait
  echo "✅ ArgoCD installed"
fi

# ── Start port-forward in background ──────────────
echo ""
echo "🚀 Starting ArgoCD port-forward..."
pkill -f "port-forward.*argocd-server" 2>/dev/null || true
kubectl port-forward svc/argocd-server -n argocd 8080:443 &
sleep 3
echo "✅ Port-forward started"

# ── Print access instructions ──────────────────────
echo ""
echo "================================================"
echo " ✅ Environment is ready!"
echo "================================================"
echo ""
echo " On Windows/Mac — open:"
echo "   https://localhost:8080"
echo ""
echo " On iPad — open the Ports tab in VS Code"
echo " and click the 🌐 globe icon next to port 8080"
echo " URL will look like:"
echo "   https://YOUR-CODESPACE-NAME-8080.app.github.dev"
echo ""
echo " Get admin password:"
echo "   kubectl get secret argocd-initial-admin-secret \\"
echo "   -n argocd -o jsonpath='{.data.password}' | base64 -d"
echo ""
echo " Username: admin"
echo "================================================"
