# Atlantis for OpenTofu

```bash
helm repo add atlantis https://runatlantis.github.io/helm-charts
kubectl create namespace atlantis || true
kubectl -n atlantis create configmap atlantis-repos --from-file=repos.yaml -o yaml --dry-run=client | kubectl apply -f -
helm upgrade --install atlantis atlantis/atlantis -n atlantis -f values.yaml
```
