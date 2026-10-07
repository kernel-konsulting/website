/**
 * Tests for the contact Worker.
 *
 * Runs the real handler from src/index.js against constructed Request objects,
 * with a fake email binding, so every layer is exercised without deploying.
 *
 *   node --test test/                      (or)   npm test
 *
 * The Turnstile cases call the real siteverify endpoint using Cloudflare's
 * published dummy keys, so they are skipped automatically when offline.
 */

import { test, beforeEach, afterEach } from 'node:test';
import assert from 'node:assert/strict';

import { handleRequest } from '../src/index.js';

/* --------------------------------------------------------------- test env */

const REAL_FETCH = globalThis.fetch;

/** Answer for siteverify so the captcha path runs without hitting the network. */
function stubSiteverify(payload = {
  success: true,
  hostname: 'kernelkonsulting.com',
  action: 'contact',
}) {
  globalThis.fetch = async () => new Response(JSON.stringify(payload), { status: 200 });
}

beforeEach(() => {
  globalThis.fetch = REAL_FETCH;
  stubSiteverify();
});

afterEach(() => {
  globalThis.fetch = REAL_FETCH;
});

const BASE_ENV = {
  ALLOWED_ORIGINS: 'https://kernelkonsulting.com,https://www.kernelkonsulting.com',
  SITE_NAME: 'kernelkonsulting.com',
  MAIL_TO: 'contact@kernelkonsulting.com',
  MAIL_FROM: 'website@kernelkonsulting.com',
  TURNSTILE_ACTION: 'contact',
  TURNSTILE_HOSTNAMES: '',
  TURNSTILE_SECRET_KEY: 'stub-secret',
};

const ALLOWED_ORIGIN = 'https://kernelkonsulting.com';

/** A fake `send_email` binding that records what it was asked to send. */
function fakeEmail({ fail = false } = {}) {
  const sent = [];
  return {
    sent,
    binding: {
      async send(message) {
        if (fail) throw new Error('smtp exploded');
        sent.push(message);
        return { messageId: `test-${sent.length}` };
      },
    },
  };
}

function formBody(overrides = {}) {
  const fields = {
    name: 'Ada Lovelace',
    email: 'ada@example.com',
    message: 'We need help standardising our deployment pipeline across teams.',
    website: '',
    js: '1',
    ts: String(Math.floor(Date.now() / 1000) - 10),
    // A token, because the captcha is enforced on every submission. The
    // siteverify stub accepts it; tests for the token itself override this.
    'cf-turnstile-response': 'valid-token',
    ...overrides,
  };
  const form = new FormData();
  for (const [key, value] of Object.entries(fields)) form.append(key, value);
  return form;
}

function post(body, { origin = ALLOWED_ORIGIN, headers = {}, json = true } = {}) {
  const finalHeaders = { ...headers };
  if (origin) finalHeaders.Origin = origin;
  if (json) {
    finalHeaders['X-Requested-With'] = 'fetch';
    finalHeaders.Accept = 'application/json';
  } else {
    finalHeaders.Accept = 'text/html';
  }
  return new Request('https://api.kernelkonsulting.com/contact', {
    method: 'POST',
    headers: finalHeaders,
    body,
  });
}

async function run(request, { env = {}, email = fakeEmail() } = {}) {
  const merged = { ...BASE_ENV, EMAIL: email.binding, ...env };
  const response = await handleRequest(request, merged);
  const contentType = response.headers.get('Content-Type') || '';
  const payload = contentType.includes('application/json')
    ? await response.json()
    : await response.text();
  return { response, payload, email };
}

/* ------------------------------------------------------------------ methods */

test('rejects anything that is not POST, and advertises Allow', async () => {
  const { response, payload } = await run(
    new Request('https://api.kernelkonsulting.com/contact', {
      method: 'GET',
      headers: { Origin: ALLOWED_ORIGIN, Accept: 'application/json' },
    }),
  );
  assert.equal(response.status, 405);
  assert.equal(response.headers.get('Allow'), 'POST');
  assert.equal(payload.ok, false);
});

test('answers CORS preflight for an allowed origin', async () => {
  const { response } = await run(
    new Request('https://api.kernelkonsulting.com/contact', {
      method: 'OPTIONS',
      headers: { Origin: ALLOWED_ORIGIN },
    }),
  );
  assert.equal(response.status, 204);
  assert.equal(response.headers.get('Access-Control-Allow-Origin'), ALLOWED_ORIGIN);
  assert.match(response.headers.get('Access-Control-Allow-Headers'), /X-Requested-With/);
});

test('refuses preflight from an unknown origin', async () => {
  const { response } = await run(
    new Request('https://api.kernelkonsulting.com/contact', {
      method: 'OPTIONS',
      headers: { Origin: 'https://evil.example' },
    }),
  );
  assert.equal(response.status, 403);
  assert.equal(response.headers.get('Access-Control-Allow-Origin'), null);
});

/* ------------------------------------------------------------------- origin */

test('refuses a submission from an origin that is not the site', async () => {
  const { response, payload, email } = await run(
    post(formBody(), { origin: 'https://evil.example' }),
  );
  assert.equal(response.status, 403);
  assert.equal(payload.ok, false);
  assert.equal(email.sent.length, 0);
});

test('allows a submission with no Origin header (curl, no-JS fallback)', async () => {
  const { response } = await run(post(formBody(), { origin: null, json: false }));
  assert.equal(response.status, 200);
});

/* --------------------------------------------------------------------- size */

test('rejects a body over the size cap before parsing it', async () => {
  const { response, payload, email } = await run(
    post(formBody(), { headers: { 'Content-Length': String(64 * 1024) } }),
  );
  assert.equal(response.status, 413);
  assert.equal(payload.ok, false);
  assert.equal(email.sent.length, 0);
});

/* ----------------------------------------------------------------- honeypot */

test('honeypot: silently accepts and sends nothing', async () => {
  const { response, payload, email } = await run(
    post(formBody({ website: 'http://spam.example' })),
  );
  assert.equal(response.status, 200);
  assert.equal(payload.ok, true);
  assert.equal(payload.message, 'Your message was received.');
  assert.equal(email.sent.length, 0);
});

/* ---------------------------------------------------------------- dwell time */

test('dwell time: rejects a form submitted immediately after load', async () => {
  const { response, payload, email } = await run(
    post(formBody({ ts: String(Math.floor(Date.now() / 1000)) })),
  );
  assert.equal(response.status, 429);
  assert.match(payload.message, /too quickly/i);
  assert.equal(email.sent.length, 0);
});

test('dwell time: rejects a stale form', async () => {
  const stale = Math.floor(Date.now() / 1000) - 3 * 60 * 60;
  const { response } = await run(post(formBody({ ts: String(stale) })));
  assert.equal(response.status, 429);
});

test('dwell time: is skipped when the browser never set js', async () => {
  const { response } = await run(
    post(formBody({ js: '', ts: String(Math.floor(Date.now() / 1000)) })),
  );
  assert.equal(response.status, 200);
});

/* --------------------------------------------------------------- rate limit */

test('rate limit: a refused key gets 429 and nothing is sent', async () => {
  const { response, payload, email } = await run(post(formBody()), {
    env: { CONTACT_RATE_LIMITER: { async limit() { return { success: false }; } } },
  });
  assert.equal(response.status, 429);
  assert.match(payload.message, /too many/i);
  assert.equal(email.sent.length, 0);
});

test('rate limit: the key is namespaced per IP', async () => {
  const keys = [];
  await run(post(formBody(), { headers: { 'CF-Connecting-IP': '203.0.113.9' } }), {
    env: {
      CONTACT_RATE_LIMITER: {
        async limit({ key }) {
          keys.push(key);
          return { success: true };
        },
      },
    },
  });
  assert.deepEqual(keys, ['contact:203.0.113.9']);
});

/* --------------------------------------------------------------- validation */

const badInputs = [
  ['a name that is too short', { name: 'A' }, /enter your name/i],
  ['a missing name', { name: '' }, /enter your name/i],
  ['a name past the cap', { name: 'x'.repeat(101) }, /enter your name/i],
  ['a malformed email', { email: 'not-an-address' }, /valid email/i],
  ['an email past the cap', { email: `${'a'.repeat(200)}@example.com` }, /valid email/i],
  ['a message that is too short', { message: 'hi there' }, /a little more/i],
  ['a message past the cap', { message: 'x'.repeat(4001) }, /too long/i],
  [
    'a message stuffed with links',
    { message: 'see http://a.example http://b.example http://c.example http://d.example http://e.example' },
    /too many links/i,
  ],
];

for (const [label, overrides, pattern] of badInputs) {
  test(`validation: rejects ${label}`, async () => {
    const { response, payload, email } = await run(post(formBody(overrides)));
    assert.equal(response.status, 422);
    assert.match(payload.message, pattern);
    assert.equal(email.sent.length, 0);
  });
}

test('validation: strips CRLF that would smuggle a mail header', async () => {
  const { response, email } = await run(
    post(formBody({ name: 'Ada\r\nBcc: victim@example.com' })),
  );
  assert.equal(response.status, 200);
  assert.equal(email.sent[0].subject.includes('\n'), false);
  assert.equal(email.sent[0].replyTo.name.includes('\r'), false);
  assert.match(email.sent[0].subject, /Ada Bcc: victim@example\.com/);
});

/* ------------------------------------------------------------------ success */

test('delivers a valid submission with a Reply-To for the sender', async () => {
  const { response, payload, email } = await run(post(formBody()));
  assert.equal(response.status, 200);
  assert.equal(payload.ok, true);
  assert.match(payload.message, /get back to you/i);

  assert.equal(email.sent.length, 1);
  const message = email.sent[0];
  assert.equal(message.to, 'contact@kernelkonsulting.com');
  assert.equal(message.from, 'website@kernelkonsulting.com');
  assert.deepEqual(message.replyTo, { email: 'ada@example.com', name: 'Ada Lovelace' });
  assert.equal(message.subject, '[kernelkonsulting.com] Contact form: Ada Lovelace');
  assert.match(message.text, /Ada Lovelace/);
  assert.match(message.text, /standardising our deployment pipeline/);
});

test('returns a result page, not JSON, when the browser has no JS', async () => {
  const { response, payload } = await run(post(formBody(), { json: false }));
  assert.equal(response.status, 200);
  assert.match(response.headers.get('Content-Type'), /text\/html/);
  assert.match(payload, /Back to kernelkonsulting\.com/);
});

test('reports a delivery failure as 500 with the fallback address', async () => {
  const { response, payload } = await run(post(formBody()), {
    email: fakeEmail({ fail: true }),
  });
  assert.equal(response.status, 500);
  assert.equal(payload.ok, false);
  assert.match(payload.message, /contact@kernelkonsulting\.com/);
});

test('delivery falls back to Resend when RESEND_API_KEY is set', async () => {
  const originalFetch = globalThis.fetch;
  const calls = [];
  globalThis.fetch = async (url, init) => {
    if (String(url).includes('siteverify')) {
      return new Response(
        JSON.stringify({ success: true, hostname: 'kernelkonsulting.com', action: 'contact' }),
        { status: 200 },
      );
    }
    calls.push({ url: String(url), body: JSON.parse(init.body) });
    return new Response(JSON.stringify({ id: 'resend-1' }), { status: 200 });
  };
  try {
    const email = fakeEmail();
    const { response } = await run(post(formBody()), {
      env: { RESEND_API_KEY: 'test-key' },
      email,
    });
    assert.equal(response.status, 200);
    assert.equal(email.sent.length, 0);
    assert.equal(calls.length, 1);
    assert.match(calls[0].url, /api\.resend\.com/);
    assert.deepEqual(calls[0].body.to, ['contact@kernelkonsulting.com']);
    assert.equal(calls[0].body.reply_to, 'Ada Lovelace <ada@example.com>');
  } finally {
    globalThis.fetch = originalFetch;
  }
});

/* ------------------------------------------------------------------ captcha */

test('turnstile: refuses to run at all when no secret is configured', async () => {
  // Fail closed: a missing secret must not silently mean "no CAPTCHA".
  const { response, payload, email } = await run(post(formBody()), {
    env: { TURNSTILE_SECRET_KEY: '' },
  });
  assert.equal(response.status, 503);
  assert.equal(payload.ok, false);
  assert.match(payload.message, /temporarily unavailable/i);
  assert.match(payload.message, /contact@kernelkonsulting\.com/);
  assert.equal(email.sent.length, 0);
});

test('turnstile: a missing token is rejected when the secret is configured', async () => {
  const { response, payload, email } = await run(
    post(formBody({ 'cf-turnstile-response': '' })),
    { env: { TURNSTILE_SECRET_KEY: '2x0000000000000000000000000000000AA' } },
  );
  assert.equal(response.status, 403);
  assert.match(payload.message, /verify that you are human/i);
  assert.equal(email.sent.length, 0);
});

test('turnstile: a forged token is rejected', async () => {
  globalThis.fetch = REAL_FETCH; // the always-fail key is a real API call
  const { response, email } = await run(
    post(formBody({ 'cf-turnstile-response': 'XXXX.DUMMY.TOKEN.XXXX' })),
    { env: { TURNSTILE_SECRET_KEY: '2x0000000000000000000000000000000AA' } },
  );
  assert.equal(response.status, 403);
  assert.equal(email.sent.length, 0);
});

test('turnstile: a token with no action is rejected when an action is required', async () => {
  const originalFetch = globalThis.fetch;
  // What a widget rendered without data-action returns.
  globalThis.fetch = async () =>
    new Response(JSON.stringify({ success: true, hostname: 'kernelkonsulting.com' }), {
      status: 200,
    });
  try {
    const { response, email } = await run(post(formBody({ 'cf-turnstile-response': 'a-token' })), {
      env: { TURNSTILE_SECRET_KEY: 'secret' },
    });
    assert.equal(response.status, 403);
    assert.equal(email.sent.length, 0);
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test('turnstile: the always-pass test pair is accepted', async (t) => {
  // Always-pass secret from Cloudflare's documented test keys. Needs network.
  // Test keys do not echo an `action`, so the action check is disabled here;
  // enforcement of it is covered by the two tests above.
  globalThis.fetch = REAL_FETCH; // the always-pass key is a real API call
  let result;
  try {
    result = await run(
      post(formBody({ 'cf-turnstile-response': 'XXXX.DUMMY.TOKEN.XXXX' })),
      {
        env: {
          TURNSTILE_SECRET_KEY: '1x0000000000000000000000000000000AA',
          TURNSTILE_ACTION: '',
        },
      },
    );
  } catch {
    t.skip('siteverify unreachable');
    return;
  }
  assert.equal(result.response.status, 200, JSON.stringify(result.payload));
  assert.equal(result.email.sent.length, 1);
});

test('turnstile: warns loudly when it is still on the test secret', async () => {
  const originalLog = console.log;
  const lines = [];
  console.log = (...args) => lines.push(args.join(' '));
  try {
    await run(post(formBody()), {
      env: {
        TURNSTILE_SECRET_KEY: '1x0000000000000000000000000000000AA',
        TURNSTILE_ACTION: '',
      },
    });
  } finally {
    console.log = originalLog;
  }
  assert.equal(
    lines.some((line) => line.includes('Turnstile TEST secret')),
    true,
    `expected a test-secret warning, got: ${JSON.stringify(lines)}`,
  );
});

test('turnstile: a response from the wrong hostname is rejected', async () => {
  const originalFetch = globalThis.fetch;
  globalThis.fetch = async () =>
    new Response(
      JSON.stringify({ success: true, hostname: 'evil.example', action: 'contact' }),
      { status: 200 },
    );
  try {
    const { response, email } = await run(
      post(formBody({ 'cf-turnstile-response': 'a-token' })),
      {
        env: {
          TURNSTILE_SECRET_KEY: 'secret',
          TURNSTILE_HOSTNAMES: 'kernelkonsulting.com',
        },
      },
    );
    assert.equal(response.status, 403);
    assert.equal(email.sent.length, 0);
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test('turnstile: the wrong action is rejected', async () => {
  const originalFetch = globalThis.fetch;
  globalThis.fetch = async () =>
    new Response(
      JSON.stringify({ success: true, hostname: 'kernelkonsulting.com', action: 'login' }),
      { status: 200 },
    );
  try {
    const { response } = await run(post(formBody({ 'cf-turnstile-response': 'a-token' })), {
      env: { TURNSTILE_SECRET_KEY: 'secret' },
    });
    assert.equal(response.status, 403);
  } finally {
    globalThis.fetch = originalFetch;
  }
});
