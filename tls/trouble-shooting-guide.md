# cert-manager TLS Setup Troubleshooting Guide

## Overview

This guide covers installing cert-manager on a Kubernetes 1.29 cluster (GitHub Codespaces),
setting up self-signed TLS certificates for ArgoCD, and the issues encountered along the way.

-----

## Problem: `kubectl apply -f ./tls/` Fails with CRD Errors

### Symptom

```
resource mapping not found for name: "selfsigned-issuer" namespace: "" from "tls/tls-setup.yaml": no matches for kind "ClusterIssuer" in version "cert-manager.io/v1"
ensure CRDs are installed first
```

### Cause

cert-manager is not installed — the `ClusterIssuer`, `Certificate`, and `Issuer` resource
types don’t exist in the cluster yet.

-----

## Step 1: Check Your Kubernetes Version First

This is critical — cert-manager `latest` uses features not available in older K8s versions.

```bash
kubectl version
```

**In this environment:** Server is K8s **1.29.2**, client is 1.35.2 (skew warning is expected, ignore it).

-----

## Step 2: Install the Correct cert-manager Version

For **K8s 1.29**, use cert-manager **v1.14.7**. Do NOT use `latest` — it will fail with:

```
strict decoding error: unknown field "spec.versions[0].selectableFields"
```

### If you previously attempted to install latest, clean it up first:

```bash
kubectl delete -f https://github.com/cert-manager/cert-manager/releases/latest/download/cert-manager.yaml --ignore-not-found
```

### Install the compatible version:

```bash
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.14.7/cert-manager.yaml
```

-----

## Step 3: Wait for cert-manager Pods to be Ready

```bash
kubectl get pods -n cert-manager -w
```

Wait until all three show `1/1 Running`:

```
NAME                                       READY   STATUS    RESTARTS   AGE
cert-manager-7457b85f4f-bt7qp              1/1     Running   0          58s
cert-manager-cainjector-5f77bfbd89-hg2ld   1/1     Running   0          58s
cert-manager-webhook-69bb4fc6c-7h72f       1/1     Running   0          58s
```

> **Important:** Even after pods show Running, wait an additional 30-60 seconds for the
> webhook TLS to fully bootstrap before proceeding. Applying too early causes:
> 
> ```
> x509: certificate signed by unknown authority
> ```

### Verify CRDs are all installed:

```bash
kubectl get crds | grep cert-manager
```

You should see **6 CRDs**:

```
certificaterequests.cert-manager.io
certificates.cert-manager.io
challenges.acme.cert-manager.io
clusterissuers.cert-manager.io
issuers.cert-manager.io
orders.acme.cert-manager.io
```

-----

## Step 4: Apply the TLS Configuration

```bash
kubectl apply -f ./tls/
```

Expected output:

```
clusterissuer.cert-manager.io/selfsigned-issuer created
certificate.cert-manager.io/argocd-ca created
issuer.cert-manager.io/argocd-issuer created
certificate.cert-manager.io/argocd-server-tls created
certificate.cert-manager.io/argocd-repo-server-tls created
certificate.cert-manager.io/argocd-dex-server-tls created
```

-----

## Step 5: Verify Certificates are Issued

```bash
kubectl get certificates -n argocd
```

All certificates should show `READY: True`:

```
NAME                     READY   SECRET                   AGE
argocd-ca                True    argocd-ca-secret         44s
argocd-dex-server-tls    True    argocd-dex-server-tls    44s
argocd-repo-server-tls   True    argocd-repo-server-tls   44s
argocd-server-tls        True    argocd-server-tls        44s
```

-----

## Step 6: Restart ArgoCD Components

ArgoCD needs to be restarted to pick up the new TLS certificates:

```bash
kubectl rollout restart deployment/argocd-server -n argocd
kubectl rollout restart deployment/argocd-repo-server -n argocd
kubectl rollout restart deployment/argocd-dex-server -n argocd
```

Verify they come back up cleanly:

```bash
kubectl get pods -n argocd
```

All pods should return to `1/1 Running`.

-----

## What’s Next

1. **Switch ArgoCD back to HTTPS mode** — now that TLS certs are in place, remove the
   `--insecure` flag from the ArgoCD server deployment so it serves on HTTPS properly.
1. **Update the port-forward** — change from `8080:80` to `8080:443` to connect over HTTPS:
   
   ```bash
   kubectl port-forward svc/argocd-server -n argocd 8080:443 --address 0.0.0.0 &
   ```
1. **Update ArgoCD CLI login** — drop the `--insecure` flag:
   
   ```bash
   argocd login localhost:8080 --username admin \
     --password $(kubectl -n argocd get secret argocd-initial-admin-secret \
     -o jsonpath="{.data.password}" | base64 -d)
   ```
1. **Verify ArgoCD UI loads over HTTPS** — open the Codespaces forwarded port in the browser
   and confirm it loads with a valid (self-signed) cert.
1. **Consider adding cert-manager to your install.sh** — so it’s automatically set up on
   Codespace restart and you don’t have to repeat these steps each time.

-----

## Common Errors Reference

|Error                                                      |Cause                               |Fix                               |
|-----------------------------------------------------------|------------------------------------|----------------------------------|
|`no matches for kind "ClusterIssuer"`                      |cert-manager not installed          |Install cert-manager first        |
|`selectableFields` strict decoding error                   |cert-manager version too new for K8s|Use v1.14.7 for K8s 1.29          |
|`x509: certificate signed by unknown authority`            |Webhook not fully bootstrapped yet  |Wait 30-60s after pods are Running|
|`cainjector has been configured to watch certificates` loop|CRDs missing                        |Reinstall cert-manager CRDs       |