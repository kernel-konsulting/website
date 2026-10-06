#!/usr/bin/env bash
#
# Exercises cloudflare-setup.sh --apply end to end without a Cloudflare account.
#
# A stub `curl` stands in for the API and keeps its state on disk, and a stub
# `npx` swallows the wrangler calls, so the whole control flow runs for real:
# the record payloads, the idempotency checks, the secret handling and the
# deploy. Nothing here touches the network.
#
#   ./scripts/test-setup-script.sh

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

BIN="${WORK}/bin"
STATE="${WORK}/state"
mkdir -p "$BIN" "$STATE"
echo '{"zones":[{"id":"zone123"}],"records":[],"widgets":[],"addresses":[]}' > "${STATE}/db.json"
: > "${STATE}/calls.log"

# ------------------------------------------------------------------ stub curl

cat > "${BIN}/curl" <<'STUB'
#!/usr/bin/env python3
"""A tiny stand-in for the Cloudflare API, backed by a JSON file."""
import json, os, sys

state_dir = os.environ["STUB_STATE"]
db_path = os.path.join(state_dir, "db.json")
log_path = os.path.join(state_dir, "calls.log")

args = sys.argv[1:]
method, url, body, out = "GET", "", None, "/dev/stdout"
i = 0
while i < len(args):
    a = args[i]
    if a == "-X":
        method = args[i + 1]; i += 2; continue
    if a == "--data":
        body = args[i + 1]; i += 2; continue
    if a == "-o":
        out = args[i + 1]; i += 2; continue
    if a == "-w":
        i += 2; continue
    if a.startswith("http"):
        url = a
    i += 1

path = url.split("/client/v4", 1)[1].split("?")[0]
db = json.load(open(db_path))
record = {}
with open(log_path, "a") as handle:
    handle.write(json.dumps({"method": method, "path": path, "body": body}) + "\n")

def reply(payload, status=200):
    with open(out, "w") as handle:
        json.dump(payload, handle)
    print(status)

if path == "/zones":
    reply({"success": True, "result": db["zones"]})
elif path == "/accounts":
    reply({"success": True, "result": [{"id": "acct123"}]})
elif path.startswith("/zones/zone123/dns_records") and method == "GET":
    reply({"success": True, "result": db["records"]})
elif path.startswith("/zones/zone123/dns_records") and method == "POST":
    payload = json.loads(body)
    if any(r["type"] == payload["type"] and r["name"] == payload["name"]
           and r["content"] == payload["content"] for r in db["records"]):
        reply({"success": False, "errors": [{"code": 81057, "message": "record already exists"}]})
    else:
        payload["id"] = "rec%d" % (len(db["records"]) + 1)
        db["records"].append(payload)
        json.dump(db, open(db_path, "w"))
        reply({"success": True, "result": payload})
elif path == "/accounts/acct123/challenges/widgets" and method == "GET":
    reply({"success": True, "result": db["widgets"]})
elif path == "/accounts/acct123/challenges/widgets" and method == "POST":
    payload = json.loads(body)
    widget = {"name": payload["name"], "sitekey": "0x4AAAAAAA_test_sitekey",
              "secret": "0x4AAAAAAA_test_secret"}
    db["widgets"].append(widget)
    json.dump(db, open(db_path, "w"))
    reply({"success": True, "result": widget})
elif path.endswith("/rotate_secret"):
    widget = db["widgets"][0]
    widget["secret"] = "0x4AAAAAAA_rotated_secret"
    json.dump(db, open(db_path, "w"))
    reply({"success": True, "result": {"secret": widget["secret"]}})
elif path == "/accounts/acct123/email/routing/addresses" and method == "GET":
    reply({"success": True, "result": db["addresses"]})
elif path == "/accounts/acct123/email/routing/addresses" and method == "POST":
    payload = json.loads(body)
    db["addresses"].append({"email": payload["email"]})
    json.dump(db, open(db_path, "w"))
    reply({"success": True, "result": {"email": payload["email"]}})
else:
    reply({"success": False, "errors": [{"code": 9999, "message": "unstubbed %s %s" % (method, path)}]}, 404)
STUB
chmod +x "${BIN}/curl"

# -------------------------------------------------------------------- stub npx

cat > "${BIN}/npx" <<'STUB'
#!/usr/bin/env bash
# Swallow the wrangler calls. Consume stdin so the writer does not see SIGPIPE,
# and record only that a secret arrived, never its value.
log="${STUB_STATE}/npx.log"
{
  printf 'npx %s\n' "$*"
  if [ "${1:-}" = "--yes" ] && [ "${2:-}" = "wrangler" ] && [ "${3:-}" = "secret" ]; then
    bytes="$(wc -c)"
    printf '  received %s bytes on stdin\n' "${bytes// /}"
  fi
} >> "$log"
exit 0
STUB
chmod +x "${BIN}/npx"

# ------------------------------------------------------------------- run it

export STUB_STATE="$STATE"
export PATH="${BIN}:${PATH}"
export CLOUDFLARE_API_TOKEN="stub-token"
unset CLOUDFLARE_ACCOUNT_ID

# Work on a throwaway copy of index.html so the repository is not modified.
SANDBOX="${WORK}/sandbox"
mkdir -p "${SANDBOX}/workers/contact/scripts"
cp "${HERE}/cloudflare-setup.sh" "${SANDBOX}/workers/contact/scripts/"
printf 'before <div class="cf-turnstile" data-sitekey="1x00000000000000000000AA" data-action="contact"></div> after\n' \
  > "${SANDBOX}/index.html"

pass=0
fail=0
check() {
  if [ "$2" = "$3" ]; then
    printf '  \033[32mok\033[0m    %s\n' "$1"; pass=$((pass + 1))
  else
    printf '  \033[31mFAIL\033[0m  %s\n        expected: %s\n        actual:   %s\n' "$1" "$3" "$2"
    fail=$((fail + 1))
  fi
}
contains() {
  if grep -q -- "$2" "$3"; then
    printf '  \033[32mok\033[0m    %s\n' "$1"; pass=$((pass + 1))
  else
    printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=$((fail + 1))
  fi
}
lacks() {
  if grep -q -- "$2" "$3"; then
    printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=$((fail + 1))
  else
    printf '  \033[32mok\033[0m    %s\n' "$1"; pass=$((pass + 1))
  fi
}
# Assert against the parsed request log, so escaped JSON in the bodies is
# compared as parsed values rather than as text.
pycheck() {
  local label=$1 expr=$2
  if python3 -c '
import json, sys
calls = [json.loads(line) for line in open(sys.argv[1]) if line.strip()]
sys.exit(0 if eval(sys.argv[2]) else 1)
' "$STATE/calls.log" "$expr" 2>/dev/null; then
    printf '  \033[32mok\033[0m    %s\n' "$label"; pass=$((pass + 1))
  else
    printf '  \033[31mFAIL\033[0m  %s\n' "$label"; fail=$((fail + 1))
  fi
}

posts() {  # posts <path-prefix> -> number of POSTs recorded
  python3 -c '
import json, sys
calls = [json.loads(line) for line in open(sys.argv[1]) if line.strip()]
print(len([c for c in calls if c["method"] == "POST" and c["path"].startswith(sys.argv[2])]))
' "$STATE/calls.log" "$1"
}

printf '\n\033[1mFirst run (--apply --email)\033[0m\n'
first="$(cd "${SANDBOX}/workers/contact" && ./scripts/cloudflare-setup.sh --apply --email 2>&1)" || {
  printf '%s\n' "$first"; echo "script exited non-zero"; exit 1
}

check "creates nine DNS records and no more" "$(posts /zones/zone123/dns_records)" "9"
pycheck "creates exactly one widget" \
  "len([c for c in calls if c['method'] == 'POST' and c['path'] == '/accounts/acct123/challenges/widgets']) == 1"
check "registers one destination address" "$(posts /accounts/acct123/email/routing/addresses)" "1"

pycheck "A records point at all four GitHub page addresses" \
  "sorted(b['content'] for c in calls if (b := json.loads(c['body'] or '{}')).get('type') == 'A') == \
   ['185.199.108.153', '185.199.109.153', '185.199.110.153', '185.199.111.153']"
pycheck "AAAA records point at all four GitHub page addresses" \
  "sorted(b['content'] for c in calls if (b := json.loads(c['body'] or '{}')).get('type') == 'AAAA') == \
   ['2606:50c0:8000::153', '2606:50c0:8001::153', '2606:50c0:8002::153', '2606:50c0:8003::153']"
pycheck "the www CNAME points at the org page host, without the repo name" \
  "any((b := json.loads(c['body'] or '{}')).get('type') == 'CNAME' and
       b.get('name') == 'www.kernelkonsulting.com' and
       b.get('content') == 'kernel-konsulting.github.io' for c in calls)"
pycheck "no DNS record is proxied" \
  "not any(json.loads(c['body'] or '{}').get('proxied') for c in calls)"
pycheck "the widget covers the apex, www and the github.io preview" \
  "sorted(json.loads(next(c['body'] for c in calls if c['method'] == 'POST'
                         and c['path'] == '/accounts/acct123/challenges/widgets'))['domains']) == \
   ['kernel-konsulting.github.io', 'kernelkonsulting.com', 'www.kernelkonsulting.com']"
pycheck "the widget is managed mode" \
  "json.loads(next(c['body'] for c in calls if c['method'] == 'POST'
                   and c['path'] == '/accounts/acct123/challenges/widgets'))['mode'] == 'managed'"

check "site key written into index.html" \
  "$(grep -o 'data-sitekey="[^"]*"' "${SANDBOX}/index.html" | head -1)" \
  'data-sitekey="0x4AAAAAAA_test_sitekey"'
contains "index.html keeps its surrounding markup intact" 'before .* after' "${SANDBOX}/index.html"
check "HTML was not rewritten with LF endings" \
  "$(grep -c $'\r' "${SANDBOX}/index.html")" "0"

check "secret pushed to wrangler once" "$(grep -c 'wrangler secret put TURNSTILE_SECRET_KEY' "$STATE/npx.log")" "1"
check "secret arrived on stdin and is non-empty" \
  "$(grep -o 'received [0-9]* bytes' "$STATE/npx.log" | grep -v 'received 0 bytes' | wc -l | tr -d ' ')" "1"
lacks "the secret value is never written to the log" '0x4AAAAAAA_test_secret' "$STATE/npx.log"
contains "wrangler deploy ran" 'wrangler deploy' "$STATE/npx.log"
lacks "the secret is never printed to stdout" '0x4AAAAAAA_test_secret' <(printf '%s' "$first")

printf '\n\033[1mSecond run (idempotency)\033[0m\n'
second="$(cd "${SANDBOX}/workers/contact" && ./scripts/cloudflare-setup.sh --apply --email 2>&1)" || {
  printf '%s\n' "$second"; echo "second run exited non-zero"; exit 1
}
check "still only nine DNS creates" "$(posts /zones/zone123/dns_records)" "9"
pycheck "still only one widget created" \
  "len([c for c in calls if c['method'] == 'POST' and c['path'] == '/accounts/acct123/challenges/widgets']) == 1"
check "still only one address registered" "$(posts /accounts/acct123/email/routing/addresses)" "1"
contains "reports the record already present" 'already present' <(printf '%s' "$second")
contains "reports the widget already exists" 'already exists' <(printf '%s' "$second")
contains "reports the address already present" 'already a destination' <(printf '%s' "$second")
check "rotates rather than recreates the secret" \
  "$(grep -c 'rotate_secret' "$STATE/calls.log" | tr -d ' ')" "1"

printf '\n\033[1mGuard rails\033[0m\n'
out="$(cd "${SANDBOX}/workers/contact" && ./scripts/cloudflare-setup.sh 2>&1)"
contains "dry run prints a plan" 'PLAN (dry run' <(printf '%s' "$out")
lacks   "dry run makes no API calls" 'dns_records' "$STATE/npx.log"

if out="$(cd "${SANDBOX}/workers/contact" && CLOUDFLARE_API_TOKEN= ./scripts/cloudflare-setup.sh --apply 2>&1)"; then
  printf '  \033[31mFAIL\033[0m  refuses to run without a token\n'; fail=$((fail + 1))
else
  contains "refuses to run without a token" 'CLOUDFLARE_API_TOKEN is not set' <(printf '%s' "$out")
fi

# A pre-existing conflicting record must stop the run rather than duplicate it.
python3 - "$STATE/db.json" <<'PY'
import json, sys
db = json.load(open(sys.argv[1]))
db["records"] = [{"type": "A", "name": "kernelkonsulting.com", "content": "203.0.113.9", "id": "old"}]
json.dump(db, open(sys.argv[1], "w"))
PY
if out="$(cd "${SANDBOX}/workers/contact" && ./scripts/cloudflare-setup.sh --apply 2>&1)"; then
  printf '  \033[31mFAIL\033[0m  stops when an A record already points elsewhere\n'; fail=$((fail + 1))
else
  contains "stops when an A record already points elsewhere" 'already points at 203.0.113.9' <(printf '%s' "$out")
fi

printf '\n\033[1m%d passed, %d failed\033[0m\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
