# root-app (App of Apps)

This README explains the purpose and behavior of [root-app.yaml](root-app.yaml), which is the bootstrap Argo CD Application for this repository.

## What `root-app.yaml` does

`root-app` is an **App of Apps** entrypoint. You apply this one manifest once, and Argo CD then discovers and manages the other Application manifests under `argocd/`.

In short:
- Bootstraps platform delivery from a single Argo CD Application
- Recursively scans the `argocd/` directory in this repo
- Syncs child Application manifests into the cluster
- Continuously reconciles drift and prunes removed resources

## Key behavior by spec section

### Metadata
- `name: root-app`: The parent Application name in Argo CD
- `namespace: argocd`: Where the Application CR is created
- `resources-finalizer.argocd.argoproj.io`: Ensures managed resources are cleaned up when deleting the app

### Source
- `repoURL`: Points Argo CD to this Git repository
- `targetRevision: HEAD`: Tracks latest commit on the configured branch
- `path: argocd`: Limits discovery to the `argocd/` folder
- `directory.recurse: true`: Walks subdirectories
- `directory.include: "*.yaml"`: Includes all YAML manifests in that path

### Destination
- `server: https://kubernetes.default.svc`: Targets the in-cluster Kubernetes API
- `namespace: argocd`: Default destination namespace for namespaced resources

### Sync policy
- `automated.prune: true`: Deletes resources removed from Git
- `automated.selfHeal: true`: Reverts out-of-band cluster drift
- `syncOptions: CreateNamespace=true`: Creates destination namespaces if missing

## Operational flow

1. Apply `root-app.yaml` once.
2. Argo CD reads `argocd/**/*.yaml`.
3. Child Applications (apps/infra/project manifests) are created.
4. Those child Applications deploy and reconcile their own resources.

## Apply and verify

Apply:

```bash
kubectl apply -f apps/root-app.yaml
```

Verify:

```bash
kubectl get applications -n argocd
argocd app get root-app
```

## Notes

- `targetRevision: HEAD` is convenient for demos but can be risky in production. Consider pinning to a branch or tag.
- Recursive include of `*.yaml` means any YAML under `argocd/` can be treated as part of bootstrap; keep that directory curated.
