#!/bin/sh
# Restock-watcher til smukshop.dk (Venue Manager CMP, ikke Shopify).
# Tjekker produktsiden og poster til Discord, naar varen skifter fra
# udsolgt til paa lager. Sender en pamindelse hver 30. minut mens den
# er paa lager.
#
# Miljoevariabler:
#   WATCH_URL         produktside
#   DISCORD_WEBHOOK   webhook-URL
#   INTERVAL          sekunder mellem tjek (default 10)
#   ITEM_TITLE        varenavn i beskeden
#   ITEM_PRICE        pris i beskeden

set -u

URL="${WATCH_URL:-https://smukshop.dk/armbaand/partout27}"
HOOK="${DISCORD_WEBHOOK:-}"
INTERVAL="${INTERVAL:-10}"
TITLE="${ITEM_TITLE:-Partoutarmbånd til Smukfest 2027}"
PRICE="${ITEM_PRICE:-3.895,00 kr.}"
REMIND_AFTER=1800
UA="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"

log() { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $*"; }

if [ -z "$HOOK" ]; then
  log "FEJL: DISCORD_WEBHOOK er ikke sat"
  exit 1
fi

payload() {
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  cat <<EOF
{"content":"@here **${TITLE}** er på lager!","allowed_mentions":{"parse":["everyone"]},"embeds":[{"title":"${TITLE}","url":"${URL}","color":3066993,"description":"**Status:** på lager\n**Pris:** ${PRICE}\n**Butik:** smukshop.dk\n\n[Åbn varen](${URL})","footer":{"text":"smukshop-watch · tjek hvert ${INTERVAL}. sekund"},"timestamp":"${ts}"}]}
EOF
}

post() {
  curl -sS -m 20 -o /dev/null -w '%{http_code}' \
    -X POST -H 'Content-Type: application/json' \
    --data-binary "$1" "$HOOK" 2>/dev/null
}

# Siger "in", "out", "unknown" eller "httpXXX"/"error"
fetch_state() {
  out=$(curl -sS -m 20 -A "$UA" -w '\n%{http_code}' "$URL" 2>/dev/null) || { echo error; return; }
  code=$(printf '%s' "$out" | tail -n 1)
  [ "$code" = "200" ] || { echo "http${code}"; return; }
  # normaliser HTML: knap-tags kan vaere brudt over flere linjer
  html=$(printf '%s' "$out" | sed '$d' | tr -d '\r' | tr '\n' ' ')

  # koeb-knap for variant 1515:3352 (raekkefoelgen af attributter kan variere)
  if printf '%s' "$html" | grep -qE '<button[^>]*data-content="add-to-cart"[^>]*product_variant_id_1515:3352'; then
    echo in; return
  fi
  if printf '%s' "$html" | grep -qE '<button[^>]*product_variant_id_1515:3352[^>]*data-content="add-to-cart"'; then
    echo in; return
  fi
  # venteliste-knap = udsolgt
  if printf '%s' "$html" | grep -qF 'waitlist.showAddToWaitlist(3352)'; then
    echo out; return
  fi
  echo unknown
}

state=""
last_alert=0
fail=0

log "starter: $URL (hvert ${INTERVAL}. sekund)"

while true; do
  new=$(fetch_state)
  now=$(date +%s)

  case "$new" in
    in)
      fail=0
      if [ "$state" != "in" ]; then
        resp=$(post "$(payload)")
        last_alert=$now
        log "PA LAGER - alert sendt (HTTP $resp)"
      elif [ $((now - last_alert)) -ge $REMIND_AFTER ]; then
        resp=$(post "$(payload)")
        last_alert=$now
        log "stadig pa lager - pamindelse sendt (HTTP $resp)"
      fi
      ;;
    out)
      fail=0
      [ "$state" != "out" ] && log "udsolgt"
      ;;
    *)
      fail=$((fail + 1))
      if [ $((fail % 30)) -eq 1 ]; then
        log "status ikke afgjort ($new)"
      fi
      ;;
  esac

  state="$new"
  sleep "$INTERVAL"
done
