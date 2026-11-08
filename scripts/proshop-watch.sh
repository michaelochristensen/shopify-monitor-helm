#!/bin/sh
# Restock/online-watcher til proshop.dk.
#
# Produktsiden er kun "online", naar Proshop har publiceret varen: saa indeholder
# JSON-LD "sku" vores varenummer. Foer da redirecter URL'en til en kategoriside.
#
# Tilstande:
#   offline              - produktsiden findes ikke endnu (redirect til kategori)
#   online|InStock       - paa lager
#   online|PreOrder      - kan forudbestilles ("Bestilt: forventet paa lager ...")
#   online|<andet>       - online, men hverken paa lager eller forudbestilling
#
# Der sendes alert:
#   - foerste gang produktsiden gaar fra offline til online
#   - naar den skifter til InStock
#   - pamindelse hver 30. minut mens den er InStock
#
# Miljoevariabler:
#   WATCH_URL         produktside
#   PRODUCT_ID        varenummer (SKU) der skal findes i JSON-LD
#   DISCORD_WEBHOOK   webhook-URL
#   INTERVAL          sekunder mellem tjek (default 20)
#   ITEM_TITLE        varenavn i beskeden
#   DETECT_ONLY=1     udskriv kun tilstand og afslut (til test)

set -u

URL="${WATCH_URL:-https://www.proshop.dk/Pokemon/Pokemon-Ultra-Premium-Collection-30th-Celebration-assorted/3519996}"
PRODUCT_ID="${PRODUCT_ID:-3519996}"
HOOK="${DISCORD_WEBHOOK:-}"
INTERVAL="${INTERVAL:-20}"
TITLE="${ITEM_TITLE:-Pokemon Ultra Premium Collection 30th Celebration}"
REMIND_AFTER=1800
UA="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"

log() { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $*"; }

# 1749.00 -> "1.749,00 kr."
fmt_price() {
  awk -v p="$1" 'BEGIN {
    if (p == "") exit
    split(p, a, ".")
    intp = a[1]; dec = (a[2] == "" ? "00" : a[2])
    if (length(dec) == 1) dec = dec "0"
    s = ""; n = length(intp)
    for (i = 1; i <= n; i++) {
      s = s substr(intp, i, 1)
      r = n - i
      if (r > 0 && r % 3 == 0) s = s "."
    }
    printf "%s,%s kr.", s, dec
  }'
}

# JSON-payload. $1 = type (online|stock|remind), $2 = status-tekst,
# $3 = pris (formateret), $4 = note (fx forventet dato)
payload() {
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  case "$1" in
    online)
      content="@here **${TITLE}** er nu online hos Proshop!"
      color=3447003
      ;;
    stock)
      content="@here **${TITLE}** er på lager hos Proshop!"
      color=3066993
      ;;
    remind)
      content="**${TITLE}** er stadig på lager hos Proshop."
      color=3066993
      ;;
  esac
  desc="**Status:** $2"
  [ -n "$3" ] && desc="$desc\n**Pris:** $3"
  [ -n "$4" ] && desc="$desc\n**Levering:** $4"
  desc="$desc\n**Butik:** proshop.dk\n\n[Åbn varen](${URL})"
  if [ "$1" = "remind" ]; then
    mentions=''
  else
    mentions=',"allowed_mentions":{"parse":["everyone"]}'
  fi
  cat <<EOF
{"content":"${content}"${mentions},"embeds":[{"title":"${TITLE}","url":"${URL}","color":${color},"description":"${desc}","footer":{"text":"proshop-watch · tjek hvert ${INTERVAL}. sekund"},"timestamp":"${ts}"}]}
EOF
}

post() {
  curl -sS -m 20 -o /dev/null -w '%{http_code}' \
    -X POST -H 'Content-Type: application/json' \
    --data-binary "$1" "$HOOK" 2>/dev/null
}

# Udskriver "offline||||" eller "online|<availability>|<pris>|<note>"
fetch_state() {
  out=$(curl -sS --compressed -m 25 -A "$UA" -H 'Accept-Language: da-DK,da;q=0.9' \
    -L -w '\n%{http_code}' "$URL" 2>/dev/null) || { echo 'error||||'; return; }
  code=$(printf '%s' "$out" | tail -n 1)
  [ "$code" = "200" ] || { echo "http${code}||||"; return; }
  # normaliser HTML til én linje, saa regex kan virke paa tvaers af linjeskift
  html=$(printf '%s' "$out" | sed '$d' | tr -d '\r' | tr '\n' ' ')

  if ! printf '%s' "$html" | grep -qE "\"sku\"[[:space:]]*:[[:space:]]*\"${PRODUCT_ID}\""; then
    echo 'offline||||'; return
  fi

  avail=$(printf '%s' "$html" | sed -n 's/.*"availability"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)
  avail=${avail##*/}
  [ -n "$avail" ] || avail=ukendt

  price=$(printf '%s' "$html" | sed -n 's/.*"price"[[:space:]]*:[[:space:]]*"\([0-9][0-9.]*\)".*/\1/p' | head -n 1)
  note=$(printf '%s' "$html" | grep -oE 'Bestilt: forventet p[^<]{0,40}' | head -n 1 | sed 's/[[:space:]]*$//')

  echo "online|${avail}|${price}|${note}"
}

state=""
last_alert=0
fail=0

# Test-tilstand: vis blot hvad siden aktuelt rapporterer
if [ "${DETECT_ONLY:-0}" = "1" ]; then
  fetch_state
  exit 0
fi

if [ -z "$HOOK" ]; then
  log "FEJL: DISCORD_WEBHOOK er ikke sat"
  exit 1
fi

log "starter: $URL (varenr. ${PRODUCT_ID}, hvert ${INTERVAL}. sekund)"

while true; do
  new=$(fetch_state)
  now=$(date +%s)

  # split "kind|avail|price|note" uden at spaerre paa mellemrum i note
  oldIFS=$IFS; IFS='|'; set -- $new; IFS=$oldIFS
  kind=${1:-}; avail=${2:-}; price=${3:-}; note=${4:-}
  price_fmt=$(fmt_price "$price")

  case "$kind" in
    offline)
      fail=0
      [ "$state" != "offline" ] && log "produktsiden er ikke online endnu"
      ;;
    online)
      fail=0
      case "$avail" in
        InStock) status="på lager" ;;
        PreOrder) status="kan forudbestilles" ;;
        OutOfStock) status="udsolgt" ;;
        *) status="$avail" ;;
      esac
      [ -n "$note" ] && status="$status ($note)"

      prev_kind=${state%%|*}
      prev_rest=${state#*|}
      prev_avail=${prev_rest%%|*}

      if [ "$prev_kind" != "online" ]; then
        if [ "$avail" = "InStock" ]; then
          resp=$(post "$(payload stock "på lager" "$price_fmt" "$note")")
          log "PA LAGER - alert sendt (HTTP $resp)"
        else
          resp=$(post "$(payload online "$status" "$price_fmt" "$note")")
          log "ONLINE ($avail) - alert sendt (HTTP $resp)"
        fi
        last_alert=$now
      elif [ "$avail" = "InStock" ] && [ "$prev_avail" != "InStock" ]; then
        resp=$(post "$(payload stock "på lager" "$price_fmt" "$note")")
        last_alert=$now
        log "NU PA LAGER - alert sendt (HTTP $resp)"
      elif [ "$avail" = "InStock" ] && [ $((now - last_alert)) -ge $REMIND_AFTER ]; then
        resp=$(post "$(payload remind "på lager" "$price_fmt" "$note")")
        last_alert=$now
        log "stadig pa lager - pamindelse sendt (HTTP $resp)"
      fi
      ;;
    *)
      fail=$((fail + 1))
      if [ $((fail % 30)) -eq 1 ]; then
        log "kunne ikke tjekke ($kind)"
      fi
      ;;
  esac

  state="$new"
  sleep "$INTERVAL"
done
