# ArgoCD Troubleshooting Guide

## Issue: ArgoCD App Showing OutOfSync (False Positive)

### Symptoms

- ArgoCD UI shows an app as `OutOfSync` even though no intentional changes were made
- `argocd app diff` reveals a field that was automatically injected by Kubernetes (not present in your Git manifest)

-----

## Step 1: Connect the ArgoCD CLI

Before running any `argocd` commands, make sure the port-forward is running and you’re logged in.

### Check if port-forward is active

```bash
ps aux | grep port-forward
```

You should see something like:

```
kubectl port-forward svc/argocd-server -n argocd 8080:80 --address 0.0.0.0
```

If it’s not running, start it:

```bash
kubectl port-forward svc/argocd-server -n argocd 8080:80 --address 0.0.0.0 &
```

### Log in to ArgoCD CLI

```bash
argocd login localhost:8080 --insecure --username admin \
  --password $(kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d)
```

-----

## Step 2: Identify the Diff

Run the diff command to see exactly what ArgoCD thinks is out of sync:

```bash
argocd app diff <app-name> --server localhost:8080 --insecure
```

**Example output that revealed a false positive:**

```
===== apps/Deployment k8s-dashboard/k8s-dashboard-headlamp ======
203a204
>       hostUsers: true
```

### What this means

`hostUsers: true` is a field that newer versions of Kubernetes inject into pod specs as a default. Since it wasn’t explicitly set in the Helm chart values or manifest, ArgoCD flags it as drift — even though it’s not a real change.

-----

## Step 3: Fix the False Positive with `ignoreDifferences`

The cleanest fix is to tell ArgoCD to ignore that specific field using `ignoreDifferences` in the Application manifest.

### Updated Application Manifest (k8s-dashboard example)

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: k8s-dashboard
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://kubernetes-sigs.github.io/headlamp/
    chart: headlamp
    targetRevision: 0.40.0
    helm:
      values: |
        config:
          inCluster: true
  destination:
    server: https://kubernetes.default.svc
    namespace: k8s-dashboard
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
  ignoreDifferences:
    - group: apps
      kind: Deployment
      name: k8s-dashboard-headlamp
      jsonPointers:
        - /spec/template/spec/hostUsers
```

### Apply the fix

```bash
kubectl apply -f k8s-dashboard-app.yaml
```

ArgoCD will reconcile shortly after and the app should return to `Synced`.

-----

## Common CLI Errors & Fixes

|Error                                       |Cause                               |Fix                                                                  |
|--------------------------------------------|------------------------------------|---------------------------------------------------------------------|
|`Argo CD server address unspecified`        |ArgoCD CLI has no server context    |Pass `--server localhost:8080 --insecure` or run `argocd login` first|
|`Failed to establish connection: EOF`       |Port-forward not running            |Start port-forward with `kubectl port-forward`                       |
|`WARNING: server is not configured with TLS`|Running ArgoCD in insecure/HTTP mode|Expected in dev — type `y` to proceed                                |

-----

## Login Loop After Successful Password Entry

### Symptoms

- You enter valid admin credentials in the ArgoCD UI
- The page refreshes and returns to the login screen
- `kubectl get events -n argocd` shows a `FailedMount` event for `argocd-repo-server`

Example:

```text
MountVolume.SetUp failed for volume "ssh-known-hosts": failed to sync configmap cache: timed out waiting for the condition
```

### Root cause

This usually means the ArgoCD Helm release is only partially installed. In this repo's Codespaces setup, that happened because the bootstrap script treated an existing `argocd` namespace as proof that ArgoCD was fully installed, so a broken release could be skipped on later runs.

### Fix

Re-run the bootstrap script so Helm reconciles the release:

```bash
bash .devcontainer/create-cluster.sh
```

Then confirm the core pods are healthy:

```bash
kubectl get pods -n argocd
```

Once `argocd-server` and `argocd-repo-server` are `Running`, start the port-forward again if needed:

```bash
kubectl port-forward svc/argocd-server -n argocd 8080:80 --address 0.0.0.0
```

Then log back in at `http://localhost:8080`.

-----

## Notes

- **`hostUsers: true`** is a Kubernetes-injected default introduced in newer K8s versions. It is safe to ignore in ArgoCD for Helm-managed deployments.
- **`ignoreDifferences`** uses JSON pointers to target specific fields. This is preferable to modifying the chart or values just to match K8s defaults.
- In a GitHub Codespaces devcontainer setup, port-forwards do not survive restarts — you’ll need to re-run the `argocd login` command after each Codespace restart.