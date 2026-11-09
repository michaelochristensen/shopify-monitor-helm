#!/bin/sh
# Restock/online-watcher til proshop.dk.
#
# Proshop ligger bag Cloudflares "managed challenge", saa et almindeligt
# curl-kald fra klyngen faar "Just a moment..." (HTTP 403). Derfor hentes
# siden gennem r.jina.ai, som koerer en rigtig browser og derfor kommer
# igennem. Saet READER="" for at hente direkte i stedet.
#
# Produktsiden er kun "online", naar Proshop har publiceret varen: saa staar
# der "Varenummer: **<id>**" paa siden. Foer da redirecter URL'en til en
# kategoriside (Jina viser det som "Final URL:").
#
# "Paa lager" accepteres KUN som hovedstatus, dvs. "På lager" efterfulgt af en
# pris ("På lager 1.749,00 kr."). Tekster som "På lager, kan afhentes" i
# Pick-up Point-listen eller "15+ stk. på lager" gaelder ikke.
#
# Tilstande:
#   offline              - produktsiden findes ikke endnu
#   online|InStock       - paa lager
#   online|PreOrder      - kan forudbestilles ("Bestilt: forventet paa lager ...")
#   online|OutOfStock    - udsolgt
#   online|ukendt        - produktsiden findes, men status kan ikke laeses
#
# En ny tilstand skal ses to gange i traek, foer der sendes alert. Det undgaar
# falske alarmer naar Proshop/Jina skifter mellem produktside og redirect.
#
# Der sendes alert:
#   - foerste gang produktsiden gaar fra offline til online
#   - naar den skifter til InStock
#   - pamindelse hver 30. minut mens den er InStock
#
# Miljoevariabler:
#   WATCH_URL         produktside
#   PRODUCT_ID        varenummer (SKU)
#   DISCORD_WEBHOOK   webhook-URL
#   INTERVAL          sekunder mellem tjek (default 20)
#   ITEM_TITLE        varenavn i beskeden
#   READER            laeser-prefix (default https://r.jina.ai/; "" = direkte)
#   DETECT_ONLY=1     udskriv kun tilstand og afslut (til test)

set -u

URL="${WATCH_URL:-https://www.proshop.dk/Pokemon/Pokemon-Ultra-Premium-Collection-30th-Celebration-assorted/3519996}"
PRODUCT_ID="${PRODUCT_ID:-3519996}"
HOOK="${DISCORD_WEBHOOK:-}"
INTERVAL="${INTERVAL:-20}"
TITLE="${ITEM_TITLE:-Pokemon Ultra Premium Collection 30th Celebration}"
READER="${READER-https://r.jina.ai/}"
REMIND_AFTER=1800
UA="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"

log() { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $*"; }

# JSON-payload. $1 = type (online|stock|remind), $2 = status, $3 = pris, $4 = forventet dato
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
  [ -n "$4" ] && desc="$desc\n**Forventet på lager:** $4"
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

# Linje 1: "offline||||" eller "online|<status>|<pris>|<forventet-dato>"
# Linje 2: bevis (uddrag af siden omkring status-teksten)
fetch_state() {
  out=$(curl -sS --compressed -m 45 -A "$UA" -H 'X-No-Cache: true' \
    -w '\n%{http_code}' "${READER}${URL}" 2>/dev/null) || { printf 'error||||\n\n'; return; }
  code=$(printf '%s' "$out" | tail -n 1)
  [ "$code" = "200" ] || { printf 'http%s||||\n\n' "$code"; return; }
  body=$(printf '%s' "$out" | sed '$d' | tr -d '\r')
  flat=$(printf '%s' "$body" | tr '\n' ' ')

  # Jina skriver "Final URL:" naar siden er redirectet (produktet er ikke online)
  final=$(printf '%s' "$flat" | sed -n 's/.*Final URL:[[:space:]]*\([^ ]*\).*/\1/p')

  if [ -n "$final" ] && [ "$final" != "$URL" ]; then
    printf 'offline||||\n\n'; return
  fi
  if ! printf '%s' "$flat" | grep -qF "Varenummer: **${PRODUCT_ID}**"; then
    printf 'ukendt||||\n\n'; return
  fi

  note=$(printf '%s' "$flat" | grep -oE 'Bestilt: forventet p[^#]{0,40}' | head -n 1)
  note=$(printf '%s' "$note" | sed 's/^.*lager //; s/[[:space:]]*$//')

  # Varens egen status staar lige foer "Lagerstatus i vores Pick-up Points".
  # Tekster fra kategorisiden eller "tilbehoer"-lister (som ogsaa indeholder
  # "På lager" og priser) ligger uden for dette vindue og ignoreres.
  anchor='Lagerstatus i vores Pick-up Points'
  if printf '%s' "$flat" | grep -qF "$anchor"; then
    region=$(printf '%s' "${flat%%$anchor*}" | tail -c 1200)
  else
    region=""
  fi

  # Pris: den foerste pris foer fragtlinjen ("Billigste fragt ... 39,00 kr.")
  pricetext=${region%%Billigste fragt*}
  price=$(printf '%s' "$pricetext" | grep -oE '[0-9]{1,3}(\.[0-9]{3})*,[0-9]{2} kr\.' | head -n 1)

  ev=$(printf '%s' "$region" | grep -oE '.{0,50}(På lager|Bestilt: forventet p|Udsolgt|Ikke på lager).{0,70}' | head -n 1)

  if [ -z "$region" ]; then
    printf 'online|ukendt|%s|%s\n(ingen statusblok paa siden)\n' "$price" "$note"
  elif printf '%s' "$region" | grep -qF 'Bestilt: forventet p'; then
    printf 'online|PreOrder|%s|%s\n%s\n' "$price" "$note" "$ev"
  elif printf '%s' "$region" | grep -qF 'Ikke på lager'; then
    printf 'online|OutOfStock|%s|%s\n%s\n' "$price" "$note" "$ev"
  elif printf '%s' "$region" | grep -qF 'Udsolgt'; then
    printf 'online|OutOfStock|%s|%s\n%s\n' "$price" "$note" "$ev"
  elif printf '%s' "$region" | grep -qF 'stk. på lager'; then
    printf 'online|InStock|%s|%s\n%s\n' "$price" "$note" "$ev"
  elif printf '%s' "$region" | grep -qF 'På lager'; then
    printf 'online|InStock|%s|%s\n%s\n' "$price" "$note" "$ev"
  else
    printf 'online|ukendt|%s|%s\n%s\n' "$price" "$note" "$ev"
  fi
}

candidate=""
confirmed=""
last_alert=0
last_online_alert=0
fail=0
ONLINE_COOLDOWN=3600

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
  raw=$(fetch_state)
  new=$(printf '%s' "$raw" | head -n 1)
  ev=$(printf '%s' "$raw" | tail -n 1)

  now=$(date +%s)

  oldIFS=$IFS; IFS='|'; set -- $new; IFS=$oldIFS
  kind=${1:-}; avail=${2:-}; price=${3:-}; note=${4:-}

  case "$kind" in
    offline)
      fail=0
      [ "${confirmed%%|*}" != "offline" ] && log "produktsiden er ikke online endnu"
      candidate=""
      confirmed="offline"
      ;;
    online)
      fail=0
      case "$avail" in
        InStock) status="på lager" ;;
        PreOrder) status="kan forudbestilles" ;;
        OutOfStock) status="udsolgt" ;;
        *) status="ikke oplyst" ;;
      esac

      cand="online|${avail}"

      if [ "$candidate" = "$cand" ]; then
        # set to gange i traek -> godkendt
        if [ "$confirmed" != "$cand" ]; then
          if [ "$avail" = "InStock" ]; then
            resp=$(post "$(payload stock "på lager" "$price" "$note")")
            log "PA LAGER - alert sendt (HTTP $resp) [pris=${price:-?}] $ev"
            last_alert=$now
          elif [ $((now - last_online_alert)) -ge $ONLINE_COOLDOWN ]; then
            resp=$(post "$(payload online "$status" "$price" "$note")")
            log "ONLINE ($avail) - alert sendt (HTTP $resp) [pris=${price:-?}] $ev"
            last_online_alert=$now
          else
            log "ONLINE ($avail) igen - alert undertrykt (cooldown)"
          fi
          confirmed="$cand"
        elif [ "$avail" = "InStock" ] && [ $((now - last_alert)) -ge $REMIND_AFTER ]; then
          resp=$(post "$(payload remind "på lager" "$price" "$note")")
          log "stadig pa lager - pamindelse sendt (HTTP $resp) [pris=${price:-?}]"
          last_alert=$now
        fi
      else
        candidate="$cand"
        log "ser $avail - afventer bekræftelse [pris=${price:-?}] $ev"
      fi
      ;;
    *)
      fail=$((fail + 1))
      if [ $((fail % 30)) -eq 1 ]; then
        log "kunne ikke tjekke ($kind)"
      fi
      ;;
  esac

  sleep "$INTERVAL"
done
