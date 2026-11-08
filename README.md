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

## proshop.dk product watcher

`templates/proshop-watch.yaml` watches one Proshop product and alerts when the
product page goes live and when the item is in stock.

Proshop sits behind a Cloudflare "managed challenge", so plain HTTP clients get
`403 Just a moment...`. The watcher therefore reads the page through the
[r.jina.ai](https://r.jina.ai) reader, which renders it in a real browser.
Configure it with `proshopWatch.reader` (set to `""` to fetch the URL directly).

Detection, from the rendered page:

| State | Marker |
|---|---|
| offline | page redirects (the reader reports a `Final URL` different from the product URL) |
| online | `Varenummer: **<id>**` is present |
| in stock | `På lager` |
| pre-order | `Bestilt: forventet på lager <date>` |

Alerts ping `@here`; a reminder follows every 30 minutes while the product is in
stock. Settings live under `proshopWatch` in `values.yaml`.

## Applying manifests with Danish characters

`helm template ... | kubectl apply -f -` from PowerShell mangles UTF-8 (all
`æ/ø/å` become `??`), which breaks both the alert texts and the `grep` patterns
in the scripts. Render to a file first:

```powershell
cmd /c "helm template shopify-monitor . -n shopify-monitor > $env:TEMP\render.yaml"
kubectl apply -f $env:TEMP\render.yaml
```
