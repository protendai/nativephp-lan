# Changelog

All notable changes to this project are documented in this file.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0] - 2026-10-25

First public release, extracted from an app-specific plugin and generalised.

### Added
- `config/lan.php` (publish tag `lan-config`): service id, API prefix, port, multicast group/port, prepare timeout, file size/count, connection and PIN limits. Every start/announce/sweep call accepts per-call overrides.
- `UploadRequested::$remoteIp`; `sender['ip']` is now always the address the request came from.
- `Lan::accept()`, `Lan::decline()`, `Lan::config()`, `Lan::deviceInfo()`; `respond()` and `cancelSession()` return whether native code still knew the request/session.
- `SessionCancelled` reason constants and the reasons `receiver`, `storage`, `stopped`, `error`.
- JavaScript library (`resources/js`, `@protendai/nativephp-lan`) with TypeScript definitions.
- FakeBridge macros `withServerPort()`, `withPendingRequests()`, `assertDiscoveryStarted()`, `assertServerStarted()`; Boost guidelines; Pest suite.

### Changed
- Package `protendai/nativephp-lan`, namespace `Protendai\Lan`, Kotlin package `com.protendai.lan`, native sources under `resources/android/src` and `resources/ios/Sources`.
- No app-specific defaults: neutral service id, route prefix, port and multicast group; neutral Info.plist wording; no app folders.
- The plugin no longer sets `UIFileSharingEnabled`, `LSSupportsOpeningDocumentsInPlace` or `NSBonjourServices`, and no longer ships a privacy manifest or `post_compile` hook; these are app settings (see README).
- Android `min_version` raised from 26 to 29, the API level the code really needs; iOS `min_version` set to 15.0.
- `startServer()` no longer takes the unused `$certPem` / `$keyPem` arguments; `$publicFolder` is the third argument.

### Removed
- `Lan::setAppearance()` and `Lan::wakeQueue()` (app concerns, not LAN transfer).
- `PeerLost` event (it was never dispatched).

### Fixed
- Any status from `respond()` (409 busy, 429, 5xx...) now reaches the sender; it was turned into an empty 200. A 200 without a session id answers 500.
- iOS stored interrupted uploads as complete; short or dropped uploads are now deleted on both platforms and end the session with `SessionCancelled(interrupted)`.
- Unanswered requests now dispatch `SessionCancelled(requestId, reason: timeout)`; a late `respond()` returns false instead of silently doing nothing.
- iOS receive server: 16 KB header limit (431), 1 MB JSON limit (413), 30 s idle timeout, connection cap, and parked requests no longer block a GCD thread on a semaphore for up to 60 s.
- iOS: `FileHandle.write` no longer crashes on a full disk (507, `SessionCancelled(storage)`); a missing file handle answers 500; free space is checked against the declared sizes.
- Upload bodies larger than declared (or than `max_file_size`) are refused (413) on both platforms; chunked bodies are refused (501) and uploads need a Content-Length (411).
- Files with the same name in one session no longer overwrite each other; names are sanitised (`.`, `..`, separators, control characters, 255 bytes) on both platforms.
- Upload tokens are one-shot (409 on reuse).
- Per-IP PIN backoff in native code (429 with Retry-After).
- `/cancel` is only honoured from the session's address; cancel by fingerprint was added to iOS.
- Android device info is replaced as an immutable snapshot instead of being mutated across threads; iOS device info is lock-protected.
- `stopServer()` answers parked requests 503, closes live connections, deletes partial files and pending MediaStore rows, and reports `SessionCancelled(stopped)`.
- Android Wi-Fi lock is released when the server and discovery stop (it was held forever).
- Discovery start/stop race on Android (a socket opened after stop kept running), sweeps and announces that could not be stopped, unsynchronised "found" flag.
- HTTP probe responses are capped at 64 KB on both platforms.
- iOS query strings with `=` or `+` in values are decoded correctly.
- iOS multicast group failures are reported as `ServerError`.
- Android `OpenFile` catches exceptions inside the UI-thread lambda; the activity is held by a weak reference.
- The register route ignores a self-declared `ip` and uses the caller's address.
