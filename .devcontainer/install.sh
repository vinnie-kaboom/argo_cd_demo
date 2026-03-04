#!/bin/bash
set -e

echo "================================================"
echo " Installing tools..."
echo "================================================"

# ── kind ──────────────────────────────────────────
echo ""
echo "🚀 Installing kind..."
KIND_VERSION="v0.22.0"
curl -Lo /tmp/kind https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-linux-amd64
chmod +x /tmp/kind
sudo mv /tmp/kind /usr/local/bin/kind
echo "✅ kind $(kind version) installed"

# ── ArgoCD CLI ─────────────────────────────────────
echo ""
echo "🚀 Installing ArgoCD CLI..."
curl -sSL -o /tmp/argocd https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-amd64
sudo install -m 555 /tmp/argocd /usr/local/bin/argocd
rm /tmp/argocd
echo "✅ ArgoCD CLI installed"

# ── ArgoCD Helm Repo ───────────────────────────────
echo ""
echo "🚀 Adding ArgoCD Helm repo..."
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update
echo "✅ Helm repo ready"

# ── Claude Code CLI ────────────────────────────────
echo ""
echo "🚀 Installing Claude Code CLI..."
curl -fsSL https://claude.ai/install.sh | bash
echo 'export PATH="$HOME/.claude/bin:$HOME/.local/bin:$PATH"' >> ~/.bashrc
echo "✅ Claude Code installed"

echo ""
echo "================================================"
echo " ✅ All tools installed!"
echo "================================================"
echo ""
echo " Available commands:"
echo "   kind      - create/manage local k8s clusters"
echo "   kubectl   - interact with clusters"
echo "   helm      - install helm charts"
echo "   argocd    - ArgoCD CLI"
echo "   claude    - Claude Code CLI"
echo ""
echo " To create your cluster run:"
echo "   bash .devcontainer/create-cluster.sh"
echo "================================================"
