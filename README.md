## Argo-cd
# ArgoCD Demo on GitHub Codespaces
## Complete Setup Guide

## Docs quick links

- Root app (App of Apps): [apps/README.md](apps/README.md)
- Agent Ops remediation pipeline: [apps/ops/agent-ops/README.md](apps/ops/agent-ops/README.md)

## CI Tag Promotion Flow (Simple)

This is the simple end-to-end flow for `.github/workflows/ci.yaml`:

1. A separate app pipeline builds an image and pushes it to DockerHub.
2. After push, that pipeline sends `repository_dispatch` to this repo with:
  - `image_tag` (example: `v1.2.3`)
  - `target_env` (`dev`, `staging`, or `prod`)
3. This workflow can also be run manually with the same inputs.
4. The workflow updates one file in this repo:
  - `apps/app/my-app/deploy/overlays/<env>/values.yaml`
5. It commits and pushes the change.

What DockerHub does here:

- DockerHub stores the image.
- This workflow does not call DockerHub APIs directly.
- It trusts the tag provided by the event/manual input.

How Argo CD deploys the new version:

1. Argo CD watches this GitOps repo.
2. It sees the new commit with the updated image tag.
3. It syncs the target Application and applies the new manifests.
4. Kubernetes pulls the new image tag from DockerHub and rolls out the update.

In short: build pipeline pushes image -> CI updates Git tag -> Argo CD syncs -> cluster runs new version.

A 4-node Kubernetes cluster (2 control-plane + 2 workers) with ArgoCD and Claude Code CLI
— fully in the cloud, no local Docker or admin rights needed. Works on Windows, Mac and iPad.

---

## Prerequisites

- A **GitHub account** (free) → https://github.com
- An **Anthropic account** (for Claude Code) → https://console.anthropic.com

---

## Step 1 — Create a GitHub Repo

1. Go to https://github.com/new
2. Name it `argocd-demo`, set to **Private**
3. Click **Create repository**

---

## Step 2 — Create the .devcontainer folder and files

In your new repo, click **Add file → Create new file** for each file below.
Type the filename exactly as shown, paste the contents, click **Commit changes**.

### `.devcontainer/devcontainer.json`
```json
{
  "name": "Kubernetes + kind + ArgoCD + Claude Code",
  "image": "mcr.microsoft.com/devcontainers/base:ubuntu",

  "features": {
    "ghcr.io/devcontainers/features/docker-in-docker:2": {
      "version": "latest"
    },
    "ghcr.io/devcontainers/features/kubectl-helm-minikube:1": {
      "version": "latest",
      "helm": "latest",
      "minikube": "none"
    },
    "ghcr.io/devcontainers/features/github-cli:1": {}
  },

  "onCreateCommand": "bash .devcontainer/install.sh",

  "postStartCommand": "bash .devcontainer/create-cluster.sh",

  "customizations": {
    "vscode": {
      "extensions": [
        "ms-kubernetes-tools.vscode-kubernetes-tools",
        "redhat.vscode-yaml",
        "ms-azuretools.vscode-docker"
      ],
      "settings": {
        "terminal.integrated.defaultProfile.linux": "bash",
        "vs-kubernetes.kubectl-path": "/usr/local/bin/kubectl"
      }
    }
  },

  "remoteUser": "vscode",

  "mounts": [
    "source=/var/run/docker.sock,target=/var/run/docker.sock,type=bind"
  ],

  "forwardPorts": [8080],
  "portsAttributes": {
    "8080": {
      "label": "ArgoCD UI",
      "onAutoForward": "openBrowser",
      "visibility": "public"
    }
  }
}

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


#!/bin/bash
set -e

CLUSTER_NAME=${1:-"argocd-demo"}

echo "================================================"
echo " Setting up cluster: $CLUSTER_NAME"
echo "================================================"

# ── Check if cluster already exists ───────────────
if kind get clusters | grep -q "^$CLUSTER\_NAME$"; then
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
echo "================================================"

kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
  - role: control-plane
  - role: worker
  - role: worker



# Check cluster nodes
kubectl get nodes

# Check ArgoCD pods
kubectl get pods -n argocd

# Restart port-forward manually if needed
kubectl port-forward svc/argocd-server -n argocd 8080:443 &

# Delete the cluster
kind delete cluster --name argocd-demo

# Recreate everything from scratch
bash .devcontainer/create-cluster.sh
