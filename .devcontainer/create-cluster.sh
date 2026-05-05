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
  --namespace argocd \
  --set server.service.type=NodePort \
  --set configs.params."server\.insecure"=true \
  --set dex.enabled=true \
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
if pgrep -f "kubectl port-forward svc/argocd-server -n argocd 8080:80 --address 0.0.0.0" >/dev/null 2>&1; then
  echo "✅ ArgoCD port-forward is already running on port 8080"
elif ss -ltn | grep -q ':8080 '; then
  echo "⚠️ Port 8080 is already in use by another process; skipping auto port-forward"
  echo "   Use a different local port if needed, for example:"
  echo "   kubectl port-forward svc/argocd-server -n argocd 8081:80 --address 0.0.0.0"
else
  nohup kubectl port-forward svc/argocd-server -n argocd 8080:80 --address 0.0.0.0 > /tmp/argocd-portforward.log 2>&1 &
  sleep 3
  if ss -ltn | grep -q ':8080 '; then
    echo "✅ Port-forward started"
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
echo " If the UI accepts your password but does not finish logging in,"
echo " open the forwarded URL in a private/incognito window or clear site data"
echo " for the ArgoCD port URL. Rebuilds can rotate server.secretkey and"
echo " invalidate stored browser sessions."
echo ""
echo " Verify Argo Rollouts:"
echo "   kubectl get crd rollouts.argoproj.io"
echo "   kubectl get pods -n argo-rollouts"
echo "================================================"
