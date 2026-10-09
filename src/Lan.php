<?php

namespace Tuma\Lan;

/**
 * PHP side of the tuma/mobile-lan plugin. Every method is a thin, synchronous
 * bridge call into the native discovery + receive-listener implementation.
 * Anything slow (accepting sockets, streaming uploads) happens off-thread in
 * native code and is reported back via the events under Tuma\Lan\Events.
 */
class Lan
{
    /**
     * Start UDP multicast announce + listen using the given device info.
     *
     * @param  array<string, mixed>  $deviceInfo  LocalSend v2 device-info JSON.
     */
    public function startDiscovery(array $deviceInfo): void
    {
        $this->call('Lan.StartDiscovery', ['deviceInfo' => $deviceInfo]);
    }

    /**
     * Whether the Wi-Fi radio is switched on. True when unknown (no bridge, iOS).
     */
    public function wifiEnabled(): bool
    {
        $result = $this->call('Lan.WifiEnabled', []);
        $decoded = $result !== null ? json_decode($result, true) : null;

        return (bool) ($decoded['enabled'] ?? true);
    }

    public function stopDiscovery(): void
    {
        $this->call('Lan.StopDiscovery', []);
    }

    /**
     * Start the HTTP(S) receive listener on the announced port. If that port
     * is busy the native side retries once on port + 1.
     *
     * When $publicFolder is given (Android), uploads stream straight into the
     * public Downloads/{publicFolder} collection via MediaStore and
     * UploadComplete reports a content:// URI instead of a file path.
     *
     * @param  array<string, mixed>  $deviceInfo
     * @return int|null The port actually bound, or null when the listener failed to start.
     */
    public function startServer(array $deviceInfo, string $incomingDir, ?string $certPem = null, ?string $keyPem = null, ?string $publicFolder = null): ?int
    {
        $result = $this->call('Lan.StartServer', [
            'deviceInfo' => $deviceInfo,
            'incomingDir' => $incomingDir,
            'certPem' => $certPem,
            'keyPem' => $keyPem,
            'publicFolder' => $publicFolder,
        ]);

        $decoded = $result !== null ? json_decode($result, true) : null;

        if (! ($decoded['ok'] ?? false)) {
            return null;
        }

        return (int) ($decoded['port'] ?? $deviceInfo['port'] ?? 53480);
    }

    public function stopServer(): void
    {
        $this->call('Lan.StopServer', []);
    }

    /**
     * Answer a parked prepare-upload request. Native replies to the sender
     * with the given HTTP status; a 200 accepts the listed file ids.
     *
     * @param  list<string>  $acceptedFileIds
     */
    public function respond(string $requestId, array $acceptedFileIds, ?string $sessionId = null, int $status = 200): void
    {
        $this->call('Lan.Respond', [
            'requestId' => $requestId,
            'acceptedFileIds' => array_values($acceptedFileIds),
            'sessionId' => $sessionId,
            'status' => $status,
        ]);
    }

    public function cancelSession(string $sessionId): void
    {
        $this->call('Lan.CancelSession', ['sessionId' => $sessionId]);
    }

    /**
     * The device's current LAN IP, for the "your address" / manual-add UI.
     */
    public function localIp(): ?string
    {
        $result = $this->call('Lan.LocalIp', []);
        $decoded = $result !== null ? json_decode($result, true) : null;

        $ip = $decoded['ip'] ?? null;

        return is_string($ip) && $ip !== '' ? $ip : null;
    }

    /**
     * Open a received file (a content:// URI from the public Downloads
     * collection) in the system viewer.
     *
     * @return bool False when the file no longer exists or nothing can open it.
     */
    public function openFile(string $uri, ?string $mime = null): bool
    {
        $result = $this->call('Lan.OpenFile', ['uri' => $uri, 'mime' => $mime]);
        $decoded = $result !== null ? json_decode($result, true) : null;

        return (bool) ($decoded['ok'] ?? false);
    }

    /**
     * Force the app's appearance: 'light', 'dark', or 'system' to follow the OS.
     */
    public function setAppearance(string $mode): void
    {
        $this->call('Lan.SetAppearance', ['mode' => $mode]);
    }

    /**
     * @param  array<string, mixed>  $params
     */
    /**
     * Write a JPEG preview (about $size px on the long edge) of an image or
     * video to $dest. $source is a file path or, on Android, a content:// URI.
     */
    public function thumbnail(string $source, string $dest, ?string $mime = null, int $size = 256): bool
    {
        $result = $this->call('Lan.Thumbnail', ['source' => $source, 'dest' => $dest, 'mime' => $mime, 'size' => $size]);
        $decoded = $result !== null ? json_decode($result, true) : null;

        return (bool) ($decoded['ok'] ?? false);
    }

    /**
     * Open the system document picker with multiple selection. Answers with a
     * FilesPicking event (how many were chosen) and then FilesPicked once each
     * file has been copied somewhere PHP can read it.
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
     * Start a just-dispatched queue job now instead of on the worker's next
     * idle poll (up to 3s away on Android).
     */
    public function wakeQueue(): void
    {
        $this->call('Lan.WakeQueue', []);
    }

    private function call(string $method, array $params): ?string
    {
        if (! function_exists('nativephp_call')) {
            return null;
        }

        return nativephp_call($method, json_encode($params) ?: '{}');
    }
}
