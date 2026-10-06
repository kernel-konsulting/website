/**
 * Contact form endpoint for kernelkonsulting.com
 * ---------------------------------------------------------------------------
 * The site is served by GitHub Pages, which is static and cannot run PHP, so
 * this Worker replaces contact.php. It keeps the same layers, cheapest first:
 *
 *   1. POST only, plus an Origin check against the site's own hosts
 *   2. Request size cap
 *   3. Honeypot field ("website") — hidden from people, filled in by bots
 *   4. Dwell time ("js"/"ts") — a bot that posts instantly on page load
 *   5. Per-IP rate limit (Workers Rate Limiting binding, no storage to run)
 *   6. Field validation, length caps and a link-count heuristic
 *   7. Cloudflare Turnstile, enforced whenever TURNSTILE_SECRET_KEY is set
 *
 * Delivery is the Cloudflare `send_email` binding by default. Setting
 * RESEND_API_KEY switches delivery to Resend; nothing else has to change.
 *
 * No build step: this is plain ESM JavaScript and deploys as-is.
 */

/* ------------------------------------------------------------------ config */

const MAX_BODY_BYTES = 16 * 1024;
const MIN_FILL_SECS = 2; // humans need at least this long to type a message
const MAX_FILL_SECS = 2 * 60 * 60; // a stale token is not a live submission
const MAX_LINKS = 4; // more than this in the body reads as spam
const MAX_NAME = 100;
const MIN_NAME = 2;
const MAX_EMAIL = 200;
const MIN_MESSAGE = 10;
const MAX_MESSAGE = 4000;

const DEFAULT_ALLOWED_ORIGINS = [
  'https://kernelkonsulting.com',
  'https://www.kernelkonsulting.com',
  'https://kernel-konsulting.github.io',
];

const SITE_URL = 'https://kernelkonsulting.com';
const CONTACT_EMAIL = 'contact@kernelkonsulting.com';

/* ----------------------------------------------------------------- helpers */

function parseList(value, fallback) {
  if (typeof value !== 'string' || value.trim() === '') return fallback;
  return value
    .split(',')
    .map((item) => item.trim())
    .filter(Boolean);
}

function corsHeaders(origin, allowedOrigins) {
  const headers = {
    Vary: 'Origin',
    'Access-Control-Allow-Methods': 'POST, OPTIONS',
    'Access-Control-Allow-Headers': 'Content-Type, Accept, X-Requested-With',
    'Access-Control-Max-Age': '86400',
  };
  if (origin && allowedOrigins.includes(origin)) {
    headers['Access-Control-Allow-Origin'] = origin;
  }
  return headers;
}

function jsonResponse(status, payload, headers) {
  return new Response(JSON.stringify(payload), {
    status,
    headers: {
      'Content-Type': 'application/json; charset=utf-8',
      'Cache-Control': 'no-store',
      'X-Content-Type-Options': 'nosniff',
      ...headers,
    },
  });
}

function escapeHtml(value) {
  return String(value)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}

/** Result page for the no-JavaScript path, mirroring contact.php. */
function htmlResponse(status, heading, message) {
  const body = `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex">
<title>${escapeHtml(heading)} — Kernel Konsulting</title>
<style>
  :root { color-scheme: light }
  body { margin:0; min-height:100dvh; display:grid; place-content:center; gap:.75rem;
         padding:2rem; text-align:center; background:#f6f8fa; color:#0b0f14;
         font:16px/1.6 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Arial,sans-serif }
  h1 { font-size:1.6rem; margin:0 }
  p { margin:0; color:#5a6675; max-width:34rem }
  a { color:#0f6f96 }
</style>
</head>
<body>
  <h1>${escapeHtml(heading)}</h1>
  <p>${escapeHtml(message)}</p>
  <p><a href="${SITE_URL}/#contact">Back to kernelkonsulting.com</a></p>
</body>
</html>`;
  return new Response(body, {
    status,
    headers: {
      'Content-Type': 'text/html; charset=utf-8',
      'Cache-Control': 'no-store',
      'X-Content-Type-Options': 'nosniff',
    },
  });
}

/** True when the request came from a fetch() call in our own front end. */
function wantsJson(request) {
  if (request.headers.get('X-Requested-With') === 'fetch') return true;
  return (request.headers.get('Accept') || '').includes('application/json');
}

/** Strip anything that could smuggle a header into the outgoing mail. */
function stripHeaderBreakers(value) {
  return String(value)
    .replace(/[\r\n]|%0a|%0d/gi, ' ')
    .replace(/\s{2,}/g, ' ');
}

/** "Ada Lovelace <ada@example.com>" — Resend and SMTP both accept this form. */
function formatAddress(address) {
  if (!address) return '';
  if (typeof address === 'string') return address;
  return address.name ? `${address.name} <${address.email}>` : address.email;
}

function clientIp(request) {
  return request.headers.get('CF-Connecting-IP') || '0.0.0.0';
}

/** Pragmatic address check; the address is only ever used as a Reply-To. */
function looksLikeEmail(value) {
  if (value.length > MAX_EMAIL) return false;
  return /^[^\s@,;:<>"'()[\]]+@[^\s@.]+(\.[^\s@.]+)+$/.test(value);
}

function countLinks(value) {
  const matches = value.match(/https?:\/\//gi);
  return matches ? matches.length : 0;
}

/** Cloudflare's published always-pass test key. Never valid in production. */
function isTurnstileTestSecret(secret) {
  return secret.startsWith('1x0000000000000000000000000000000');
}

/** Turnstile validation. Returns { ok, codes }. */
async function verifyTurnstile(secret, token, ip, allowedHostnames, expectedAction) {
  if (token === '' || token.length > 2048) {
    return { ok: false, codes: ['missing-input-response'] };
  }

  const form = new FormData();
  form.append('secret', secret);
  form.append('response', token);
  if (ip) form.append('remoteip', ip);

  let payload;
  try {
    const response = await fetch(
      'https://challenges.cloudflare.com/turnstile/v0/siteverify',
      { method: 'POST', body: form },
    );
    payload = await response.json();
  } catch {
    return { ok: false, codes: ['internal-error'] };
  }

  if (payload.success !== true) {
    return { ok: false, codes: payload['error-codes'] || ['unknown'] };
  }
  if (allowedHostnames.length && !allowedHostnames.includes(payload.hostname)) {
    return { ok: false, codes: ['hostname-mismatch'] };
  }
  if (expectedAction && payload.action !== expectedAction) {
    return { ok: false, codes: ['action-mismatch'] };
  }
  return { ok: true, codes: [] };
}

/* ---------------------------------------------------------------- delivery */

async function deliverViaCloudflare(env, message) {
  const result = await env.EMAIL.send({
    to: message.to,
    from: message.from,
    replyTo: message.replyTo,
    subject: message.subject,
    text: message.text,
  });
  return result && result.messageId ? result.messageId : 'sent';
}

async function deliverViaResend(env, message) {
  const response = await fetch('https://api.resend.com/emails', {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${env.RESEND_API_KEY}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({
      from: message.from,
      to: [message.to],
      reply_to: formatAddress(message.replyTo),
      subject: message.subject,
      text: message.text,
    }),
  });
  const payload = await response.json().catch(() => ({}));
  if (!response.ok) {
    throw new Error(`resend ${response.status}: ${payload.message || 'failed'}`);
  }
  return payload.id || 'sent';
}

async function deliver(env, message) {
  if (env.RESEND_API_KEY) return deliverViaResend(env, message);
  return deliverViaCloudflare(env, message);
}

/* ------------------------------------------------------------------ handler */

export async function handleRequest(request, env) {
  const allowedOrigins = parseList(env.ALLOWED_ORIGINS, DEFAULT_ALLOWED_ORIGINS);
  const origin = request.headers.get('Origin');
  const cors = corsHeaders(origin, allowedOrigins);
  const asJson = wantsJson(request);

  const finish = (status, ok, heading, message) => {
    const payload = { ok, message };
    return asJson
      ? jsonResponse(status, payload, cors)
      : htmlResponse(status, heading, message);
  };

  // --- CORS preflight ------------------------------------------------------
  if (request.method === 'OPTIONS') {
    if (origin && !allowedOrigins.includes(origin)) {
      return new Response(null, { status: 403, headers: cors });
    }
    return new Response(null, { status: 204, headers: cors });
  }

  // --- 1. POST only, from our own site -------------------------------------
  if (request.method !== 'POST') {
    return new Response(JSON.stringify({ ok: false, message: 'This endpoint only accepts form submissions.' }), {
      status: 405,
      headers: { ...cors, 'Content-Type': 'application/json; charset=utf-8', Allow: 'POST' },
    });
  }

  if (origin && !allowedOrigins.includes(origin)) {
    return finish(403, false, 'Blocked', 'That submission did not come from this site.');
  }

  // --- 2. size cap ---------------------------------------------------------
  const declaredLength = Number(request.headers.get('Content-Length') || '0');
  if (declaredLength > MAX_BODY_BYTES) {
    return finish(413, false, 'Too large', 'That submission was too large to process.');
  }

  let form;
  try {
    form = await request.formData();
  } catch {
    return finish(400, false, 'Bad request', 'That submission could not be read.');
  }

  const field = (name) => {
    const value = form.get(name);
    return typeof value === 'string' ? value : '';
  };

  // --- 3. honeypot: fail silently so the bot believes it worked ------------
  if (field('website').trim() !== '') {
    console.log(`[contact] honeypot triggered from ${clientIp(request)}`);
    return finish(200, true, 'Thanks', 'Your message was received.');
  }

  // --- 4. dwell time, only when the browser confirmed JS ran ---------------
  if (field('js') !== '') {
    const ts = Number.parseInt(field('ts'), 10);
    const age = Math.floor(Date.now() / 1000) - ts;
    if (Number.isFinite(ts) && ts > 0 && age < MIN_FILL_SECS) {
      return finish(429, false, 'Too fast', 'That was submitted too quickly. Please try again.');
    }
    if (Number.isFinite(ts) && ts > 0 && age > MAX_FILL_SECS) {
      return finish(429, false, 'Stale form', 'That page had been open a while. Please reload and try again.');
    }
  }

  // --- 5. per-IP rate limit ------------------------------------------------
  if (env.CONTACT_RATE_LIMITER) {
    const { success } = await env.CONTACT_RATE_LIMITER.limit({
      key: `contact:${clientIp(request)}`,
    });
    if (!success) {
      return finish(429, false, 'Slow down', 'Too many messages from this connection. Please try again shortly.');
    }
  }

  // --- 6. validation -------------------------------------------------------
  const name = stripHeaderBreakers(field('name')).trim();
  const email = stripHeaderBreakers(field('email')).trim();
  const message = field('message').trim();

  const problems = [];
  if (name.length < MIN_NAME || name.length > MAX_NAME) {
    problems.push('Please enter your name.');
  }
  if (!looksLikeEmail(email)) {
    problems.push('Please enter a valid email address.');
  }
  if (message.length < MIN_MESSAGE) {
    problems.push('Please tell us a little more about what you need.');
  }
  if (message.length > MAX_MESSAGE) {
    problems.push(`That message is too long — please keep it under ${MAX_MESSAGE} characters.`);
  }
  if (countLinks(message) > MAX_LINKS) {
    problems.push('That message contains too many links.');
  }
  if (problems.length) {
    return finish(422, false, 'Check your details', problems.join(' '));
  }

  // --- 7. CAPTCHA ----------------------------------------------------------
  const turnstileSecret = env.TURNSTILE_SECRET_KEY || '';
  if (turnstileSecret) {
    if (isTurnstileTestSecret(turnstileSecret)) {
      // Loud on purpose: the test key passes everything, so a production
      // deploy that still carries it has no CAPTCHA at all.
      console.log('[contact] WARNING: running on a Turnstile TEST secret — no real challenge is being solved');
    }
    const allowedHostnames = parseList(env.TURNSTILE_HOSTNAMES, []);
    const result = await verifyTurnstile(
      turnstileSecret,
      field('cf-turnstile-response'),
      clientIp(request),
      allowedHostnames,
      env.TURNSTILE_ACTION ?? 'contact',
    );
    if (!result.ok) {
      console.log(`[contact] turnstile rejected: ${result.codes.join(',')}`);
      return finish(403, false, 'Verification failed',
        'We could not verify that you are human. Please reload and try again.');
    }
  }

  // --- send ----------------------------------------------------------------
  const siteName = env.SITE_NAME || 'kernelkonsulting.com';
  const to = env.MAIL_TO || CONTACT_EMAIL;
  const from = env.MAIL_FROM || `website@${new URL(SITE_URL).hostname}`;
  const submittedAt = new Date().toISOString();

  const text =
    'New contact form submission\n' +
    '===========================\n\n' +
    `Name:    ${name}\n` +
    `Email:   ${email}\n` +
    `Time:    ${submittedAt}\n` +
    `IP:      ${clientIp(request)}\n` +
    `Origin:  ${origin || '(none)'}\n\n` +
    'Message\n' +
    '-------\n' +
    `${message}\n`;

  try {
    await deliver(env, {
      to,
      from,
      replyTo: { email, name },
      subject: `[${siteName}] Contact form: ${name}`,
      text,
    });
  } catch (error) {
    console.log(`[contact] send failed: ${error && error.message}`);
    return finish(500, false, 'Message not sent',
      `Something went wrong on our side and your message was not sent. Please email us directly at ${to}`);
  }

  return finish(200, true, 'Thanks — message sent',
    'We have your message and will get back to you shortly.');
}

export default {
  async fetch(request, env) {
    return handleRequest(request, env);
  },
};
