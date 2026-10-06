<?php
declare(strict_types=1);

/**
 * Contact form endpoint.
 *
 * Layers, cheapest first:
 *   1. POST only, plus an Origin/Referer check against this host
 *   2. Honeypot field  ("website") — hidden from people, filled in by bots
 *   3. Dwell time       ("js"/"ts") — a bot that posts instantly on page load
 *   4. Per-IP rate limit (file backed, no external service)
 *   5. Field validation, length caps and a link-count heuristic
 *   6. Optional Cloudflare Turnstile check, enabled by adding keys to the config
 *
 * Delivery is over an authenticated SMTP relay (see includes/smtp.php) so no
 * local mail transfer agent is required. Credentials live in
 * contact-config.php, which is never committed.
 */

const RATE_WINDOW   = 3600;  // seconds
const RATE_MAX      = 4;     // submissions per IP per window
const MIN_FILL_SECS = 2;     // humans need at least this long to type a message
const MAX_LINKS     = 4;     // more than this in the body reads as spam

$configPath = __DIR__ . '/contact-config.php';

// ------------------------------------------------------------------ helpers
function respond_json(int $status, array $payload): void
{
    http_response_code($status);
    header('Content-Type: application/json; charset=utf-8');
    echo json_encode($payload, JSON_UNESCAPED_SLASHES);
    exit;
}

function respond_html(int $status, string $heading, string $message): void
{
    http_response_code($status);
    header('Content-Type: text/html; charset=utf-8');
    $h = htmlspecialchars($heading, ENT_QUOTES, 'UTF-8');
    $m = htmlspecialchars($message, ENT_QUOTES, 'UTF-8');
    echo <<<HTML
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex">
<title>{$h} — Kernel Konsulting</title>
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
  <h1>{$h}</h1>
  <p>{$m}</p>
  <p><a href="/#contact">Back to kernelkonsulting.com</a></p>
</body>
</html>
HTML;
    exit;
}

/** True when the request came from a fetch() call in our own front end. */
function wants_json(): bool
{
    if (($_SERVER['HTTP_X_REQUESTED_WITH'] ?? '') === 'fetch') {
        return true;
    }
    $accept = $_SERVER['HTTP_ACCEPT'] ?? '';
    return str_contains($accept, 'application/json');
}

function finish(int $status, bool $ok, string $heading, string $message): void
{
    if (wants_json()) {
        respond_json($status, ['ok' => $ok, 'message' => $message]);
    }
    respond_html($status, $heading, $message);
}

function client_ip(): string
{
    // Behind Cloudflare, CF-Connecting-IP is the only trustworthy source.
    $ip = $_SERVER['HTTP_CF_CONNECTING_IP'] ?? $_SERVER['REMOTE_ADDR'] ?? '';
    return filter_var($ip, FILTER_VALIDATE_IP) ?: '0.0.0.0';
}

/** Sliding-window rate limit, one small file per IP. */
function rate_limit_exceeded(string $ip): bool
{
    $dir = sys_get_temp_dir() . '/kk-contact-rate';
    if (!is_dir($dir) && !@mkdir($dir, 0700, true) && !is_dir($dir)) {
        return false; // never lock real users out because of a filesystem problem
    }
    $file = $dir . '/' . hash('sha256', $ip);
    $now  = time();

    $fh = @fopen($file, 'c+');
    if ($fh === false) {
        return false;
    }
    flock($fh, LOCK_EX);
    $raw   = stream_get_contents($fh);
    $times = array_values(array_filter(
        array_map('intval', $raw === '' ? [] : explode(',', $raw)),
        static fn (int $t): bool => $t > $now - RATE_WINDOW
    ));

    if (count($times) >= RATE_MAX) {
        flock($fh, LOCK_UN);
        fclose($fh);
        return true;
    }

    $times[] = $now;
    ftruncate($fh, 0);
    rewind($fh);
    fwrite($fh, implode(',', $times));
    fflush($fh);
    flock($fh, LOCK_UN);
    fclose($fh);
    return false;
}

function verify_turnstile(string $secret, string $response): bool
{
    $ch = curl_init('https://challenges.cloudflare.com/turnstile/v0/siteverify');
    curl_setopt_array($ch, [
        CURLOPT_POST           => true,
        CURLOPT_POSTFIELDS     => http_build_query([
            'secret'   => $secret,
            'response' => $response,
            'remoteip' => client_ip(),
        ]),
        CURLOPT_RETURNTRANSFER => true,
        CURLOPT_TIMEOUT        => 8,
    ]);
    $body = curl_exec($ch);
    curl_close($ch);
    if (!is_string($body)) {
        return false;
    }
    $data = json_decode($body, true);
    return is_array($data) && ($data['success'] ?? false) === true;
}

// ------------------------------------------------------------------- guards
if (($_SERVER['REQUEST_METHOD'] ?? '') !== 'POST') {
    header('Allow: POST');
    finish(405, false, 'Not allowed', 'This endpoint only accepts form submissions.');
}

if (!is_file($configPath)) {
    error_log('[contact] contact-config.php is missing');
    finish(500, false, 'Not configured',
        'The contact form has not been configured on the server yet.');
}

/** @var array<string,mixed> $config */
$config = require $configPath;
$debug  = (bool) ($config['debug'] ?? false);

// Only accept posts that originated on this host.
$host    = $_SERVER['HTTP_HOST'] ?? '';
$referer = $_SERVER['HTTP_REFERER'] ?? '';
if ($referer !== '') {
    $refHost = parse_url($referer, PHP_URL_HOST) ?: '';
    $allowed = array_filter(array_map('trim', (array) ($config['allowed_hosts'] ?? [$host])));
    $ok = false;
    foreach ($allowed as $candidate) {
        if (strcasecmp($refHost, (string) $candidate) === 0) {
            $ok = true;
            break;
        }
    }
    if (!$ok) {
        finish(403, false, 'Blocked', 'That submission did not come from this site.');
    }
}

// Honeypot: real users never see this field, so anything in it is a bot.
if (trim((string) ($_POST['website'] ?? '')) !== '') {
    error_log('[contact] honeypot triggered from ' . client_ip());
    finish(200, true, 'Thanks', 'Your message was received.'); // fail silently for the bot
}

// Dwell time, only when the browser confirmed JS ran.
if (($_POST['js'] ?? '') !== '') {
    $ts = (int) ($_POST['ts'] ?? 0);
    if ($ts > 0 && (time() - $ts) < MIN_FILL_SECS) {
        finish(429, false, 'Too fast', 'That was submitted too quickly. Please try again.');
    }
}

if (rate_limit_exceeded(client_ip())) {
    finish(429, false, 'Slow down', 'Too many messages from this connection. Please try again later.');
}

$name    = trim((string) ($_POST['name'] ?? ''));
$email   = trim((string) ($_POST['email'] ?? ''));
$message = trim((string) ($_POST['message'] ?? ''));

// Strip anything that could smuggle a header.
$strip = static fn (string $v): string => str_replace(["\r", "\n", "%0a", "%0d"], ' ', $v);
$name  = $strip($name);
$email = $strip($email);

$errors = [];
if (mb_strlen($name) < 2 || mb_strlen($name) > 100) {
    $errors[] = 'Please enter your name.';
}
if (!filter_var($email, FILTER_VALIDATE_EMAIL) || mb_strlen($email) > 200) {
    $errors[] = 'Please enter a valid email address.';
}
if (mb_strlen($message) < 10) {
    $errors[] = 'Please tell us a little more about what you need.';
}
if (mb_strlen($message) > 4000) {
    $errors[] = 'That message is too long — please keep it under 4000 characters.';
}
if (preg_match_all('~https?://~i', $message) > MAX_LINKS) {
    $errors[] = 'That message contains too many links.';
}
if ($errors) {
    finish(422, false, 'Check your details', implode(' ', $errors));
}

// Optional CAPTCHA — only enforced when keys are present.
$turnstileSecret = (string) ($config['turnstile_secret'] ?? '');
if ($turnstileSecret !== '') {
    $token = (string) ($_POST['cf-turnstile-response'] ?? '');
    if ($token === '' || !verify_turnstile($turnstileSecret, $token)) {
        finish(403, false, 'Verification failed',
            'We could not verify that you are human. Please reload and try again.');
    }
}

// -------------------------------------------------------------------- send
require_once __DIR__ . '/includes/smtp.php';

$siteName = (string) ($config['site_name'] ?? 'kernelkonsulting.com');
$subject  = sprintf('[%s] Contact form: %s', $siteName, $name);
$body     = "New contact form submission\n"
          . "===========================\n\n"
          . "Name:    {$name}\n"
          . "Email:   {$email}\n"
          . "Time:    " . date('Y-m-d H:i:s T') . "\n"
          . "IP:      " . client_ip() . "\n"
          . "Referer: " . ($referer !== '' ? $referer : '(none)') . "\n\n"
          . "Message\n"
          . "-------\n"
          . $message . "\n";

try {
    $mailer = new SmtpMailer(
        host:       (string) ($config['smtp_host'] ?? ''),
        port:       (int) ($config['smtp_port'] ?? 587),
        encryption: (string) ($config['smtp_encryption'] ?? 'tls'),
        username:   (string) ($config['smtp_username'] ?? ''),
        password:   (string) ($config['smtp_password'] ?? ''),
        timeout:    (int) ($config['smtp_timeout'] ?? 15),
        debug:      $debug,
    );

    $mailer->send(
        fromAddress: (string) ($config['from_address'] ?? ''),
        fromName:    (string) ($config['from_name'] ?? $siteName),
        recipients:  [(string) ($config['to_address'] ?? '')],
        subject:     $subject,
        textBody:    $body,
        replyTo:     $email,
    );
} catch (Throwable $e) {
    error_log('[contact] send failed: ' . $e->getMessage());
    finish(500, false, 'Message not sent',
        'Something went wrong on our side and your message was not sent. '
        . 'Please email us directly at ' . (string) ($config['to_address'] ?? ''));
}

finish(200, true, 'Thanks — message sent',
    'We have your message and will get back to you shortly.');
