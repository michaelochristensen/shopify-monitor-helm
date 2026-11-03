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

## smukshop.dk restock watcher

`templates/smukshop-watch.yaml` deploys a small watcher for a single product at
smukshop.dk. That shop runs Venue Manager CMP, not Shopify (there is no
`/products.json`), so it is scraped from the product page instead.

It polls every `smukshopWatch.intervalSeconds` (default 10 s) and posts to the
Discord webhook when the product goes from sold out to in stock, with an
`@here` ping and a reminder every 30 minutes while it stays in stock.

Detection, from the product page markup:

| State | Marker |
|---|---|
| in stock | `<button ... data-content="add-to-cart" ... product_variant_id_1515:3352>` |
| sold out | `waitlist.showAddToWaitlist(3352)` (waitlist button) |

HTML is newline-normalised before matching, because the button tag is split
across lines. All settings live under `smukshopWatch` in `values.yaml`
(`enabled`, `url`, `intervalSeconds`, `itemTitle`, `itemPrice`, `webhook`).
