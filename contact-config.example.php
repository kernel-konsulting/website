<?php
/**
 * Copy this file to contact-config.php and fill in real values.
 * contact-config.php is git-ignored and must never be committed.
 */

return [
    // --- who gets the mail -------------------------------------------------
    'to_address'   => 'contact@kernelkonsulting.com',

    // --- who it comes from -------------------------------------------------
    // Best deliverability: an address on the domain you control (SPF/DKIM aligned).
    'from_address' => 'no-reply@kernelkonsulting.com',
    'from_name'    => 'Kernel Konsulting website',
    'site_name'    => 'kernelkonsulting.com',

    // --- SMTP relay --------------------------------------------------------
    // The domain's MX points at Proton Mail, so Proton SMTP is the natural fit:
    // create an SMTP token in Proton settings and use your full Proton address
    // as the username. (A Gmail account with an App Password works too.)
    'smtp_host'       => 'smtp.protonmail.ch',
    'smtp_port'       => 587,
    'smtp_encryption' => 'tls',          // tls (587) | ssl (465) | none
    'smtp_username'   => 'contact@kernelkonsulting.com',
    'smtp_password'   => '',             // <-- fill in; never commit this file
    'smtp_timeout'    => 15,

    // --- spam --------------------------------------------------------------
    // Hosts allowed to post to contact.php. Yours, not someone else's.
    'allowed_hosts' => ['kernelkonsulting.com', 'www.kernelkonsulting.com'],

    // Optional: Cloudflare Turnstile (free). Leave the secret empty to disable.
    // When set, the front end must render the Turnstile widget for the check to pass.
    'turnstile_secret' => '',

    // --- diagnostics -------------------------------------------------------
    // true logs the SMTP conversation (credentials are never logged) to the
    // PHP error log. Turn it off once the form works.
    'debug' => false,
];
