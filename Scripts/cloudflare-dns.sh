#!/bin/bash
# Points everyday.<zone> at GitHub Pages and deletes the records listed in CF_DELETE_RECORDS.
# Settings come from .env (copy .env.example). Prints the remaining records at the end.
set -euo pipefail
cd "$(dirname "$0")/.."
[ -f .env ] && set -a && . ./.env && set +a
: "${CF_API_TOKEN:?Add CF_API_TOKEN to .env (see .env.example)}"
ZONE_NAME=${CF_ZONE:?Add CF_ZONE to .env}
API=https://api.cloudflare.com/client/v4
H=(-H "Authorization: Bearer $CF_API_TOKEN" -H "Content-Type: application/json")
ZONE=$(curl -fsS "${H[@]}" "$API/zones?name=$ZONE_NAME" | jq -r '.result[0].id')
[ -n "$ZONE" ] && [ "$ZONE" != null ] || { echo "Zone $ZONE_NAME not found for this token"; exit 1; }

for n in ${CF_DELETE_RECORDS:-}; do
  for id in $(curl -fsS "${H[@]}" "$API/zones/$ZONE/dns_records?name=$n.$ZONE_NAME" | jq -r '.result[].id'); do
    curl -fsS -X DELETE "${H[@]}" "$API/zones/$ZONE/dns_records/$id" >/dev/null && echo "deleted $n.$ZONE_NAME"
  done
done

if [ "$(curl -fsS "${H[@]}" "$API/zones/$ZONE/dns_records?name=everyday.$ZONE_NAME" | jq '.result | length')" = 0 ]; then
  curl -fsS -X POST "${H[@]}" "$API/zones/$ZONE/dns_records" \
    -d '{"type":"CNAME","name":"everyday","content":"mandrusian.github.io","proxied":false,"ttl":1}' >/dev/null && echo "added everyday.$ZONE_NAME -> mandrusian.github.io"
else
  echo "everyday.$ZONE_NAME already has a record; left as is"
fi
echo; echo "Remaining records:"
curl -fsS "${H[@]}" "$API/zones/$ZONE/dns_records?per_page=100" | jq -r '.result[] | "\(.type)\t\(.name)\t\(.content)"'
