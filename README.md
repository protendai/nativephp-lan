# nativephp-lan

Local-network file transfer for [NativePHP Mobile](https://nativephp.com) v4 apps on iOS and Android.

- **Discovery**: devices announce themselves by UDP multicast every 5 seconds and probe their /24 over HTTP (many routers drop multicast). A pairing helper sweeps a single subnet, such as a Wi-Fi Direct group.
- **Receive server**: an embedded HTTP server streams uploads straight to disk (or, on Android, into the public Downloads collection). Your PHP code decides who may send: every request is parked until you answer it.
- **Sending** is plain HTTP from PHP (Laravel's `Http` client) against the documented routes, so it is testable with `Http::fake()`.

The protocol is derived from [LocalSend](https://github.com/localsend/protocol) v2 (same JSON shapes), with your own service id, route prefix, port and multicast group. It does not talk to the LocalSend app.

| | Android | iOS |
|---|---|---|
| Multicast discovery | yes | yes (sending needs Apple's multicast entitlement, see below) |
| HTTP subnet probe, sweep, announce | yes | yes |
| Receive server | yes (NanoHTTPD) | yes (Network.framework) |
| Stream into public Downloads | yes (`$publicFolder`) | no (app sandbox) |
| Wi-Fi radio state | yes | always `true` |
| File / media pickers, thumbnails, open file | yes | yes |
| Minimum version | API 29 (Android 10) | iOS 15 |

## Installation

```bash
composer require protendai/nativephp-lan
php artisan native:plugin:register protendai/nativephp-lan
php artisan vendor:publish --tag=lan-config
```

The plugin contains native code: rebuild the app with `php artisan native:run` (`native:jump` is not enough).

## Configuration

`config/lan.php`:

| Key | Default | Meaning |
|---|---|---|
| `service_id` | `nativephp-lan` | `"app"` marker in every device-info JSON. Devices with another value are ignored. |
| `api_prefix` | `/api/nativephp-lan/v1` | Route prefix of the receive server. |
| `port` | `53530` | Receive server port. When busy, `port + 1` is used. |
| `multicast_group` | `224.0.0.170` | UDP multicast group for announcements. |
| `multicast_port` | `53530` | UDP multicast port. |
| `prepare_timeout` | `60` | Seconds a send request waits for `Lan::respond()`. |
| `max_file_size` | `0` | Largest single file in bytes, `0` = no limit (larger files get 413). |
| `max_files` | `1000` | Most files per send request. |
| `max_connections` | `32` | Most simultaneous connections; extra ones are closed. |
| `pin_max_attempts` | `3` | Wrong PINs per IP before a lockout (10 s, doubling, up to 5 min). |

Two installs only see each other when `service_id`, `api_prefix`, `port`, `multicast_group` and `multicast_port` all match. **Choose your own values for your app** (so it never answers devices of another app built on this plugin), and never change them after release, or older installs stop finding newer ones. Every start, announce and sweep call accepts a trailing `$options` array (same snake_case keys) to override the config for that call.

## Permissions and Info.plist

**Android** (added by the plugin): `INTERNET`, `ACCESS_NETWORK_STATE`, `ACCESS_WIFI_STATE`, `CHANGE_WIFI_MULTICAST_STATE`, `WAKE_LOCK`. A Wi-Fi lock is held only while the server or discovery is running. No runtime permission prompts.

**iOS** (added by the plugin): `NSLocalNetworkUsageDescription` with neutral wording. The first discovery or server start shows the local-network prompt. To change the wording, or to add app-wide keys, use `config/nativephp.php`, which is applied after plugin manifests:

```php
'permissions' => [
    'NSLocalNetworkUsageDescription' => 'MyApp finds nearby phones on your Wi-Fi to send and receive files.',

    // Optional, your app's choice; the plugin never sets these:
    'NSBonjourServices' => ['_myapp._tcp'],     // only if your app browses or advertises Bonjour
    'UIFileSharingEnabled' => true,             // show the app's Documents folder in the Files app
    'LSSupportsOpeningDocumentsInPlace' => true,
],
```

NativePHP writes plist booleans as strings; App Store validation wants real `<true/>`. If you set the boolean keys above, fix them in a `post_compile` hook of your own (see NativePHP's plugin hooks).

**Multicast on iOS.** Sending to a multicast group needs Apple's `com.apple.developer.networking.multicast` entitlement (request it from Apple). Without it the group fails and you get a `ServerError` event, but other devices still find the iPhone through their HTTP subnet probe, and the iPhone still answers announcements it receives with an HTTP register.

**App privacy manifest.** The plugin checks free disk space (`NSPrivacyAccessedAPICategoryDiskSpace`, reason `E174.1`) and reads file sizes of picked files (`NSPrivacyAccessedAPICategoryFileTimestamp`, `C617.1` / `3B52.1`). Declare these in your app's `PrivacyInfo.xcprivacy`.

## Usage (PHP)

```php
use Protendai\Lan\Facades\Lan;

$device = [
    'alias' => 'Tendai’s phone',
    'fingerprint' => $installId,     // random, stable per install
    'deviceModel' => 'Pixel 8',
    'deviceType' => 'mobile',
];

$port = Lan::startServer($device, storage_path('app/incoming'));   // bound port, or null
Lan::startDiscovery($device + ['port' => $port]);
```

A receive screen (EDGE `NativeComponent`; Livewire works the same with `#[OnNative]`):

```php
use Illuminate\Support\Str;
use Native\Mobile\Attributes\OnNative;
use Native\Mobile\Edge\NativeComponent;
use Protendai\Lan\Events\PeerFound;
use Protendai\Lan\Events\SessionCancelled;
use Protendai\Lan\Events\UploadComplete;
use Protendai\Lan\Events\UploadProgress;
use Protendai\Lan\Events\UploadRequested;
use Protendai\Lan\Facades\Lan;

class Receive extends NativeComponent
{
    public array $pending = [];

    #[OnNative(PeerFound::class)]
    public function onPeerFound(?string $alias = null, ?string $fingerprint = null, ?string $ip = null, ?int $port = null): void
    {
        // Remember where each fingerprint was last seen (used for auto-accept below).
        Peer::updateOrCreate(['fingerprint' => $fingerprint], ['alias' => $alias, 'ip' => $ip, 'port' => $port, 'last_seen_at' => now()]);
    }

    #[OnNative(UploadRequested::class)]
    public function onUploadRequested(?string $requestId = null, array $sender = [], array $files = [], ?string $pinProvided = null, ?string $remoteIp = null): void
    {
        if ($this->pinIsSet() && $pinProvided !== $this->pin()) {
            Lan::decline($requestId, 401);   // the sender asks its user for the PIN

            return;
        }

        if ($this->pending !== []) {
            Lan::decline($requestId, 409);   // busy with another request

            return;
        }

        $this->pending = compact('requestId', 'sender', 'files', 'remoteIp');

        if (Peer::trustedAt($sender['fingerprint'] ?? null, $remoteIp)) {
            $this->accept();                  // see "Security" below
        }
    }

    public function accept(): void
    {
        $sessionId = (string) Str::uuid();
        $ids = array_column($this->pending['files'], 'id');

        if (! Lan::accept($this->pending['requestId'], $ids, $sessionId)) {
            // Too late (timed out / withdrawn) or not enough storage.
        }

        $this->pending = [];
    }

    #[OnNative(UploadProgress::class)]
    public function onProgress(?string $sessionId = null, ?string $fileId = null, int $bytesReceived = 0, int $bytesTotal = 0): void {}

    #[OnNative(UploadComplete::class)]
    public function onComplete(?string $sessionId = null, ?string $fileId = null, ?string $path = null): void
    {
        // $path is in {incomingDir}/{sessionId}/; move it somewhere permanent.
    }

    #[OnNative(SessionCancelled::class)]
    public function onCancelled(?string $sessionId = null, ?string $reason = null, ?string $requestId = null): void
    {
        if ($requestId !== null && ($this->pending['requestId'] ?? null) === $requestId) {
            $this->pending = [];   // the sender withdrew, or the request timed out ($reason === 'timeout')
        }
    }
}
```

Declare every handler parameter optional with a default: payloads from older native builds may not carry newer keys.

### Sending (from PHP)

```php
$base = "http://{$peer->ip}:{$peer->port}".config('lan.api_prefix');

$prepare = Http::timeout(config('lan.prepare_timeout') + 5)->post("$base/prepare-upload", [
    'info' => Lan::deviceInfo($device),
    'files' => ['f1' => ['id' => 'f1', 'fileName' => 'photo.jpg', 'size' => filesize($path), 'fileType' => 'image/jpeg']],
]);
// 401 PIN required, 403 declined (also: no answer within prepare_timeout), 409 busy, 413 too large,
// 429 too many requests / PIN lockout, 503 receiver stopped, 507 not enough storage.
// A 200 without a sessionId comes from an older receiver that was busy: treat it like 409.

$sessionId = $prepare->json('sessionId');
$token = $prepare->json('files.f1');

Http::withBody(fopen($path, 'rb'), 'application/octet-stream')
    ->withHeaders(['Expect' => ''])
    ->post("$base/upload?".http_build_query(compact('sessionId') + ['fileId' => 'f1', 'token' => $token]));
```

## Usage (JavaScript / Inertia)

```js
import { configure, startServer, startDiscovery, respond, on, Events } from '@protendai/nativephp-lan';
// Without npm: import from 'vendor/protendai/nativephp-lan/resources/js/index.js'

configure({ serviceId: 'myapp', apiPrefix: '/api/myapp/v1', port: 50500 });   // same values as config/lan.php

const device = { alias: 'My phone', fingerprint: installId, deviceType: 'mobile' };
const port = await startServer(device, incomingDir);
await startDiscovery({ ...device, port });

const stop = on(Events.UploadRequested, async ({ requestId, files, remoteIp }) => {
    const ok = await respond(requestId, files.map((f) => f.id), crypto.randomUUID(), 200);
});
on(Events.SessionCancelled, ({ requestId, reason }) => { /* close the prompt */ });
```

Exports: `configure`, `startDiscovery`, `stopDiscovery`, `sweepSubnet`, `announce`, `startServer`, `stopServer`, `respond`, `accept`, `decline`, `cancelSession`, `localIp`, `wifiEnabled`, `pickFiles`, `pickMedia`, `thumbnail`, `openFile`, `Events`, `CancelReasons`, `on`. TypeScript definitions are in `resources/js/index.d.ts`.

## Methods

| Method | Returns | Notes |
|---|---|---|
| `startServer(array $deviceInfo, string $incomingDir, ?string $publicFolder = null, array $options = [])` | `?int` | Bound port (`deviceInfo['port']` or the configured port, else +1). `null` on failure, followed by `ServerError`. `$publicFolder` (Android): stream into Downloads/{folder}; `UploadComplete::$path` is then a `content://` URI. |
| `stopServer()` | `void` | Parked requests get 503, sessions end with `SessionCancelled(stopped)`, partial files and pending Downloads rows are removed, connections close. |
| `respond(string $requestId, array $acceptedFileIds = [], ?string $sessionId = null, int $status = 200)` | `bool` | Status goes to the sender as-is. 200 needs `$sessionId` (without it the sender gets 500 and you get `false`). `false` also when the request is gone or storage is short (sender gets 507). |
| `accept(string $requestId, array $fileIds, string $sessionId)` | `bool` | `respond()` with 200. |
| `decline(string $requestId, int $status = 403)` | `bool` | `respond()` without files. |
| `cancelSession(string $sessionId)` | `bool` | Receiver-side cancel: uploads stop, partial files go, `SessionCancelled(receiver)`. |
| `startDiscovery(array $deviceInfo, array $options = [])` | `void` | Multicast announce/listen plus HTTP probe of the /24 (configured port and +1). |
| `stopDiscovery()` | `void` | Also stops sweeps and announces in progress. |
| `sweepSubnet(array $deviceInfo, string $prefix, int $seconds = 20, array $options = [])` | `void` | Probe `prefix.2`–`prefix.254` in rounds until a device answers; `PeerFound` for the first. |
| `announce(array $deviceInfo, string $host, ?int $port = null, int $seconds = 20, array $options = [])` | `void` | POST register to `$host` until it answers 200; that host gets `PeerFound` with our address. |
| `localIp()` | `?string` | Wi-Fi IPv4 address. |
| `wifiEnabled()` | `bool` | Android radio state; always `true` on iOS. |
| `pickFiles(array $mimeTypes = ['*/*'])` | `void` | Utility. `FilesPicking`, then `FilesPicked` with copies in the cache (Android) / tmp (iOS). |
| `pickMedia()` | `void` | Utility. Photo/video picker, same events. |
| `thumbnail(string $source, string $dest, ?string $mime = null, int $size = 256)` | `bool` | Utility. JPEG preview of an image or video. |
| `openFile(string $uri, ?string $mime = null)` | `bool` | Utility. Android intent chooser; iOS Quick Look. `false` when the file is gone. |
| `config(array $options = [])`, `deviceInfo(array $deviceInfo, array $options = [])` | `array` | The resolved settings / device info sent to native code. |

`$deviceInfo` keys: `alias`, `fingerprint`, `deviceModel`, `deviceType`, `port`, `protocol` (`http`), `version`, `download`. The plugin adds `app` (service id), `port` and `protocol` when missing.

## Events

All in `Protendai\Lan\Events`.

| Event | Payload |
|---|---|
| `PeerFound` | `alias`, `fingerprint`, `ip` (the address the device was seen at, never a declared one), `port`, `protocol`, `deviceModel`, `deviceType`. Repeats with every announcement. |
| `UploadRequested` | `requestId`, `sender` (the sender's device info; `sender['ip']` is overwritten with the real address), `files` (`id`, `fileName`, `size`, `fileType`), `pinProvided` (or null), `remoteIp`. |
| `UploadProgress` | `sessionId`, `fileId`, `bytesReceived`, `bytesTotal`. At most twice a second. |
| `UploadComplete` | `sessionId`, `fileId`, `path`. |
| `SessionCancelled` | `sessionId`, or `requestId` for a request that was never answered, and `reason`: `sender` (sender cancelled or withdrew), `receiver` (`cancelSession()`), `interrupted` (connection dropped or short body), `timeout` (no `respond()` within `prepare_timeout`), `storage` (disk full), `stopped` (`stopServer()`), `error`. Constants: `SessionCancelled::TIMEOUT` etc. |
| `ServerError` | `message`. Server could not bind, listener failed, or discovery failed. |
| `FilesPicking` | `count`. |
| `FilesPicked` | `files`: list of `path`, `name`, `size`. Empty when cancelled. |

## Protocol and limits

Routes under `{api_prefix}` (one request per connection):

| Route | Purpose |
|---|---|
| `GET /info` | Device info JSON. |
| `POST /register` | Body: device info. Dispatches `PeerFound` with the caller's real address; answers with our info. |
| `POST /prepare-upload[?pin=]` | Body: `{info, files: {fileId: {id, fileName, size, fileType}}}`. Parked until `respond()`; 200 answers `{sessionId, files: {fileId: token}}`. |
| `POST /upload?sessionId&fileId&token` | Raw body. Tokens are one-shot (409 on reuse). |
| `POST /cancel?sessionId=` or `?fingerprint=` | Honoured only from the address that opened the session / sent the request. |

Enforced natively on both platforms: JSON bodies at most 1 MB (413); request headers at most 16 KB on iOS (431; NanoHTTPD caps them at 8 KB on Android); `Transfer-Encoding: chunked` bodies are rejected (501) and uploads need a `Content-Length` (411) no larger than the declared size (413) or `max_file_size`; free space is checked against the declared sizes on accept and before each upload (507), and a full disk mid-write ends the session (507, `SessionCancelled(storage)`); short or dropped uploads are deleted, never reported complete; received file names lose path separators, control characters and `.`/`..`, are cut to 255 bytes and made unique per session (`photo (2).jpg`); idle connections close after 30 s on iOS; at most `max_connections` connections and 8 parked requests (429 beyond).

## Security

- **The fingerprint is not authentication.** It is self-declared and broadcast to the whole network, so any device on the LAN can claim a fingerprint it has seen. Only skip the user's confirmation ("trusted device", auto-accept) when **both** the fingerprint is trusted **and** `remoteIp` equals the IP of a peer you discovered recently (from `PeerFound`, which always carries the observed address). When in doubt, ask the user. This narrows impersonation to an attacker who also takes over the peer's IP address; it does not prevent it.
- **PINs**: answer 401 when `pinProvided` is wrong. After `pin_max_attempts` wrong PINs from one IP the plugin answers 429 itself (with `Retry-After`) for 10 s, doubling per further failure up to 5 minutes.
- **No encryption yet**: traffic is plain HTTP. Do not rely on it for confidential files on untrusted networks.
- `/cancel` is only honoured from the address that opened the session, so other devices cannot cancel your transfers.

## Testing

The service provider registers FakeBridge macros for app tests:

```php
Native::test(Receive::class)
    ->withLocalIp('192.168.1.10')
    ->withServerPort(53531)
    ->withPendingRequests()
    ->emitNative(UploadRequested::class, ['requestId' => 'req-1', 'sender' => ['fingerprint' => 'fp'], 'files' => [], 'remoteIp' => '192.168.1.7'])
    ->assertRespondedTo('req-1', 409);
```

Also `assertDiscoveryStarted(?callable)` and `assertServerStarted(?callable)`. The plugin's own suite: `composer install && composer test`.

## Limitations

- iOS keeps received files in the app sandbox; there is no public-folder option.
- iOS reports Wi-Fi as always on (no public API).
- Discovery probes only the /24 of the Wi-Fi address and the configured port (+1).
- The pickers, thumbnails and `openFile()` are convenience utilities and may move to separate plugins in a later major version.

## Roadmap

- TLS with certificate pinning (the LocalSend model: fingerprint = certificate hash), so a fingerprint can no longer be impersonated.
- A native sender (streaming uploads from Kotlin/Swift instead of PHP's HTTP client), with progress and cancel.
- Bonjour / NSD discovery first (advertise and browse a `_service._tcp` type), with multicast and the subnet probe as fallbacks; removes the need for the iOS multicast entitlement.

## Support

Issues and questions: [github.com/protendai/nativephp-lan/issues](https://github.com/protendai/nativephp-lan/issues).

## License

MIT. See [LICENSE](LICENSE).
