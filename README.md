# kernelkonsulting.com

Marketing site for Kernel Konsulting LLC. Static HTML, CSS and vanilla JS served
by **GitHub Pages**, with one Cloudflare Worker for the contact form. No build
step: what is in this repository is what gets published.

> Rewrite of the original HTML5 UP "Directive" one-pager. The old template, its
> jQuery bundle and the unoptimised source images are gone; the wording of the
> four service pillars and the company claims are carried over (lightly edited),
> nothing new was invented.

## What is in here

```
index.html                     the whole site, one page
404.html                       error page (GitHub Pages serves it automatically)
robots.txt  sitemap.xml        crawler files
CNAME                          the custom domain GitHub Pages answers on
assets/css/site.css            all styling (plain CSS, custom properties)
assets/js/site.js              nav toggle, year, contact-form enhancement
assets/img/                    optimised photos, logo (SVG + PNG), social card
assets/favicons/               icon set + web app manifest
workers/contact/               contact-form endpoint (Cloudflare Worker)

legacy, superseded by the Worker — see "Removing the old endpoint" below
contact.php                    the PHP endpoint the cluster still serves
includes/smtp.php              small SMTP client (no Composer dependency)
contact-config.example.php     template for the git-ignored config
.htaccess                      Apache config; ignored by GitHub Pages
```

## Deploying

Push to `main`. GitHub Pages publishes the repository root, so a push is a
deploy — no action, no runner, nothing to install.

One-time setup, in the repository settings:

- **Settings → Pages**: source `Deploy from a branch`, branch `main`, folder `/`.
  Leave **Enforce HTTPS** on once the certificate has been issued.
- **Settings → Pages → Custom domain**: `kernelkonsulting.com`. The `CNAME` file
  in the repository already says so.

The domain's DNS lives at Cloudflare and this is the part that has to match
GitHub's expectations exactly — see "DNS" below.

## DNS

`kernelkonsulting.com` is on Cloudflare, so these records go in the Cloudflare
dashboard. Nothing else on the zone changes: Proton keeps the `MX`, the SPF
`TXT` and its `protonmail-verification` record, and they are not touched.

| Type | Name | Value | Proxy |
|---|---|---|---|
| A | `@` | `185.199.108.153` | DNS only |
| A | `@` | `185.199.109.153` | DNS only |
| A | `@` | `185.199.110.153` | DNS only |
| A | `@` | `185.199.111.153` | DNS only |
| AAAA | `@` | `2606:50c0:8000::153` | DNS only |
| AAAA | `@` | `2606:50c0:8001::153` | DNS only |
| AAAA | `@` | `2606:50c0:8002::153` | DNS only |
| AAAA | `@` | `2606:50c0:8003::153` | DNS only |
| CNAME | `www` | `kernel-konsulting.github.io` | DNS only |

**Set the proxy to DNS only (grey cloud) for all of them.** GitHub has to be able
to see these records to verify the domain and to issue the certificate; a
proxied record hides the target and breaks both. Once the site is up and the
certificate is issued you can revisit that, but there is no benefit here — the
site is already static and free to serve.

`www` redirects to the apex automatically once both are configured in GitHub.

## Contact form

The form posts to a Cloudflare Worker at
`https://api.kernelkonsulting.com/contact`, which is deployed from
`workers/contact/`. GitHub Pages cannot run PHP, which is the whole reason the
Worker exists.

`workers/contact/README.md` has the full setup. The short version:

```bash
cd workers/contact
./scripts/cloudflare-setup.sh                    # dry run: prints the plan
export CLOUDFLARE_API_TOKEN=...                  # never commit this
./scripts/cloudflare-setup.sh --apply --email    # does the whole Cloudflare side
./scripts/check-deployment.sh                    # read-only verification
```

The setup script creates the nine DNS records, the Turnstile widget, the site
key in `index.html`, the Worker secret and the deploy. It never enables Email
Routing on the apex, so the MX, SPF and DMARC records Proton depends on are not
modified.

One step is still manual: the mail provider. Delivery goes through **Resend**
(free tier), and a Cloudflare Workers free plan cannot do it natively — Email
Sending needs Workers Paid, and the free alternative would mean handing
Cloudflare the apex MX that Proton owns. `workers/contact/README.md` explains
the whole trade-off.

Spam protection is layered and every layer is free:

- `POST` only, plus an `Origin` check against the site's own hosts
- Honeypot field (`website`) that only bots fill in
- Dwell-time check: submissions less than two seconds after page load are refused
- Per-IP rate limit (5 per minute; the platform's smallest window is 60s)
- Field validation, length caps and a link-count heuristic
- Cloudflare Turnstile, verified server-side — always enforced

## Removing the old endpoint

`contact.php`, `includes/smtp.php`, `contact-config.example.php` and
`.htaccess` are what the old cluster deployment (`kk-site` namespace) serves, and
they are dead once the Worker is in place. They are kept here only until the
Worker has been verified against the live domain. After that, delete them and
the `kk-site` namespace.

They contain no secrets — `contact-config.php`, which does, has always been
git-ignored — so nothing leaks by leaving them for now, but they are served as
plain files by Pages, which is not useful.

## Notes and follow-ups

- **Security headers are gone.** `.htaccess` set CSP, `X-Frame-Options`,
  `Referrer-Policy` and `Permissions-Policy`, and GitHub Pages ignores
  `.htaccess` entirely. Adding them back means either proxying the domain
  through Cloudflare and using a Transform Rule, or moving the CSP into a
  `<meta http-equiv>` tag in `index.html` — which needs checking against the GA4
  and Turnstile scripts first, because a wrong directive silently breaks both.
- **Dead social links.** `https://x.com/kernelkonsulting` and
  `https://www.linkedin.com/kernelkonsulting` both return 404 (checked
  2026-10-01). Facebook and GitHub are live. The dead entries are commented out
  in `index.html` with a `TODO` — restore them once the handles exist. The old
  LinkedIn URL was also missing its `/company/` or `/in/` segment.
- **Analytics** is the original GA4 property `G-JCZYRKV01Z`, unchanged. If the
  site ever needs to work without third-party requests, delete the two script
  blocks at the bottom of `index.html`.
- **Copy** is the original wording tightened up. Add real client names,
  testimonials or case studies only when they are real.
- **Photography** is the original stock set from Pexels (CC0), re-cropped to 3:2
  and re-encoded. The three dark shots got a gentle exposure lift so they read at
  display size. Replacing them with real team or client imagery would say more
  than stock photography does.
- **No legal pages exist.** The form's privacy line is a plain statement of what
  the code actually does with the data. If you want a privacy policy or terms
  page, that content has to come from you — do not ship invented legal text.
- **Abuse:** the rate limiter keeps a counter in Cloudflare's own infrastructure
  and stores nothing. The Worker logs the honeypot hits and the Turnstile
  rejections; nothing else about a submission is persisted.
