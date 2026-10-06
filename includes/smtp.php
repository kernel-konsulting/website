<?php
declare(strict_types=1);

/**
 * Minimal SMTP client.
 *
 * Exists so the contact form can send mail over an authenticated relay without
 * vendoring a mail library and without depending on the host's local MTA.
 * Supports implicit TLS (smtps, port 465), STARTTLS (port 587) and plain
 * connections, and AUTH LOGIN / AUTH PLAIN.
 */
final class SmtpMailer
{
    /** @var resource|null */
    private $socket = null;
    private string $hostname;

    public function __construct(
        private string $host,
        private int $port = 587,
        private string $encryption = 'tls',   // tls | ssl | none
        private string $username = '',
        private string $password = '',
        private int $timeout = 15,
        private bool $debug = false,
    ) {
        $this->hostname = gethostname() ?: 'localhost';
    }

    /**
     * @param string[] $recipients
     */
    public function send(
        string $fromAddress,
        string $fromName,
        array $recipients,
        string $subject,
        string $textBody,
        ?string $replyTo = null
    ): void {
        $this->connect();
        try {
            $this->command('EHLO ' . $this->hostname, [250]);

            if ($this->encryption === 'tls') {
                $this->command('STARTTLS', [220]);
                $ok = stream_socket_enable_crypto(
                    $this->socket,
                    true,
                    STREAM_CRYPTO_METHOD_TLS_CLIENT
                );
                if ($ok !== true) {
                    throw new RuntimeException('STARTTLS negotiation failed');
                }
                $this->command('EHLO ' . $this->hostname, [250]);
            }

            if ($this->username !== '') {
                $this->authenticate();
            }

            $this->command('MAIL FROM:<' . $fromAddress . '>', [250]);
            foreach ($recipients as $rcpt) {
                $this->command('RCPT TO:<' . $rcpt . '>', [250, 251]);
            }

            $this->command('DATA', [354]);
            $this->write($this->buildMessage($fromAddress, $fromName, $recipients, $subject, $textBody, $replyTo));
            $this->command('.', [250]);
            $this->command('QUIT', [221]);
        } finally {
            $this->close();
        }
    }

    private function connect(): void
    {
        $scheme = $this->encryption === 'ssl' ? 'ssl://' : 'tcp://';
        $errno = 0;
        $errstr = '';
        $socket = @stream_socket_client(
            $scheme . $this->host . ':' . $this->port,
            $errno,
            $errstr,
            $this->timeout,
            STREAM_CLIENT_CONNECT
        );
        if ($socket === false) {
            throw new RuntimeException("Cannot connect to {$this->host}:{$this->port} ({$errno}) {$errstr}");
        }
        $this->socket = $socket;
        stream_set_timeout($this->socket, $this->timeout);
        $this->expect([220]);
    }

    private function authenticate(): void
    {
        $candidates = ['PLAIN', 'LOGIN'];
        if (preg_match('/AUTH[ =]([A-Z0-9 \-]+)/i', $this->lastResponse, $m)) {
            $advertised = array_map('strtoupper', preg_split('/\s+/', trim($m[1])));
            $candidates = array_values(array_intersect($candidates, $advertised)) ?: $candidates;
        }

        foreach ($candidates as $mech) {
            try {
                if ($mech === 'PLAIN') {
                    $payload = base64_encode("\0" . $this->username . "\0" . $this->password);
                    $this->command('AUTH PLAIN ' . $payload, [235]);
                } else {
                    $this->command('AUTH LOGIN', [334]);
                    $this->command(base64_encode($this->username), [334]);
                    $this->command(base64_encode($this->password), [235]);
                }
                return;
            } catch (RuntimeException $e) {
                if ($mech === end($candidates)) {
                    throw $e;
                }
            }
        }
    }

    private function buildMessage(
        string $fromAddress,
        string $fromName,
        array $recipients,
        string $subject,
        string $textBody,
        ?string $replyTo
    ): string {
        $encodedName = $fromName === ''
            ? ''
            : '=?UTF-8?B?' . base64_encode($fromName) . '?= ';

        $headers = [
            'Date: ' . date('r'),
            'From: ' . $encodedName . '<' . $fromAddress . '>',
            'To: ' . implode(', ', $recipients),
            'Subject: =?UTF-8?B?' . base64_encode($subject) . '?=',
            'Message-ID: <' . bin2hex(random_bytes(16)) . '@' . $this->hostname . '>',
            'MIME-Version: 1.0',
            'Content-Type: text/plain; charset=UTF-8',
            'Content-Transfer-Encoding: base64',
            'Auto-Submitted: auto-generated',
        ];
        if ($replyTo !== null && $replyTo !== '') {
            $headers[] = 'Reply-To: <' . $replyTo . '>';
        }

        $body = rtrim(chunk_split(base64_encode($textBody), 76, "\r\n"));

        return implode("\r\n", $headers) . "\r\n\r\n" . $body . "\r\n";
    }

    /** @var string */
    private string $lastResponse = '';

    /**
     * @param int[] $expected
     */
    private function command(string $command, array $expected): void
    {
        if ($command !== '.' ) {
            // never log credentials
            $this->log('>> ' . (str_starts_with($command, 'AUTH LOGIN') ? 'AUTH LOGIN' : $command));
        }
        $this->writeRaw($command . "\r\n");
        $this->expect($expected);
    }

    /**
     * @param int[] $expected
     */
    private function expect(array $expected): void
    {
        $response = '';
        while (true) {
            $line = fgets($this->socket, 2048);
            if ($line === false) {
                throw new RuntimeException('SMTP connection closed unexpectedly');
            }
            $response .= $line;
            // "250-STARTTLS" continues, "250 AUTH" ends
            if (strlen($line) < 4 || $line[3] !== '-') {
                break;
            }
        }
        $this->lastResponse = $response;
        $code = (int) substr($response, 0, 3);
        $this->log('<< ' . trim($response));
        if (!in_array($code, $expected, true)) {
            throw new RuntimeException('SMTP error: ' . trim($response));
        }
    }

    private function write(string $data): void
    {
        // normalise line endings, then dot-stuff (RFC 5321 §4.5.2)
        $data = preg_replace('/\r\n|\r|\n/', "\r\n", $data);
        $data = preg_replace('/^\./m', '..', $data);
        $this->writeRaw($data);
    }

    private function writeRaw(string $data): void
    {
        if ($this->socket === null) {
            throw new RuntimeException('Not connected');
        }
        $written = fwrite($this->socket, $data);
        if ($written === false) {
            throw new RuntimeException('Failed writing to SMTP socket');
        }
    }

    private function log(string $line): void
    {
        if ($this->debug) {
            error_log('[smtp] ' . $line);
        }
    }

    private function close(): void
    {
        if ($this->socket !== null) {
            @fclose($this->socket);
            $this->socket = null;
        }
    }
}
