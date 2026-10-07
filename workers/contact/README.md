# kk-contact

The contact-form endpoint for kernelkonsulting.com.

GitHub Pages serves the site statically and cannot run PHP, so this Worker
replaces the old `contact.php` + `includes/smtp.php`. It is deployed at
`https://api.kernelkonsulting.com/contact` and is the only dynamic part of the
site.

## What it does

Layers, cheapest first, same order as the PHP version it replaces:

1. `POST` only, plus an `Origin` check against the site's own hosts
2. Request size cap (16 KB) before the body is parsed
3. Honeypot field (`website`) — hidden from people, filled in by bots
4. Dwell-time check (`js` / `ts`) — a bot that posts instantly on page load
5. Per-IP rate limit (Workers Rate Limiting binding — no storage to run)
6. Field validation, length caps and a link-count heuristic
7. **Cloudflare Turnstile**, verified server-side against `siteverify`

Only then does it send. Delivery goes through **Resend** (set a `RESEND_API_KEY`
secret). The Worker also carries a Cloudflare Email Sending `send_email`
binding and falls back to it when no Resend key is present — see "Why Resend"
below for why the Cloudflare path is not the one in use.

## Setup

Everything below happens once. Nothing secret is ever committed or printed.

### The fast path

The whole Cloudflare side is scripted. It is a dry run until you pass `--apply`,
and every step is idempotent, so re-running it is safe.

```bash
cd workers/contact
./scripts/cloudflare-setup.sh              # print the plan, change nothing
export CLOUDFLARE_API_TOKEN=...            # never commit this
./scripts/cloudflare-setup.sh --apply --email
```

That does the nine DNS records, creates the Turnstile widget, writes the site
key into `index.html`, stores the secret, and deploys the Worker. It never
touches Email Routing on the apex, so Proton's MX, SPF and DMARC are untouched.

The token needs **Zone > DNS > Edit**, **Account > Turnstile Sites > Edit**,
**Account > Workers Scripts > Edit**, **Zone > Zone > Read**, and for `--email`
also **Account > Email Routing > Edit**.

`./scripts/test-setup-script.sh` runs the whole apply path against a stub API —
28 checks covering the record payloads, the idempotency, and that the secret
never reaches stdout or the log. Use it if you change the script.

Afterwards: `./scripts/check-deployment.sh` verifies the live result — DNS, that
the mail records have *not* moved, what Pages is actually serving, and whether
the Worker answers. It needs no credentials.

### By hand, if you prefer

1. **Turnstile.** Cloudflare dashboard → **Turnstile** → **Add widget**,
   hostname `kernelkonsulting.com` (add `kernel-konsulting.github.io` too while
   testing). Put the **site key** into `index.html` on the `.cf-turnstile` div —
   it is public. Store the **secret key**:

   ```bash
   npx wrangler secret put TURNSTILE_SECRET_KEY
   ```

   Until you set a real secret the Worker **fails closed**: it logs and returns
   a 503 telling the visitor to use the mail address. It never silently accepts
   submissions without a CAPTCHA.

2. **A sending domain.** Sign up at resend.com, then **Domains → Add Domain** →
   `send.kernelkonsulting.com`, add the DNS records it shows (all TXT, all on
   the `send.` subdomain — nothing on the apex), and click **Verify**. Then
   **API Keys → Create** and store the key:

   ```bash
   npx wrangler secret put RESEND_API_KEY
   ```

   The key may be created with **sending access only**; that is enough, and it
   is the tighter option. A sending-only key cannot list domains, so to confirm
   the domain verified, just send something.

3. **Deploy.** `npm run deploy` — `wrangler` reads `routes` in `wrangler.jsonc`
   and creates `api.kernelkonsulting.com` and its certificate itself.

### Why Resend, not Cloudflare Email Sending

Cloudflare's own delivery path is gated. **Email Sending** — the product that
lets you onboard a sending domain — requires **Workers Paid**. On the free plan
the `send_email` binding can only send to verified destination addresses, and
*only from a routing domain*, meaning a domain with **Email Routing** enabled.
Email Routing on the apex wants to take over the apex MX, which on this domain
belongs to Proton Mail, and the Subdomains option only appears once the apex is
onboarded. So the free Cloudflare path would mean migrating the domain's mail
into Cloudflare to serve one contact form.

Resend's free tier (3,000/month, 100/day) does the same job with TXT records on
a subdomain and no change to the apex at all. The `deliver()` function in
`src/index.js` keeps both paths, so switching to Cloudflare later — if the plan
changes — is a one-line edit plus unsetting the secret.

## Verifying it end-to-end

The failure modes worth checking, with the real secret in place:

```bash
# a good submission — expect {"ok":true,...}
curl -sS -X POST https://api.kernelkonsulting.com/contact \
  -H 'Origin: https://kernelkonsulting.com' \
  -H 'Accept: application/json' \
  --data-urlencode 'name=Test Person' \
  --data-urlencode 'email=test@example.com' \
  --data-urlencode 'message=A real message long enough to pass validation.' \
  --data-urlencode 'js=1' \
  --data-urlencode "ts=$(( $(date +%s) - 5 ))" \
  --data-urlencode "cf-turnstile-response=$(...)"

# no token — expect 403 and nothing in the inbox
# wrong Origin — expect 403
# honeypot filled — expect 200 but nothing in the inbox
```

The honeypot, the rate limit and the dwell-time check are all covered by
`npm test`, including a live round-trip to `siteverify` using Cloudflare's
dummy keys.

## Deploying from CI

`.github/workflows/deploy-worker.yml` deploys on any push to `main` that
touches `workers/contact/**`. It needs two repository secrets:

- `CLOUDFLARE_API_TOKEN` — token with **Workers Scripts: Edit** and
  **Zone: DNS: Edit** (the second one only so Wrangler can create the custom
  domain on the first deploy)
- `CLOUDFLARE_ACCOUNT_ID`

Until those exist, deploy by hand with `npm run deploy`.

## Known trade-offs

- **Rate-limit window.** The Workers Rate Limiting binding only supports 10 or
  60 second windows, so this is a burst guard (5 per minute per IP), not the
  4-per-hour window the PHP version had. Turnstile is what carries the load;
  a longer window would need a KV namespace or a Durable Object.
- **Turnstile action is enforced.** The widget sets `data-action="contact"` and
  the Worker rejects a token whose action does not match. If you ever change one
  side, change both.
- **`.htaccess` does nothing here.** GitHub Pages ignores it, so the security
  headers that used to be set on the server are not being sent. See the note in
  the repository README.
