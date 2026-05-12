#!/usr/bin/env bash

set -euo pipefail

echo "== ArgoCD doctor =="

echo
printf "[1/8] kubectl client: "
kubectl version --client >/dev/null
kubectl version --client | head -n 1

echo
printf "[2/8] cluster reachability: "
if kubectl cluster-info >/tmp/argocd-doctor-cluster.txt 2>&1; then
  echo "ok"
else
  echo "failed"
  cat /tmp/argocd-doctor-cluster.txt
  exit 1
fi

echo
printf "[3/8] argocd namespace: "
if kubectl get ns argocd >/dev/null 2>&1; then
  echo "present"
else
  echo "missing"
  exit 1
fi

echo
printf "[4/8] argocd-server service: "
if kubectl get svc -n argocd argocd-server >/dev/null 2>&1; then
  echo "present"
  kubectl get svc -n argocd argocd-server
else
  echo "missing"
  exit 1
fi

echo
echo "[5/8] pod status (argocd):"
kubectl get pods -n argocd

echo
echo "[6/8] repo-server init/container diagnostics:"
for pod in $(kubectl get pods -n argocd -l app.kubernetes.io/name=argocd-repo-server -o name); do
  echo "--- ${pod}"
  kubectl get "$pod" -n argocd -o jsonpath='{.status.phase}{"\n"}' || true
  kubectl describe "$pod" -n argocd | tail -n 30 || true
  echo
 done

echo
if [[ -f /tmp/argocd-portforward.log ]]; then
  echo "[7/8] recent port-forward log:"
  tail -n 40 /tmp/argocd-portforward.log || true
else
  echo "[7/8] no /tmp/argocd-portforward.log yet"
fi

echo
if ss -ltn | grep -q ':8080 '; then
  echo "[8/8] local listener found on 8080"
elif ss -ltn | grep -q ':8081 '; then
  echo "[8/8] local listener found on 8081"
else
  echo "[8/8] no local listener on 8080/8081"
fi

echo
echo "Doctor run complete."
