## Argo-cd
kubectl get pods -n argocd
# Restart the port-forward manually
kubectl port-forward svc/argocd-server -n argocd 8080:443 &
# Then check the Ports tab in VS Code
