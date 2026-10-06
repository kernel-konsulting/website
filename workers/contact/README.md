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

Only then does it send. Delivery goes through Cloudflare Email Sending's
`send_email` binding; setting a `RESEND_API_KEY` secret switches delivery to
Resend without touching anything else.

## Setup

Everything below happens once. Nothing is committed that is secret.

### 1. Turnstile

1. Cloudflare dashboard → **Turnstile** → **Add widget**, hostname
   `kernelkonsulting.com` (add `kernel-konsulting.github.io` too while testing).
2. Put the **site key** into `index.html`, on the `.cf-turnstile` div. The site
   key is public.
3. Store the **secret key**:

   ```bash
   cd workers/contact
   npx wrangler secret put TURNSTILE_SECRET_KEY
   ```

Until you do step 3 the Worker runs on Cloudflare's published always-pass test
key, which is set in `wrangler.jsonc` and **must not** be left in place for a
live site.

### 2. A sending domain

Cloudflare dashboard → **Compute → Email Service → Email Sending → Onboard
Domain**, and pick **`send.kernelkonsulting.com`**.

Onboarding a subdomain means every record Cloudflare adds — the `cf-bounce` MX,
the SPF and DKIM TXT records, and the `_dmarc` policy — lands under that
subdomain. **Nothing on the apex changes**, which matters here because the apex
MX points at Proton Mail and its SPF authorises Proton's senders.

> If you onboard the apex instead, Cloudflare also writes
> `_dmarc.kernelkonsulting.com`. You already have one there
> (`v=DMARC1; p=quarantine`), so expect a conflict to resolve. The subdomain
> avoids the question entirely.

Sending to *verified destination addresses* is free on every plan, including the
Workers free plan; that is the only kind of send this Worker does. Sending to
arbitrary recipients would need Workers Paid.

### 3. A verified destination

Cloudflare dashboard → **Email Service → Email Routing → Destination
Addresses**, add `contact@kernelkonsulting.com`. Cloudflare mails a verification
link to that mailbox (it arrives at Proton); click it.

### 4. Ship it

```bash
cd workers/contact
npm install
npm test          # 31 checks, no deployment needed
npm run deploy    # creates api.kernelkonsulting.com + its certificate
```

`wrangler deploy` reads `routes` in `wrangler.jsonc` and creates the custom
domain, so there is no DNS record to add by hand for the endpoint.

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
