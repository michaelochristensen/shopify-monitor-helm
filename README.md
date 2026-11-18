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

`templates/proshop-watch.yaml` watches a list of Proshop products
(`proshopWatch.targets`) and alerts when a product page goes live and when the
item is in stock. Every target gets its own ConfigMap and Deployment, named
`<fullname>-proshop-watch-<productId>`.

Proshop sits behind a Cloudflare "managed challenge", so plain HTTP clients get
`403 Just a moment...`. The watcher therefore reads the page through the
[r.jina.ai](https://r.jina.ai) reader, which renders it in a real browser.
Configure it with `proshopWatch.reader` (set to `""` to fetch the URL directly).

Detection, from the rendered page:

| State | Marker |
|---|---|
| offline | page redirects (the reader reports a `Final URL` different from the product URL) |
| online | `Varenummer: **<id>**` is present |
| in stock | `15+ stk. på lager` or `På lager` **in the product's own status block** |
| pre-order | `Bestilt: forventet på lager <date>` in the same block |
| sold out | `Ikke på lager` / `Udsolgt` in the same block |
| not for sale yet | no status block, but `Modtag notifikation` is present (no alert) |

The status block is the text immediately before `Lagerstatus i vores Pick-up
Points`. This matters because when the product is not visible Proshop serves a
category page (and product pages carry accessory lists) that also contain
`På lager` and prices for *other* items — matching those produced false
"på lager" alerts.

A new state must be seen twice in a row before an alert is sent, and repeated
"online" alerts are rate-limited to one per hour. Alerts ping `@here`; a
reminder follows every 30 minutes while the product is in stock. Settings live
under `proshopWatch` in `values.yaml`; add a product under
`proshopWatch.targets` with `productId`, `url` and `itemTitle`, then render and
apply again.

## Applying manifests with Danish characters

`helm template ... | kubectl apply -f -` from PowerShell mangles UTF-8 (all
`æ/ø/å` become `??`), which breaks both the alert texts and the `grep` patterns
in the scripts. Render to a file first:

```powershell
cmd /c "helm template shopify-monitor . -n shopify-monitor > $env:TEMP\render.yaml"
kubectl apply -f $env:TEMP\render.yaml
```
