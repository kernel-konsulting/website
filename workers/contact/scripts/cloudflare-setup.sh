#!/usr/bin/env bash
#
# Provision everything the contact Worker needs on Cloudflare.
#
# Dry-run by default: it prints the plan and changes nothing. Add --apply to
# actually do it. Every step is idempotent, so re-running is safe.
#
#   ./scripts/cloudflare-setup.sh                 # show the plan
#   ./scripts/cloudflare-setup.sh --apply         # do it
#   ./scripts/cloudflare-setup.sh --apply --email # also add the mail destination
#
# Requires: curl, python3, and either npx or a global wrangler.
#
# CLOUDFLARE_API_TOKEN must have, at minimum:
#   Zone    > DNS                > Edit   (the Pages records)
#   Account > Turnstile Sites    > Edit   (the widget)
#   Account > Workers Scripts    > Edit   (the deploy)
#   Zone    > Zone               > Read   (to resolve the zone id)
# Account > Email Routing > Edit is needed only for --email.
#
# Nothing here touches Email Routing on the apex domain, so the existing MX,
# SPF and DMARC records that Proton depends on are never modified.

set -euo pipefail

DOMAIN="kernelkonsulting.com"
WWW_DOMAIN="www.${DOMAIN}"
PAGES_HOST="kernel-konsulting.github.io"
SENDING_SUBDOMAIN="send.${DOMAIN}"
DESTINATION="contact@${DOMAIN}"
WIDGET_NAME="${DOMAIN} contact form"

WORKER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INDEX_HTML="$(cd "${WORKER_DIR}/../.." && pwd)/index.html"

PAGES_IPV4=(185.199.108.153 185.199.109.153 185.199.110.153 185.199.111.153)
PAGES_IPV6=(2606:50c0:8000::153 2606:50c0:8001::153 2606:50c0:8002::153 2606:50c0:8003::153)

APPLY=0
WANT_EMAIL=0
for arg in "$@"; do
  case "$arg" in
    --apply) APPLY=1 ;;
    --email) WANT_EMAIL=1 ;;
    -h|--help) sed -n '2,24p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

API="https://api.cloudflare.com/client/v4"

say()  { printf '\n\033[1m%s\033[0m\n' "$*"; }
step() { printf '  %s\n' "$*"; }
ok()   { printf '  \033[32mok\033[0m   %s\n' "$*"; }
skip() { printf '  \033[2mskip %s\033[0m\n' "$*"; }
note() { printf '  \033[33mnote\033[0m %s\n' "$*"; }
die()  { printf '\n  \033[31m%s\033[0m\n' "$*" >&2; exit 1; }

# ------------------------------------------------------------------ dry run

if [ "$APPLY" -eq 0 ]; then
  say "PLAN (dry run — nothing will be changed)"
  echo
  echo "DNS records on ${DOMAIN}, all DNS-only (proxy off):"
  for ip in "${PAGES_IPV4[@]}"; do step "A      @                    -> ${ip}"; done
  for ip in "${PAGES_IPV6[@]}"; do step "AAAA   @                    -> ${ip}"; done
  step "CNAME  ${WWW_DOMAIN} -> ${PAGES_HOST}"
  echo
  echo "Turnstile:"
  step "reuse the widget named \"${WIDGET_NAME}\", or create it (mode=managed)"
  step "write its site key into index.html"
  step "store its secret as the Worker secret TURNSTILE_SECRET_KEY"
  echo
  echo "Worker:"
  step "npx wrangler deploy    (creates api.${DOMAIN} and its certificate)"
  if [ "$WANT_EMAIL" -eq 1 ]; then
    echo
    echo "Email (only with --email):"
    step "add ${DESTINATION} as an Email Routing destination address"
    step "you must click the verification link that arrives at that mailbox"
  else
    echo
    echo "Email: not included. Add --email to also register ${DESTINATION}"
    echo "as a destination address."
  fi
  echo
  echo "Email Routing is never enabled on ${DOMAIN} itself, so the apex MX, SPF"
  echo "and DMARC records that Proton depends on are not touched."
  echo
  echo "Re-run with --apply to execute this."
  exit 0
fi

# ------------------------------------------------------------------- checks

for bin in curl python3; do
  command -v "$bin" >/dev/null || die "missing required command: ${bin}"
done
[ -n "${CLOUDFLARE_API_TOKEN:-}" ] || die "CLOUDFLARE_API_TOKEN is not set"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
RESP="${TMP}/response.json"

# Read a dotted path out of the last response; numeric segments index lists.
jget() {
  python3 -c '
import json, sys
try:
    data = json.load(open(sys.argv[1]))
except Exception:
    print(""); sys.exit(0)
try:
    for part in sys.argv[2].split("."):
        data = data[int(part)] if part.lstrip("-").isdigit() else data[part]
except Exception:
    print(""); sys.exit(0)
if data is None:
    print("")
elif isinstance(data, bool):
    print("true" if data else "false")
else:
    print(data)
' "$RESP" "$1" 2>/dev/null || true
}

# First entry of .result whose <key> equals <value>, printing <field>.
jfind() {
  python3 -c '
import json, sys
try:
    data = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
key, value, field = sys.argv[2], sys.argv[3], sys.argv[4]
for item in (data.get("result") or []):
    if str(item.get(key)) == value:
        print(item.get(field) or "")
        break
' "$RESP" "$1" "$2" "$3" 2>/dev/null || true
}

jerrors() {
  python3 -c '
import json, sys
try:
    data = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
for item in (data.get("errors") or []):
    print("  error {}: {}".format(item.get("code"), item.get("message")))
' "$RESP" 2>/dev/null || true
}

cf() {
  local method=$1 path=$2 data=${3:-}
  local args=(-sS -o "$RESP" -w '%{http_code}' -X "$method" "${API}${path}"
              -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}"
              -H 'Content-Type: application/json')
  [ -n "$data" ] && args+=(--data "$data")
  curl "${args[@]}"
}

cf_ok() {
  local code
  code="$(cf "$@")" || die "curl failed for ${1} ${2}"
  if [ "$code" != "200" ] || [ "$(jget success)" != "true" ]; then
    jerrors >&2
    die "Cloudflare rejected ${1} ${2} (HTTP ${code})"
  fi
}

say "Resolving zone and account"
cf_ok GET "/zones?name=${DOMAIN}"
ZONE_ID="$(jget 'result.0.id')"
[ -n "$ZONE_ID" ] || die "no zone for ${DOMAIN} is visible to this token"
ok "zone ${DOMAIN} -> ${ZONE_ID}"

if [ -n "${CLOUDFLARE_ACCOUNT_ID:-}" ]; then
  ACCOUNT_ID="${CLOUDFLARE_ACCOUNT_ID}"
  ok "account -> ${ACCOUNT_ID} (from CLOUDFLARE_ACCOUNT_ID)"
else
  cf_ok GET "/accounts"
  ACCOUNT_ID="$(jget 'result.0.id')"
  ok "account -> ${ACCOUNT_ID}"
fi
[ -n "$ACCOUNT_ID" ] || die "could not determine the account id; export CLOUDFLARE_ACCOUNT_ID"

# ---------------------------------------------------------------------- DNS

say "DNS records (DNS-only)"
cf_ok GET "/zones/${ZONE_ID}/dns_records?per_page=200"

create_record() {
  local type=$1 name=$2 content=$3

  local same
  same="$(python3 -c '
import json, sys
t, n, c = sys.argv[2], sys.argv[3], sys.argv[4]
data = json.load(open(sys.argv[1]))
for item in (data.get("result") or []):
    if item.get("type") == t and item.get("name") == n and item.get("content") == c:
        print(item.get("id") or ""); break
' "$RESP" "$type" "$name" "$content" 2>/dev/null || true)"
  if [ -n "$same" ]; then
    skip "${type} ${name} -> ${content} (already present)"
    return
  fi

  local clash
  clash="$(python3 -c '
import json, sys
t, n = sys.argv[2], sys.argv[3]
data = json.load(open(sys.argv[1]))
for item in (data.get("result") or []):
    if item.get("type") == t and item.get("name") == n:
        print(item.get("content") or ""); break
' "$RESP" "$type" "$name" 2>/dev/null || true)"
  [ -n "$clash" ] && die "${type} ${name} already points at ${clash}; resolve that by hand first"

  cf_ok POST "/zones/${ZONE_ID}/dns_records" \
    "$(python3 -c '
import json, sys
print(json.dumps({"type": sys.argv[1], "name": sys.argv[2], "content": sys.argv[3],
                  "ttl": 1, "proxied": False}))
' "$type" "$name" "$content")" >/dev/null
  ok "created ${type} ${name} -> ${content}"
}

for ip in "${PAGES_IPV4[@]}"; do create_record A "$DOMAIN" "$ip"; done
for ip in "${PAGES_IPV6[@]}"; do create_record AAAA "$DOMAIN" "$ip"; done
create_record CNAME "$WWW_DOMAIN" "$PAGES_HOST"

# ---------------------------------------------------------------- turnstile

say "Turnstile widget"
cf_ok GET "/accounts/${ACCOUNT_ID}/challenges/widgets"
SITEKEY="$(jfind name "$WIDGET_NAME" sitekey)"

if [ -n "$SITEKEY" ]; then
  skip "widget \"${WIDGET_NAME}\" already exists -> ${SITEKEY}"
  # The API never replays an existing secret, so it has to be rotated to be read.
  cf_ok POST "/accounts/${ACCOUNT_ID}/challenges/widgets/${SITEKEY}/rotate_secret" \
    '{"invalidate_immediately":false}'
  TURNSTILE_SECRET="$(jget 'result.secret')"
  [ -n "$TURNSTILE_SECRET" ] || die "could not rotate the widget secret"
  note "rotated the widget secret; the previous one stays valid for 2 hours"
else
  cf_ok POST "/accounts/${ACCOUNT_ID}/challenges/widgets" \
    "$(python3 -c '
import json, sys
print(json.dumps({"name": sys.argv[1],
                  "domains": [sys.argv[2], sys.argv[3], sys.argv[4]],
                  "mode": "managed"}))
' "$WIDGET_NAME" "$DOMAIN" "$WWW_DOMAIN" "$PAGES_HOST")"
  SITEKEY="$(jget 'result.sitekey')"
  TURNSTILE_SECRET="$(jget 'result.secret')"
  [ -n "$SITEKEY" ] && [ -n "$TURNSTILE_SECRET" ] || die "widget creation returned no keys"
  ok "created widget \"${WIDGET_NAME}\" -> ${SITEKEY}"
fi

say "Publishing the site key into index.html"
python3 - "$INDEX_HTML" "$SITEKEY" <<'PY'
import re, sys

path, sitekey = sys.argv[1], sys.argv[2]
with open(path, newline='', encoding='utf-8') as handle:
    source = handle.read()

updated, count = re.subn(r'data-sitekey="[^"]*"', f'data-sitekey="{sitekey}"', source)
if count != 1:
    sys.exit(f'  error: expected exactly one data-sitekey in {path}, found {count}')

with open(path, 'w', newline='', encoding='utf-8') as handle:
    handle.write(updated)
print(f'  ok   index.html site key set to {sitekey}')
PY
step "commit that change — the site key is public"

# --------------------------------------------------------------------- email

if [ "$WANT_EMAIL" -eq 1 ]; then
  say "Email Routing destination address"
  cf_ok GET "/accounts/${ACCOUNT_ID}/email/routing/addresses"
  if [ -n "$(jfind email "$DESTINATION" email)" ]; then
    skip "${DESTINATION} is already a destination address"
  else
    cf_ok POST "/accounts/${ACCOUNT_ID}/email/routing/addresses" \
      "$(python3 -c 'import json,sys; print(json.dumps({"email": sys.argv[1]}))' "$DESTINATION")"
    ok "added ${DESTINATION}"
  fi
  echo
  note "Cloudflare has mailed a verification link to ${DESTINATION}"
  step "it arrives at Proton; nothing can be sent there until you click it"
fi

# -------------------------------------------------------------------- worker

say "Worker secret"
printf '%s' "$TURNSTILE_SECRET" | (cd "$WORKER_DIR" && npx --yes wrangler secret put TURNSTILE_SECRET_KEY) >/dev/null
ok "TURNSTILE_SECRET_KEY stored (the value was never printed)"
note "now delete the test TURNSTILE_SECRET_KEY from wrangler.jsonc"

say "Deploying the Worker"
(cd "$WORKER_DIR" && npx --yes wrangler deploy)
ok "deployed"

say "Left for you"
cat <<EOF

  1. Onboard ${SENDING_SUBDOMAIN} for Email Sending (Compute > Email Service >
     Email Sending > Onboard Domain). There is no stable public API for this
     step yet. Choose the subdomain, not the apex.
  2. Confirm MAIL_FROM in wrangler.jsonc matches it, then re-run:
         cd ${WORKER_DIR} && npx wrangler deploy
  3. Add CLOUDFLARE_API_TOKEN and CLOUDFLARE_ACCOUNT_ID as GitHub repository
     secrets so .github/workflows/deploy-worker.yml can deploy from CI.
  4. Once GitHub has issued the certificate: Settings > Pages > Enforce HTTPS.
  5. Verify the whole thing:  ./scripts/check-deployment.sh
EOF
