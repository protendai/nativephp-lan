<?php

namespace Protendai\Lan;

/**
 * PHP side of protendai/nativephp-lan. Every method is a thin, synchronous
 * bridge call into native code. Anything slow (accepting sockets, streaming
 * uploads, probing the subnet) happens off-thread natively and is reported
 * back through the events under Protendai\Lan\Events.
 *
 * Outside a NativePHP runtime (tests without a fake bridge, artisan) every
 * call is a no-op that returns the "nothing happened" value.
 */
class Lan
{
    /** Defaults, mirrored by config/lan.php. */
    public const DEFAULTS = [
        'service_id' => 'nativephp-lan',
        'api_prefix' => '/api/nativephp-lan/v1',
        'port' => 53530,
        'multicast_group' => '224.0.0.170',
        'multicast_port' => 53530,
        'prepare_timeout' => 60,
        'max_file_size' => 0,
        'max_files' => 1000,
        'max_connections' => 32,
        'pin_max_attempts' => 3,
    ];

    /**
     * @param  array<string, mixed>  $config  Usually config('lan').
     */
    public function __construct(private array $config = []) {}

    // ── Discovery ────────────────────────────────────────────────

    /**
     * Announce this device by UDP multicast every 5 s, listen for others and
     * probe the local /24 over HTTP. Each device found arrives as PeerFound.
     * The first call on iOS shows the local-network permission prompt.
     *
     * @param  array<string, mixed>  $deviceInfo  See deviceInfo().
     * @param  array<string, mixed>  $options  Overrides for config/lan.php keys.
     */
    public function startDiscovery(array $deviceInfo, array $options = []): void
    {
        $this->call('Lan.StartDiscovery', [
            'deviceInfo' => $this->deviceInfo($deviceInfo, $options),
            'config' => $this->config($options),
        ]);
    }

    /**
     * Stop discovery, including running sweeps and announces.
     */
    public function stopDiscovery(): void
    {
        $this->call('Lan.StopDiscovery', []);
    }

    /**
     * Probe one /24 (e.g. "192.168.49" for a Wi-Fi Direct group) in rounds
     * until a device of this service answers or $seconds pass. The first
     * device found arrives as PeerFound.
     *
     * @param  array<string, mixed>  $deviceInfo
     * @param  array<string, mixed>  $options
     */
    public function sweepSubnet(array $deviceInfo, string $prefix, int $seconds = 20, array $options = []): void
    {
        $this->call('Lan.SweepSubnet', [
            'deviceInfo' => $this->deviceInfo($deviceInfo, $options),
            'prefix' => $prefix,
            'seconds' => $seconds,
            'config' => $this->config($options),
        ]);
    }

    /**
     * Introduce this device to a receive server (POST register), retrying for
     * up to $seconds. That server then dispatches PeerFound with our address.
     *
     * @param  array<string, mixed>  $deviceInfo
     * @param  int|null  $port  The server's port; defaults to the configured port.
     * @param  array<string, mixed>  $options
     */
    public function announce(array $deviceInfo, string $host, ?int $port = null, int $seconds = 20, array $options = []): void
    {
        $config = $this->config($options);

        $this->call('Lan.Announce', [
            'deviceInfo' => $this->deviceInfo($deviceInfo, $options),
            'host' => $host,
            'port' => $port ?? $config['port'],
            'seconds' => $seconds,
            'config' => $config,
        ]);
    }

    // ── Receive server ───────────────────────────────────────────

    /**
     * Start the HTTP receive server on deviceInfo['port'] (else the configured
     * port). If that port is busy, port + 1 is tried.
     *
     * Uploads land in {$incomingDir}/{sessionId}/{fileName}. On Android, with
     * $publicFolder, they stream into the public Downloads/{$publicFolder}
     * collection instead and UploadComplete reports a content:// URI.
     *
     * @param  array<string, mixed>  $deviceInfo
     * @param  array<string, mixed>  $options
     * @return int|null The port actually bound, or null when the server failed to start (ServerError follows).
     */
    public function startServer(array $deviceInfo, string $incomingDir, ?string $publicFolder = null, array $options = []): ?int
    {
        $info = $this->deviceInfo($deviceInfo, $options);

        $result = $this->decode($this->call('Lan.StartServer', [
            'deviceInfo' => $info,
            'incomingDir' => $incomingDir,
            'publicFolder' => $publicFolder,
            'config' => $this->config($options),
        ]));

        if (! ($result['ok'] ?? false)) {
            return null;
        }

        return (int) ($result['port'] ?? $info['port']);
    }

    public function stopServer(): void
    {
        $this->call('Lan.StopServer', []);
    }

    /**
     * Answer a parked prepare-upload (UploadRequested). The status goes to the
     * sender as-is: 200 accepts $acceptedFileIds into session $sessionId
     * (required with 200); 401 asks for a PIN, 403 declines, 409 means busy,
     * 429 slow down, or any other 4xx/5xx.
     *
     * @param  list<string>  $acceptedFileIds
     * @return bool False when the request is gone (already answered, timed out, withdrawn)
     *              or the answer was unusable (200 without a session id, not enough storage).
     */
    public function respond(string $requestId, array $acceptedFileIds = [], ?string $sessionId = null, int $status = 200): bool
    {
        $result = $this->decode($this->call('Lan.Respond', [
            'requestId' => $requestId,
            'acceptedFileIds' => array_values(array_map(strval(...), $acceptedFileIds)),
            'sessionId' => $sessionId,
            'status' => $status,
        ]));

        return (bool) ($result['ok'] ?? false);
    }

    /**
     * respond() with 200: accept these files into a session you created.
     *
     * @param  list<string>  $fileIds
     */
    public function accept(string $requestId, array $fileIds, string $sessionId): bool
    {
        return $this->respond($requestId, $fileIds, $sessionId, 200);
    }

    /**
     * respond() without files: 403 declined by default; 401, 409, 429 also make sense.
     */
    public function decline(string $requestId, int $status = 403): bool
    {
        return $this->respond($requestId, [], null, $status);
    }

    /**
     * Cancel a session from this (receiving) side: uploads stop, partial files
     * are removed and SessionCancelled(reason: "receiver") is dispatched.
     */
    public function cancelSession(string $sessionId): bool
    {
        return (bool) ($this->decode($this->call('Lan.CancelSession', ['sessionId' => $sessionId]))['ok'] ?? false);
    }

    // ── Network info ─────────────────────────────────────────────

    /**
     * The device's current LAN IPv4 address, or null.
     */
    public function localIp(): ?string
    {
        $ip = $this->decode($this->call('Lan.LocalIp', []))['ip'] ?? null;

        return is_string($ip) && $ip !== '' ? $ip : null;
    }

    /**
     * Whether the Wi-Fi radio is on (Android). Always true on iOS and outside a native runtime.
     */
    public function wifiEnabled(): bool
    {
        return (bool) ($this->decode($this->call('Lan.WifiEnabled', []))['enabled'] ?? true);
    }

    // ── Utilities ────────────────────────────────────────────────

    /**
     * Open the system document picker with multiple selection. Answers with
     * FilesPicking (how many were chosen) and FilesPicked once each file has
     * been copied somewhere PHP can read it.
     *
     * @param  list<string>  $mimeTypes
     */
    public function pickFiles(array $mimeTypes = ['*/*']): void
    {
        $this->call('Lan.PickFiles', ['mimeTypes' => array_values($mimeTypes)]);
    }

    /**
     * Open the system photo picker (photos and videos) with multiple
     * selection. Same FilesPicking / FilesPicked events as pickFiles().
     */
    public function pickMedia(): void
    {
        $this->call('Lan.PickMedia', []);
    }

    /**
     * Write a JPEG preview (about $size px on the long edge) of an image or
     * video to $dest. $source is a file path or, on Android, a content:// URI.
     */
    public function thumbnail(string $source, string $dest, ?string $mime = null, int $size = 256): bool
    {
        return (bool) ($this->decode($this->call('Lan.Thumbnail', [
            'source' => $source,
            'dest' => $dest,
            'mime' => $mime,
            'size' => $size,
        ]))['ok'] ?? false);
    }

    /**
     * Open a file in the system viewer: a content:// URI on Android, Quick Look for a file path on iOS.
     *
     * @return bool False when the file no longer exists or nothing can open it.
     */
    public function openFile(string $uri, ?string $mime = null): bool
    {
        return (bool) ($this->decode($this->call('Lan.OpenFile', ['uri' => $uri, 'mime' => $mime]))['ok'] ?? false);
    }

    // ── Config ───────────────────────────────────────────────────

    /**
     * The settings sent to native code: config/lan.php merged with $options
     * (both snake_case), in the camelCase shape the native side reads.
     *
     * @param  array<string, mixed>  $options
     * @return array{serviceId: string, apiPrefix: string, port: int, multicastGroup: string, multicastPort: int, prepareTimeout: int, maxFileSize: int, maxFiles: int, maxConnections: int, pinMaxAttempts: int}
     */
    public function config(array $options = []): array
    {
        $c = array_replace(self::DEFAULTS, array_filter($this->config, fn ($v) => $v !== null), array_filter($options, fn ($v) => $v !== null));

        return [
            'serviceId' => (string) $c['service_id'],
            'apiPrefix' => '/'.trim((string) $c['api_prefix'], '/ '),
            'port' => (int) $c['port'],
            'multicastGroup' => (string) $c['multicast_group'],
            'multicastPort' => (int) $c['multicast_port'],
            'prepareTimeout' => (int) $c['prepare_timeout'],
            'maxFileSize' => max(0, (int) $c['max_file_size']),
            'maxFiles' => (int) $c['max_files'],
            'maxConnections' => (int) $c['max_connections'],
            'pinMaxAttempts' => (int) $c['pin_max_attempts'],
        ];
    }

    /**
     * A device-info JSON with this service's marker and port filled in when
     * missing. Typical keys: alias, fingerprint, deviceModel, deviceType,
     * port, protocol ("http"), version, download.
     *
     * @param  array<string, mixed>  $deviceInfo
     * @param  array<string, mixed>  $options
     * @return array<string, mixed>
     */
    public function deviceInfo(array $deviceInfo, array $options = []): array
    {
        $config = $this->config($options);

        $deviceInfo['app'] ??= $config['serviceId'];
        $deviceInfo['port'] ??= $config['port'];
        $deviceInfo['protocol'] ??= 'http';

        return $deviceInfo;
    }

    // ── Bridge ───────────────────────────────────────────────────

    /**
     * @param  array<string, mixed>  $params
     */
    protected function call(string $method, array $params): ?string
    {
        if (! function_exists('nativephp_call')) {
            return null;
        }

        return nativephp_call($method, json_encode($params, JSON_UNESCAPED_SLASHES) ?: '{}');
    }

    /**
     * Decode a bridge result. Accepts the flat shape and the {status, data} envelope.
     *
     * @return array<string, mixed>
     */
    protected function decode(?string $result): array
    {
        $decoded = $result !== null ? json_decode($result, true) : null;

        if (! is_array($decoded)) {
            return [];
        }

        return is_array($decoded['data'] ?? null) ? $decoded['data'] : $decoded;
    }
}
