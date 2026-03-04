#!/bin/bash
set -e

CLUSTER_NAME=${1:-"argocd-demo"}

echo "================================================"
echo " Creating kind cluster: $CLUSTER_NAME"
echo " Nodes: 2 control-plane + 2 workers"
echo "================================================"

kind create cluster --name $CLUSTER_NAME --config .devcontainer/4-node-cluster.yaml

echo "✅ Cluster '$CLUSTER_NAME' created"

echo ""
echo "Nodes:"
kubectl get nodes
echo ""

# ── Install ArgoCD ─────────────────────────────────
echo "🚀 Installing ArgoCD..."
kubectl create namespace argocd
helm install argocd argo/argo-cd \
  --namespace argocd \
  --set server.service.type=NodePort \
  --wait

echo ""
echo "================================================"
echo " ✅ ArgoCD is ready!"
echo "================================================"
echo ""
echo " 1. Port-forward the ArgoCD UI:"
echo "    kubectl port-forward svc/argocd-server -n argocd 8080:443"
echo ""
echo " 2. Get admin password:"
echo "    kubectl get secret argocd-initial-admin-secret -n argocd -o jsonpath='{.data.password}' | base64 -d"
echo ""
echo " 3. Open: https://localhost:8080"
echo "    Username: admin"
echo "================================================"
