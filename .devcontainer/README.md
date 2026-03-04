# argo_c# ArgoCD Demo on GitHub Codespaces
## Setup Guide

Everything you need to run a 4-node Kubernetes cluster with ArgoCD and Claude Code CLI — fully in the cloud, no local Docker or admin rights needed.

---

## Prerequisites

- A **GitHub account** (free) → https://github.com
- An **Anthropic account** (for Claude Code) → https://console.anthropic.com

---

## Step 1 — Create a GitHub Repo

1. Go to https://github.com/new
2. Name it something like `argocd-demo`
3. Set it to **Private** (recommended)
4. Click **Create repository**

---

## Step 2 — Upload the .devcontainer folder

1. On your new repo page, click **Add file → Upload files**
2. Upload the entire `.devcontainer` folder (drag and drop it)
3. Click **Commit changes**

Your repo should look like this:
```
argocd-demo/
└── .devcontainer/
    ├── devcontainer.json
    ├── install.sh
    └── setup-argocd.sh
```

---

## Step 3 — Add your Anthropic API Key as a Secret (for Claude Code)

1. Go to https://console.anthropic.com and copy your API key
2. In GitHub, go to **Settings → Codespaces → Secrets**
3. Click **New secret**
   - Name: `ANTHROPIC_API_KEY`
   - Value: paste your API key
4. Select your `argocd-demo` repo and click **Add secret**

---

## Step 4 — Launch Codespaces

1. Go back to your `argocd-demo` repo
2. Click the green **`<> Code`** button
3. Click the **Codespaces** tab
4. Click **Create codespace on main**
5. Wait ~2-3 minutes for the environment to build

✅ This will automatically:
- Install Docker, kubectl, Helm
- Install kind and ArgoCD CLI
- Install Claude Code CLI
- Create a 4-node Kubernetes cluster
- Deploy ArgoCD via Helm

---

## Step 5 — Access the ArgoCD UI

Once the Codespace is ready, in the terminal run:

```bash
kubectl port-forward svc/argocd-server -n argocd 8080:443
```

The browser will automatically open the ArgoCD UI at https://localhost:8080

**Get your admin password:**
```bash
kubectl get secret argocd-initial-admin-secret \
  -n argocd \
  -o jsonpath='{.data.password}' | base64 -d
```

Login with:
- **Username:** `admin`
- **Password:** output from command above

---

## Step 6 — Use Claude Code CLI

In the Codespace terminal, simply run:

```bash
claude
```

It will authenticate using your `ANTHROPIC_API_KEY` secret automatically.

---

## Useful Commands

```bash
# Check all cluster nodes
kubectl get nodes

# Check ArgoCD pods
kubectl get pods -n argocd

# Check all namespaces
kubectl get ns

# Delete and recreate the kind cluster
kind delete cluster --name argocd-demo
bash .devcontainer/setup-argocd.sh
```

---

## Cost & Billing

| Resource | Cost |
|---|---|
| GitHub Codespaces | Free (120 core-hours/month on free plan) |
| Anthropic API (Claude Code) | Pay per use — approx $0.01–0.05 for light usage |

> 💡 **Tip:** Always **stop your Codespace** when not in use to preserve your free hours.
> Go to https://github.com/codespaces → find your codespace → click **Stop**

---

## Troubleshooting

**ArgoCD pods not ready?**
```bash
kubectl get pods -n argocd -w
# Wait for all pods to show "Running"
```

**kind cluster not found?**
```bash
kind get clusters
# If empty, re-run:
bash .devcontainer/setup-argocd.sh
```

**Claude Code not authenticated?**
```bash
echo $ANTHROPIC_API_KEY
# If empty, check your Codespaces secret was added correctly
```

---

*Files included in this zip:*
- `README.md` — this guide
- `.devcontainer/devcontainer.json` — Codespaces environment config
- `.devcontainer/install.sh` — installs kind, ArgoCD CLI, Claude Code
- `.devcontainer/setup-argocd.sh` — creates cluster and deploys ArgoCDd_demo