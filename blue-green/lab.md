## 🎯 Lab Goal

Deploy a blue-green release using the Argo Rollouts controller and verify that traffic switches between the active and preview services in a controlled way.

## 📝 Overview & Concepts

This lab uses the `Rollout` custom resource, not a standard Kubernetes `Deployment`. That means the cluster must have the Argo Rollouts controller and CRDs installed before you apply anything in `blue-green/manifests/`.

If you see this error:

```bash
error: resource mapping not found for name: "rollout-bluegreen" namespace: "bluegreen-lab" from "blue-green/manifests/rollout.yaml": no matches for kind "Rollout" in version "argoproj.io/v1alpha1"
ensure CRDs are installed first
```

the cluster is missing Argo Rollouts.

## ✅ Prerequisite: Install Argo Rollouts

For an existing cluster, run:

```bash
kubectl create namespace argo-rollouts --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n argo-rollouts -f https://github.com/argoproj/argo-rollouts/releases/latest/download/install.yaml
kubectl rollout status deployment/argo-rollouts -n argo-rollouts --timeout=180s
```

Verify the install:

```bash
kubectl get crd rollouts.argoproj.io
kubectl get pods -n argo-rollouts
```

If `kubectl argo rollouts` is not available yet in your Codespace, install the plugin once:

```bash
curl -sSL -o /tmp/kubectl-argo-rollouts https://github.com/argoproj/argo-rollouts/releases/latest/download/kubectl-argo-rollouts-linux-amd64
sudo install -m 555 /tmp/kubectl-argo-rollouts /usr/local/bin/kubectl-argo-rollouts
rm /tmp/kubectl-argo-rollouts
```

For new Codespaces or rebuilt devcontainers, `.devcontainer/create-cluster.sh` now installs Argo Rollouts automatically.
For new Codespaces or rebuilt devcontainers, `.devcontainer/install.sh` now installs the `kubectl argo rollouts` plugin automatically.

## 📋 Lab Tasks

1. Apply the blue-green manifests:

```bash
kubectl apply -f ./blue-green/manifests/
```

2. Confirm the rollout and services exist:

```bash
kubectl get rollout -n bluegreen-lab
kubectl get svc -n bluegreen-lab
kubectl get pods -n bluegreen-lab
```

3. Inspect the rollout status:

```bash
kubectl describe rollout rollout-bluegreen -n bluegreen-lab
kubectl get rollout rollout-bluegreen -n bluegreen-lab -w
kubectl argo rollouts get rollout rollout-bluegreen -n bluegreen-lab
```

4. Update the image or app color in [blue-green/manifests/rollout.yaml](blue-green/manifests/rollout.yaml) and re-apply the manifest.

5. Observe how the preview service receives the new ReplicaSet first, then promote it when you are ready.

## 📚 Helpful Resources

- [Argo Rollouts BlueGreen Strategy](https://argo-rollouts.readthedocs.io/en/stable/features/bluegreen/)
- [Argo Rollouts Installation](https://argo-rollouts.readthedocs.io/en/stable/installation/)

## 💭 Reflection Questions

1. Why does a blue-green rollout require a controller rather than just Kubernetes `Service` objects?
2. What is the operational difference between the active service and the preview service during a release?
3. When would you disable automatic promotion and require a manual promotion step?