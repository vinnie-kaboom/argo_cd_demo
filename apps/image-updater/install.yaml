# Argo CD Image Updater – install manifest
# This is an ALTERNATIVE to the CI git write-back job.
# Choose one approach; using both causes race conditions.
#
# Install with:
#   kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj-labs/argocd-image-updater/stable/manifests/install.yaml
#
# Then apply this ConfigMap to configure DockerHub credentials (if the image is private):
---
apiVersion: v1
kind: Secret
metadata:
  name: dockerhub-creds
  namespace: argocd
  labels:
    app.kubernetes.io/part-of: argocd-image-updater
type: Opaque
stringData:
  # Create with:
  #   kubectl create secret generic dockerhub-creds -n argocd \
  #     --from-literal=credentials="your-dockerhub-username:<access-token>"
  credentials: "your-dockerhub-username:<replace-with-access-token>"
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: argocd-image-updater-config
  namespace: argocd
data:
  # Point Image Updater at DockerHub
  registries.conf: |
    registries:
      - name: DockerHub
        prefix: docker.io
        api_url: https://registry-1.docker.io
        credentials: secret:argocd/dockerhub-creds#credentials
        defaultns: library
        default: true

  # Write updated tags back to git so the repo stays the source of truth
  git.commit-message-template: |
    ci(image-updater): update {{ .AppName }} to {{ .ImageList }}
