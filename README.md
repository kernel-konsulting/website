# kernelkonsulting.com

Marketing site for Kernel Konsulting LLC. Static HTML, CSS and vanilla JS with a
single PHP endpoint for the contact form. No build step: what is in this
repository is what gets uploaded.

> Rewrite of the original HTML5 UP "Directive" one-pager. The old template, its
> jQuery bundle and the unoptimised source images are gone; the wording of the
> four service pillars and the company claims are carried over (lightly edited),
> nothing new was invented.

## What is in here

```
index.html                     the whole site, one page
404.html                       error page
robots.txt  sitemap.xml        crawler files
.htaccess                      HTTPS + canonical host, security headers, caching
assets/css/site.css            all styling (plain CSS, custom properties)
assets/js/site.js              nav toggle, year, contact-form enhancement
assets/img/                     optimised photos, logo (SVG + PNG), social card
assets/favicons/               icon set + web app manifest
contact.php                    contact form endpoint
includes/smtp.php              small SMTP client (no Composer dependency)
contact-config.example.php     template for the git-ignored config
```

## Deploying

Upload the repository contents to the web root. The only server requirement is
PHP 8.1+ with the `openssl` and `curl` extensions — no Composer, no Node, no
build.

Then:

1. `cp contact-config.example.php contact-config.php`
2. Fill in the SMTP host, username, password and the `to_address`
3. Delete the old `phpmailer/` directory from the web root if it is there

`contact-config.php` is git-ignored and blocked by `.htaccess`. It must never be
committed — the previous revision of this repository shipped an SMTP password in
`sendmail.php` (as an empty string, so the form could not have worked).

## Contact form

Delivery goes out through an authenticated SMTP relay, so no local mail transfer
agent is needed and nothing is paid for beyond the existing hosting. The domain's
MX already points at Proton Mail, so a Proton SMTP token is the natural choice;
a Gmail account with an App Password also works.

Spam protection is layered, and every layer is free and self-hosted:

- POST-only, plus a `Referer` check against the configured hosts
- A honeypot field (`website`) that only bots fill in
- A dwell-time check: submissions that arrive less than two seconds after page load are refused
- A per-IP rate limit (4 per hour, file-backed)
- Field validation, length caps and a link-count heuristic
- Optional Cloudflare Turnstile — add `turnstile_secret` to the config to enable

If spam still gets through, Cloudflare Turnstile is the next step and costs
nothing; Sum, Cloudflare's own bot management, is another option since this
domain already resolves through Cloudflare.

## Notes and follow-ups

- **Dead social links.** `https://x.com/kernelkonsulting` and
  `https://www.linkedin.com/kernelkonsulting` both return 404 (checked
  2026-10-01). Facebook and GitHub are live. The dead entries are commented out
  in `index.html` with a `TODO` — restore them once the handles exist. The old
  LinkedIn URL was also missing its `/company/` or `/in/` segment.
- **`test.php` removed.** It called `phpinfo()` and was publicly reachable; that
  is an information disclosure bug, not a test.
- **Analytics** is the original GA4 property `G-JCZYRKV01Z`, unchanged. The
  CSP in `.htaccess` already allows it. If the site ever needs to work without
  third-party requests, delete the two script blocks at the bottom of
  `index.html`.
- **Copy** is the original wording tightened up. Add real client names,
  testimonials or case studies only when they are real.
- **Photography** is the original stock set from Pexels (CC0), re-cropped to 3:2
  and re-encoded. The three dark shots got a gentle exposure lift so they read at
  display size. Replacing them with real team or client imagery would say more
  than stock photography does.
- **No legal pages exist.** The form's privacy line is a plain statement of what
  the code actually does with the data. If you want a privacy policy or terms
  page, that content has to come from you — do not ship invented legal text.
- **Unsubscribe/abuse:** the rate limiter stores one small file per IP under the
  system temp directory. Nothing else about a submission is persisted.
