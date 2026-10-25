/**
 * protendai/nativephp-lan: JavaScript bindings for Inertia (Vue/React) and
 * other SPA front ends. Each function calls one native bridge function;
 * results and progress arrive as native events (see `Events` and `on()`).
 *
 * PHP reads protocol settings from config/lan.php. JavaScript cannot, so
 * call `configure()` once with the same values (camelCase) before starting
 * discovery or the server, or pass `config` per call.
 *
 * @module @protendai/nativephp-lan
 */

const BRIDGE_URL = '/_native/api/call';

/** @type {LanConfig} */
const DEFAULT_CONFIG = {
    serviceId: 'nativephp-lan',
    apiPrefix: '/api/nativephp-lan/v1',
    port: 53530,
    multicastGroup: '224.0.0.170',
    multicastPort: 53530,
    prepareTimeout: 60,
    maxFileSize: 0,
    maxFiles: 1000,
    maxConnections: 32,
    pinMaxAttempts: 3,
};

let currentConfig = { ...DEFAULT_CONFIG };

/**
 * @typedef {Object} LanConfig
 * @property {string} serviceId      "app" marker every device of your app announces.
 * @property {string} apiPrefix      Route prefix of the receive server.
 * @property {number} port           Receive server port (port + 1 when busy).
 * @property {string} multicastGroup UDP multicast group for announcements.
 * @property {number} multicastPort  UDP multicast port.
 * @property {number} prepareTimeout Seconds a send request waits for respond().
 * @property {number} maxFileSize    Largest file in bytes, 0 = no limit.
 * @property {number} maxFiles       Most files per send request.
 * @property {number} maxConnections Most simultaneous connections.
 * @property {number} pinMaxAttempts Wrong PINs per IP before a lockout.
 */

/**
 * Set the protocol settings used by every later call (merged over the defaults).
 * Use the same values as config/lan.php.
 *
 * @param {Partial<LanConfig>} config
 * @returns {LanConfig}
 */
export function configure(config = {}) {
    currentConfig = { ...DEFAULT_CONFIG, ...currentConfig, ...config };
    return { ...currentConfig };
}

/**
 * Call a native bridge function and return its data.
 *
 * @param {string} method
 * @param {Object} [params]
 * @returns {Promise<any>}
 */
async function bridgeCall(method, params = {}) {
    const response = await fetch(BRIDGE_URL, {
        method: 'POST',
        headers: {
            'Content-Type': 'application/json',
            'X-CSRF-TOKEN': (typeof document !== 'undefined' && document.querySelector('meta[name="csrf-token"]')?.content) || '',
        },
        body: JSON.stringify({ method, params }),
    });

    const result = await response.json();

    if (result && result.status === 'error') {
        throw new Error(result.message || `${method} failed`);
    }

    return result && typeof result === 'object' && 'data' in result ? result.data : result;
}

/** @param {Object} deviceInfo @param {LanConfig} config */
function withDefaults(deviceInfo, config) {
    return { app: config.serviceId, port: config.port, protocol: 'http', ...deviceInfo };
}

/** @param {Partial<LanConfig>} [overrides] @returns {LanConfig} */
function resolveConfig(overrides = {}) {
    return { ...currentConfig, ...overrides };
}

// ── Discovery ────────────────────────────────────────────────

/**
 * Announce this device, listen for others and probe the /24. Devices arrive as `Events.PeerFound`.
 *
 * @param {Object} deviceInfo  { alias, fingerprint, deviceModel, deviceType, ... }
 * @param {Partial<LanConfig>} [config]
 */
export async function startDiscovery(deviceInfo, config = {}) {
    const resolved = resolveConfig(config);
    return bridgeCall('Lan.StartDiscovery', { deviceInfo: withDefaults(deviceInfo, resolved), config: resolved });
}

/** Stop discovery, sweeps and announces. */
export async function stopDiscovery() {
    return bridgeCall('Lan.StopDiscovery');
}

/**
 * Probe one /24 (e.g. "192.168.49") until a device of this service answers or `seconds` pass.
 *
 * @param {Object} deviceInfo
 * @param {string} prefix
 * @param {number} [seconds=20]
 * @param {Partial<LanConfig>} [config]
 */
export async function sweepSubnet(deviceInfo, prefix, seconds = 20, config = {}) {
    const resolved = resolveConfig(config);
    return bridgeCall('Lan.SweepSubnet', { deviceInfo: withDefaults(deviceInfo, resolved), prefix, seconds, config: resolved });
}

/**
 * POST this device's info to a receive server until it answers, so it learns our address.
 *
 * @param {Object} deviceInfo
 * @param {string} host
 * @param {number} [port]  Defaults to the configured port.
 * @param {number} [seconds=20]
 * @param {Partial<LanConfig>} [config]
 */
export async function announce(deviceInfo, host, port, seconds = 20, config = {}) {
    const resolved = resolveConfig(config);
    return bridgeCall('Lan.Announce', {
        deviceInfo: withDefaults(deviceInfo, resolved),
        host,
        port: port ?? resolved.port,
        seconds,
        config: resolved,
    });
}

// ── Receive server ───────────────────────────────────────────

/**
 * Start the receive server.
 *
 * @param {Object} deviceInfo
 * @param {string} incomingDir   Absolute directory for received files.
 * @param {string|null} [publicFolder]  Android: stream into Downloads/{publicFolder} instead.
 * @param {Partial<LanConfig>} [config]
 * @returns {Promise<number|null>} The bound port, or null when the server failed to start.
 */
export async function startServer(deviceInfo, incomingDir, publicFolder = null, config = {}) {
    const resolved = resolveConfig(config);
    const info = withDefaults(deviceInfo, resolved);
    const result = await bridgeCall('Lan.StartServer', { deviceInfo: info, incomingDir, publicFolder, config: resolved });
    return result && result.ok ? Number(result.port ?? info.port) : null;
}

/** Stop the receive server (parked requests get 503, partial files are removed). */
export async function stopServer() {
    return bridgeCall('Lan.StopServer');
}

/**
 * Answer a send request (`Events.UploadRequested`). 200 accepts `acceptedFileIds` into `sessionId`.
 *
 * @param {string} requestId
 * @param {string[]} [acceptedFileIds]
 * @param {string|null} [sessionId]
 * @param {number} [status=200]
 * @returns {Promise<boolean>} false when the request is gone or the answer was unusable.
 */
export async function respond(requestId, acceptedFileIds = [], sessionId = null, status = 200) {
    const result = await bridgeCall('Lan.Respond', { requestId, acceptedFileIds, sessionId, status });
    return Boolean(result && result.ok);
}

/** respond() with 200. */
export async function accept(requestId, fileIds, sessionId) {
    return respond(requestId, fileIds, sessionId, 200);
}

/** respond() without files: 403 by default (401 PIN, 409 busy, 429 slow down). */
export async function decline(requestId, status = 403) {
    return respond(requestId, [], null, status);
}

/**
 * Cancel a session from the receiving side.
 *
 * @param {string} sessionId
 * @returns {Promise<boolean>}
 */
export async function cancelSession(sessionId) {
    const result = await bridgeCall('Lan.CancelSession', { sessionId });
    return Boolean(result && result.ok);
}

// ── Network info ─────────────────────────────────────────────

/** @returns {Promise<string|null>} The device's LAN IPv4 address. */
export async function localIp() {
    const result = await bridgeCall('Lan.LocalIp');
    return result && result.ip ? result.ip : null;
}

/** @returns {Promise<boolean>} Whether the Wi-Fi radio is on (always true on iOS). */
export async function wifiEnabled() {
    const result = await bridgeCall('Lan.WifiEnabled');
    return result && 'enabled' in result ? Boolean(result.enabled) : true;
}

// ── Utilities ────────────────────────────────────────────────

/**
 * Multi-select document picker. Answers with `Events.FilesPicking` then `Events.FilesPicked`.
 *
 * @param {string[]} [mimeTypes=['*\/*']]
 */
export async function pickFiles(mimeTypes = ['*/*']) {
    return bridgeCall('Lan.PickFiles', { mimeTypes });
}

/** Multi-select photo/video picker. Same events as pickFiles(). */
export async function pickMedia() {
    return bridgeCall('Lan.PickMedia');
}

/**
 * Write a JPEG preview of an image or video to `dest`.
 *
 * @param {string} source  File path, or Android content:// URI.
 * @param {string} dest
 * @param {string|null} [mime]
 * @param {number} [size=256]
 * @returns {Promise<boolean>}
 */
export async function thumbnail(source, dest, mime = null, size = 256) {
    const result = await bridgeCall('Lan.Thumbnail', { source, dest, mime, size });
    return Boolean(result && result.ok);
}

/**
 * Open a received file in the system viewer.
 *
 * @param {string} uri  Android content:// URI, or a file path (iOS Quick Look).
 * @param {string|null} [mime]
 * @returns {Promise<boolean>}
 */
export async function openFile(uri, mime = null) {
    const result = await bridgeCall('Lan.OpenFile', { uri, mime });
    return Boolean(result && result.ok);
}

// ── Events ───────────────────────────────────────────────────

/** Event class names, as delivered in the `native-event` DOM event. */
export const Events = Object.freeze({
    PeerFound: 'Protendai\\Lan\\Events\\PeerFound',
    UploadRequested: 'Protendai\\Lan\\Events\\UploadRequested',
    UploadProgress: 'Protendai\\Lan\\Events\\UploadProgress',
    UploadComplete: 'Protendai\\Lan\\Events\\UploadComplete',
    SessionCancelled: 'Protendai\\Lan\\Events\\SessionCancelled',
    ServerError: 'Protendai\\Lan\\Events\\ServerError',
    FilesPicking: 'Protendai\\Lan\\Events\\FilesPicking',
    FilesPicked: 'Protendai\\Lan\\Events\\FilesPicked',
});

/** SessionCancelled reasons. */
export const CancelReasons = Object.freeze({
    SENDER: 'sender',
    RECEIVER: 'receiver',
    INTERRUPTED: 'interrupted',
    TIMEOUT: 'timeout',
    STORAGE: 'storage',
    STOPPED: 'stopped',
    ERROR: 'error',
});

/**
 * Listen for one of this plugin's events. Same mechanism as `On()` from
 * `@nativephp/mobile` (the `native-event` DOM event).
 *
 * @param {string} eventName  One of `Events`.
 * @param {(payload: Object, eventName: string) => void} callback
 * @returns {() => void} Call to stop listening.
 */
export function on(eventName, callback) {
    const listener = (e) => {
        const name = String(e.detail?.event ?? '').replace(/^\\+/, '');
        if (name === eventName) {
            callback(e.detail.payload, name);
        }
    };
    document.addEventListener('native-event', listener);
    return () => document.removeEventListener('native-event', listener);
}
