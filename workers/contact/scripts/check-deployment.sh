#!/usr/bin/env bash
#
# Read-only check of everything that has to be true for the site and the
# contact form to work. Changes nothing, needs no credentials.
#
#   ./scripts/check-deployment.sh
#
# Exits non-zero if anything is wrong, so it is usable as a gate.

set -uo pipefail

DOMAIN="kernelkonsulting.com"
WWW_DOMAIN="www.${DOMAIN}"
PAGES_HOST="kernel-konsulting.github.io"
WORKER_HOST="api.${DOMAIN}"
PAGES_IP="185.199.108.153"

PASS=0
FAIL=0
WAIT=0

ok()    { printf '  \033[32mok\033[0m    %s\n' "$*"; PASS=$((PASS + 1)); }
bad()   { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; FAIL=$((FAIL + 1)); }
pending() { printf '  \033[33mwait\033[0m  %s\n' "$*"; WAIT=$((WAIT + 1)); }
head_() { printf '\n\033[1m%s\033[0m\n' "$*"; }

command -v curl >/dev/null || { echo "curl is required" >&2; exit 2; }
HAVE_JQ=1; command -v jq >/dev/null || HAVE_JQ=0

# DNS over HTTPS, so this works without dig and behind anything.
doh() {
  local name=$1 type=$2
  if [ "$HAVE_JQ" -eq 1 ]; then
    curl -sS --max-time 15 "https://dns.google/resolve?name=${name}&type=${type}" \
      | jq -r '[.Answer[]?.data] | join(" ")'
  else
    curl -sS --max-time 15 "https://dns.google/resolve?name=${name}&type=${type}" \
      | python3 -c 'import json,sys; print(" ".join(a.get("data","") for a in json.load(sys.stdin).get("Answer",[])))'
  fi
}

head_ "DNS"
found="$(doh "$DOMAIN" A)"
if [ -z "$found" ]; then
  pending "no A record on ${DOMAIN} yet (Pages cannot resolve without them)"
else
  missing=""
  for ip in 185.199.108.153 185.199.109.153 185.199.110.153 185.199.111.153; do
    case " $found " in *" $ip "*) ;; *) missing="${missing} ${ip}" ;; esac
  done
  if [ -z "$missing" ]; then
    ok "A ${DOMAIN} -> all four GitHub Pages addresses"
  else
    bad "A ${DOMAIN} is missing:${missing} (currently: ${found})"
  fi
fi

found="$(doh "$WWW_DOMAIN" CNAME)"
case "$found" in
  *"${PAGES_HOST}"*) ok "CNAME ${WWW_DOMAIN} -> ${PAGES_HOST}" ;;
  "") [ -z "$found" ] && pending "CNAME ${WWW_DOMAIN} not set yet" || bad "CNAME ${WWW_DOMAIN} unresolved" ;;
  *) bad "CNAME ${WWW_DOMAIN} points at ${found}, expected ${PAGES_HOST}" ;;
esac

head_ "Mail records that must NOT have moved"
mx="$(doh "$DOMAIN" MX)"
case "$mx" in
  *protonmail*) ok "MX still Proton: ${mx}" ;;
  *cloudflare*|*mx.cloudflare.net*) bad "MX has been moved to Cloudflare — Proton mail is broken: ${mx}" ;;
  "") pending "MX lookup returned nothing" ;;
  *) bad "MX looks unexpected: ${mx}" ;;
esac
spf="$(doh "$DOMAIN" TXT)"
case "$spf" in
  *"include:_spf.protonmail.ch"*) ok "apex SPF still authorises Proton" ;;
  *) bad "apex SPF no longer contains include:_spf.protonmail.ch: ${spf}" ;;
esac

head_ "GitHub Pages (asked directly, before DNS settles)"
body="$(curl -sSk --max-time 25 --resolve "${DOMAIN}:443:${PAGES_IP}" "https://${DOMAIN}/" \
        -w '\n__STATUS__%{http_code}')"
status="$(sed -n 's/.*__STATUS__//p' <<<"$body")"
if [ "$status" = "200" ]; then
  ok "HTTP 200 from GitHub Pages for Host: ${DOMAIN}"
  grep -q "data-sitekey" <<<"$body" && ok "Turnstile widget present in the served HTML" \
                                      || bad "Turnstile widget missing from the served HTML"
  if grep -q 'data-sitekey="1x00000000000000000000AA"' <<<"$body"; then
    bad "the served page still carries Cloudflare's always-pass TEST site key"
  else
    ok "the served page does not use the Turnstile test site key"
  fi
  grep -q "api.${DOMAIN}/contact" <<<"$body" && ok "form posts to the Worker" \
                                               || bad "form does not post to https://${WORKER_HOST}/contact"
else
  bad "GitHub Pages returned ${status:-nothing} for Host: ${DOMAIN}"
fi

head_ "Contact Worker"
code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 -X GET "https://${WORKER_HOST}/contact" 2>/dev/null || true)"
case "${code:-000}" in
  405) ok "GET ${WORKER_HOST}/contact -> 405 (the Worker is deployed)" ;;
  000) pending "the Worker does not resolve yet (expected until you deploy)" ;;
  530|502|503) pending "the Worker host resolves but has no Worker behind it yet (${code})" ;;
  *)   bad "unexpected status from ${WORKER_HOST}/contact: ${code}" ;;
esac

head_ "Summary"
printf '  %d ok, %d waiting, %d failed\n' "$PASS" "$WAIT" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
