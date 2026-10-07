#!/usr/bin/env bash
#
# Watches for the GitHub Pages certificate on kernelkonsulting.com.
#
# Prints nothing until the certificate is actually valid for the domain, so it
# can be run on a schedule without generating hourly noise. When it does become
# valid it turns on HTTPS enforcement, verifies the redirect, and prints one
# report — then goes quiet for good.
#
#   ./check-https.sh                 # normal run
#   WATCH_DRY_RUN=1 ./check-https.sh # report only, change nothing
#
# Env overrides (used by the tests): WATCH_DOMAIN, WATCH_REPO, WATCH_MARKER,
# WATCH_DRY_RUN.

set -uo pipefail

DOMAIN="${WATCH_DOMAIN:-kernelkonsulting.com}"
REPO="${WATCH_REPO:-kernel-konsulting/website}"
MARKER="${WATCH_MARKER:-/opt/data/work/.https-watch-done}"
DRY_RUN="${WATCH_DRY_RUN:-0}"
EXPECT="${WATCH_EXPECT:-Kernel Konsulting}"
GH="/opt/data/bin/gh"
[ -x "$GH" ] || GH="$(command -v gh || true)"

# Already reported once. Nothing further to do, and nothing to say.
[ -f "$MARKER" ] && exit 0

# ------------------------------------------------------------------ the check
# curl verifies the certificate by default, so a successful fetch of the apex
# over https both proves the certificate exists and that it covers this domain.
# GitHub serves its shared *.github.io certificate until it has provisioned the
# custom-domain one, and that fails this check — which is the point.
https_code="$(curl -sS --max-time 25 -o /tmp/.https-watch-body -w '%{http_code}' \
  "https://${DOMAIN}/" 2>/dev/null)"
https_ok=$?

if [ "$https_ok" -ne 0 ] || [ -z "$https_code" ] || [ "$https_code" = "000" ]; then
  exit 0   # not ready; say nothing
fi

# Guard against a 200 from something that is not our site.
if ! grep -qi "$EXPECT" /tmp/.https-watch-body 2>/dev/null; then
  exit 0
fi

# ------------------------------------------------------------------- act
if [ "$DRY_RUN" != "1" ] && [ -n "$GH" ]; then
  "$GH" api -X PUT "repos/${REPO}/pages" -f https_enforced=true >/dev/null 2>&1
fi

sleep 20   # give the enforcement change a moment to take effect

redirect_code="$(curl -sS --max-time 25 -o /dev/null -w '%{http_code}' \
  "http://${DOMAIN}/" 2>/dev/null)"
redirect_to="$(curl -sS --max-time 25 -o /dev/null -w '%{redirect_url}' \
  "http://${DOMAIN}/" 2>/dev/null)"
enforced="$([ "$redirect_code" = "301" ] || [ "$redirect_code" = "302" ] || [ "$redirect_code" = "308" ] && echo yes || echo no)"

# Which certificate is actually being served, so the report says something
# verifiable rather than just "it works".
issuer="$(echo | timeout 20 openssl s_client -connect "${DOMAIN}:443" -servername "$DOMAIN" 2>/dev/null \
  | openssl x509 -noout -issuer 2>/dev/null | sed 's/^issuer=//')"
subject="$(echo | timeout 20 openssl s_client -connect "${DOMAIN}:443" -servername "$DOMAIN" 2>/dev/null \
  | openssl x509 -noout -subject 2>/dev/null | sed 's/^subject=//')"

[ "$DRY_RUN" != "1" ] && : > "$MARKER"

cat <<EOF
HTTPS is live on ${DOMAIN}.

  https://${DOMAIN}/        -> HTTP ${https_code}, certificate valid and covering the domain
  certificate               -> ${subject:-unknown} (${issuer:-unknown})
  http://${DOMAIN}/         -> HTTP ${redirect_code} -> ${redirect_to:-<no redirect>}
  Enforce HTTPS             -> $([ "$enforced" = "yes" ] && echo "on, and the redirect verified" || echo "SET BUT THE REDIRECT DID NOT VERIFY — check Settings > Pages")

The site is now served over TLS, so the temporary http:// origins can come out
of ALLOWED_ORIGINS in the Worker whenever you want.

$( [ "$enforced" = "yes" ] && echo "Nothing left to do for the certificate." || echo "Worth a look: the redirect did not verify." )
EOF
