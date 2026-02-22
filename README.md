# shopify-monitor-helm

Helm chart and Argo CD application definition for deploying `micmacha/home:shopify_monitor`.

## Files

- `Chart.yaml`: chart metadata
- `values.yaml`: deployment values
- `templates/deployment.yaml`: Kubernetes Deployment
- `argocd-application.yaml`: Argo CD Application pointing to this repo

## Deploy via Argo CD

```powershell
kubectl apply -f argocd-application.yaml
```