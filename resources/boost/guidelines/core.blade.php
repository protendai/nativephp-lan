## protendai/nativephp-lan

Local-network file transfer for NativePHP Mobile v4 on iOS and Android: discovery (UDP multicast + HTTP subnet probe) and an embedded HTTP receive server that streams uploads to disk. PHP decides who may send; native code does the networking off-thread and reports back with events. The sending half is plain HTTP from PHP (Laravel `Http`) against the routes below.

### Configuration (`config/lan.php`, publish with `php artisan vendor:publish --tag=lan-config`)

- `service_id`, `api_prefix`, `port`, `multicast_group`, `multicast_port` define the wire protocol. Two installs only see each other when all five match. Pick your own values per app and never change them after release.
- Limits: `prepare_timeout` (s, default 60), `max_file_size` (bytes, 0 = none), `max_files`, `max_connections`, `pin_max_attempts`.
- Every start/announce/sweep call takes a trailing `array $options` (snake_case keys) that overrides the config for that call.

### Methods (facade `Protendai\Lan\Facades\Lan`)

- `Lan::startServer(array $deviceInfo, string $incomingDir, ?string $publicFolder = null, array $options = []): ?int` returns the bound port (configured port, or +1 when busy) or null (then `ServerError`). `$publicFolder` (Android only) streams into public Downloads/{folder} and `UploadComplete::$path` is a content:// URI.
- `Lan::stopServer()`: parked requests get 503, sessions end with `SessionCancelled(reason: 'stopped')`, partial files are removed.
- `Lan::respond(string $requestId, array $acceptedFileIds = [], ?string $sessionId = null, int $status = 200): bool`. The status reaches the sender as-is (401 PIN, 403 declined, 409 busy, 429 slow down). 200 requires a `$sessionId` you create. Returns false when the request is gone (answered, timed out, withdrawn) or storage is short (sender gets 507). Shorthands: `Lan::accept($requestId, $fileIds, $sessionId)`, `Lan::decline($requestId, $status = 403)`.
- `Lan::cancelSession(string $sessionId): bool` cancels from the receiving side (`reason: 'receiver'`).
- `Lan::startDiscovery(array $deviceInfo, array $options = [])` / `Lan::stopDiscovery()`; `Lan::sweepSubnet(array $deviceInfo, string $prefix, int $seconds = 20)` probes one /24 such as `'192.168.49'`; `Lan::announce(array $deviceInfo, string $host, ?int $port = null, int $seconds = 20)` POSTs register so that host learns our address.
- `Lan::localIp(): ?string`, `Lan::wifiEnabled(): bool` (always true on iOS).
- Utilities: `Lan::pickFiles(array $mimeTypes = ['*/*'])`, `Lan::pickMedia()` (both answer `FilesPicking` then `FilesPicked`), `Lan::thumbnail($source, $dest, $mime, $size): bool`, `Lan::openFile($uri, $mime): bool`.
- `$deviceInfo`: `alias`, `fingerprint` (stable random id per install), `deviceModel`, `deviceType`, `port`, `protocol` (`http`), `version`. The plugin fills in `app` (service id), `port` and `protocol` when missing.

### Events (`#[OnNative(...)]` from `Native\Mobile\Attributes\OnNative`)

- `PeerFound`: `alias`, `fingerprint`, `ip` (always the observed address), `port`, `protocol`, `deviceModel`, `deviceType`. Repeats every announcement; de-duplicate by fingerprint.
- `UploadRequested`: `requestId`, `sender` (self-declared, except `sender['ip']`), `files` (`id`, `fileName`, `size`, `fileType`), `pinProvided`, `remoteIp`. Answer with `Lan::respond()` within `prepare_timeout`.
- `UploadProgress`: `sessionId`, `fileId`, `bytesReceived`, `bytesTotal` (at most twice a second).
- `UploadComplete`: `sessionId`, `fileId`, `path`.
- `SessionCancelled`: `sessionId` or (for an unanswered request) `requestId`, and `reason`: `sender`, `receiver`, `interrupted`, `timeout`, `storage`, `stopped`, `error` (constants on the class). On `timeout` close any prompt for that `requestId`.
- `ServerError`: `message`. `FilesPicking`: `count`. `FilesPicked`: `files` (`path`, `name`, `size`).
- Declare every handler parameter optional with a default; payloads from older native builds may lack new keys.

### Security rules

- The fingerprint is self-declared and broadcast: anyone on the LAN can claim it. Only auto-accept (skip the prompt) when the fingerprint is trusted AND `remoteIp` equals the IP of a peer you discovered recently (`PeerFound`). Otherwise ask the user.
- Answer 401 when a PIN is set and `pinProvided` is wrong; native code locks out an IP after `pin_max_attempts` wrong PINs.
- There is no TLS yet: do not use this for secrets on untrusted networks.

### Wire protocol (for the PHP sender)

`GET {prefix}/info`, `POST {prefix}/register` (device info JSON), `POST {prefix}/prepare-upload[?pin=]` with `{info, files: {fileId: {id, fileName, size, fileType}}}` returns `{sessionId, files: {fileId: token}}`, `POST {prefix}/upload?sessionId&fileId&token` with the raw body and a Content-Length no larger than the declared size (tokens are one-shot, chunked bodies get 501), `POST {prefix}/cancel?sessionId=` or `?fingerprint=`. Treat a 200 prepare-upload without a `sessionId` as busy (older receivers).

### Platform notes

- iOS: set `NSLocalNetworkUsageDescription` wording in `config('nativephp.permissions')` if needed; multicast sending needs Apple's `com.apple.developer.networking.multicast` entitlement (discovery still works via the HTTP probe without it). App-wide keys such as `UIFileSharingEnabled`, `LSSupportsOpeningDocumentsInPlace` and `NSBonjourServices` are the app's choice, set in `config('nativephp.permissions')`.
- Android: minimum API 29. The plugin holds a Wi-Fi lock only while the server or discovery runs.
- Native code: rebuild with `php artisan native:run` after installing or updating; `native:jump` is not enough.

### Testing

FakeBridge macros: `withLocalIp('192.168.1.10')`, `withServerPort(?int $port)`, `withPendingRequests()`, `assertRespondedTo($requestId, ?$status)`, `assertDiscoveryStarted(?fn)`, `assertServerStarted(?fn)`. Drive screens with `->emitNative(UploadRequested::class, ['requestId' => 'req-1', 'sender' => [...], 'files' => [...], 'remoteIp' => '192.168.1.7'])`.

@verbatim
<code-snippet name="Receive screen (EDGE component)" lang="php">
use Illuminate\Support\Str;
use Native\Mobile\Attributes\OnNative;
use Native\Mobile\Edge\NativeComponent;
use Protendai\Lan\Events\SessionCancelled;
use Protendai\Lan\Events\UploadComplete;
use Protendai\Lan\Events\UploadRequested;
use Protendai\Lan\Facades\Lan;

class Receive extends NativeComponent
{
    public array $pending = [];

    public function mount(): void
    {
        $device = ['alias' => 'My phone', 'fingerprint' => $this->fingerprint(), 'deviceType' => 'mobile'];
        Lan::startServer($device, storage_path('app/incoming'));
        Lan::startDiscovery($device);
    }

    public function unmount(): void
    {
        Lan::stopDiscovery();
        Lan::stopServer();
    }

    #[OnNative(UploadRequested::class)]
    public function onUploadRequested(?string $requestId = null, array $sender = [], array $files = [], ?string $pinProvided = null, ?string $remoteIp = null): void
    {
        if ($this->pending !== []) {
            Lan::decline($requestId, 409); // busy

            return;
        }

        $this->pending = compact('requestId', 'sender', 'files', 'remoteIp');
    }

    public function accept(): void
    {
        $sessionId = (string) Str::uuid();
        Lan::accept($this->pending['requestId'], array_column($this->pending['files'], 'id'), $sessionId);
        $this->pending = [];
    }

    #[OnNative(SessionCancelled::class)]
    public function onCancelled(?string $sessionId = null, ?string $reason = null, ?string $requestId = null): void
    {
        if ($requestId !== null && ($this->pending['requestId'] ?? null) === $requestId) {
            $this->pending = []; // withdrawn or timed out
        }
    }

    #[OnNative(UploadComplete::class)]
    public function onComplete(?string $sessionId = null, ?string $fileId = null, ?string $path = null): void
    {
        // move $path somewhere permanent
    }
}
</code-snippet>
@endverbatim
