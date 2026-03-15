mkdir -p /workspaces/argo_cd_demo/tls

mv tls-setup.yaml /workspaces/argo_cd_demo/tls/tls-setup.yaml

cat <<EOF > /workspaces/argo_cd_demo/tls/README.md
# ArgoCD TLS Setup

Self-signed TLS for ArgoCD components using cert-manager.

## Prerequisites
\`\`\`bash
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/latest/download/cert-manager.yaml
kubectl wait --namespace cert-manager --for=condition=ready pod --all --timeout=120s
\`\`\`

## Apply
\`\`\`bash
kubectl apply -f tls/tls-setup.yaml
\`\`\`

## After applying
\`\`\`bash
# Remove --insecure from argocd-server
kubectl -n argocd edit deployment argocd-server

# Restart components
kubectl rollout restart deployment/argocd-repo-server -n argocd
kubectl rollout restart deployment/argocd-dex-server -n argocd
kubectl rollout restart deployment/argocd-server -n argocd

# Port-forward over HTTPS
kubectl port-forward svc/argocd-server 8080:443 -n argocd --address 0.0.0.0 &
\`\`\`
EOF

git add tls/
git commit -m "add: ArgoCD TLS setup with cert-manager self-signed CA"
git push
