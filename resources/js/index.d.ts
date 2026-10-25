// Type definitions for @protendai/nativephp-lan

export interface LanConfig {
    serviceId: string;
    apiPrefix: string;
    port: number;
    multicastGroup: string;
    multicastPort: number;
    prepareTimeout: number;
    maxFileSize: number;
    maxFiles: number;
    maxConnections: number;
    pinMaxAttempts: number;
}

export interface DeviceInfo {
    alias?: string;
    fingerprint?: string;
    deviceModel?: string;
    deviceType?: string;
    port?: number;
    protocol?: string;
    version?: string;
    download?: boolean;
    app?: string;
    [key: string]: unknown;
}

export interface DeclaredFile {
    id: string;
    fileName: string;
    size: number;
    fileType?: string;
    [key: string]: unknown;
}

export interface PeerFoundPayload {
    alias: string;
    fingerprint: string;
    ip: string;
    port: number;
    protocol: string;
    deviceModel: string;
    deviceType: string;
}

export interface UploadRequestedPayload {
    requestId: string;
    sender: DeviceInfo & { ip: string };
    files: DeclaredFile[];
    pinProvided?: string;
    remoteIp: string;
}

export interface UploadProgressPayload {
    sessionId: string;
    fileId: string;
    bytesReceived: number;
    bytesTotal: number;
}

export interface UploadCompletePayload {
    sessionId: string;
    fileId: string;
    path: string;
}

export type CancelReason = 'sender' | 'receiver' | 'interrupted' | 'timeout' | 'storage' | 'stopped' | 'error';

export interface SessionCancelledPayload {
    sessionId?: string;
    requestId?: string;
    reason: CancelReason;
}

export interface ServerErrorPayload {
    message: string;
}

export interface PickedFile {
    path: string;
    name: string;
    size: number;
}

export function configure(config?: Partial<LanConfig>): LanConfig;

export function startDiscovery(deviceInfo: DeviceInfo, config?: Partial<LanConfig>): Promise<unknown>;
export function stopDiscovery(): Promise<unknown>;
export function sweepSubnet(deviceInfo: DeviceInfo, prefix: string, seconds?: number, config?: Partial<LanConfig>): Promise<unknown>;
export function announce(deviceInfo: DeviceInfo, host: string, port?: number, seconds?: number, config?: Partial<LanConfig>): Promise<unknown>;

export function startServer(deviceInfo: DeviceInfo, incomingDir: string, publicFolder?: string | null, config?: Partial<LanConfig>): Promise<number | null>;
export function stopServer(): Promise<unknown>;
export function respond(requestId: string, acceptedFileIds?: string[], sessionId?: string | null, status?: number): Promise<boolean>;
export function accept(requestId: string, fileIds: string[], sessionId: string): Promise<boolean>;
export function decline(requestId: string, status?: number): Promise<boolean>;
export function cancelSession(sessionId: string): Promise<boolean>;

export function localIp(): Promise<string | null>;
export function wifiEnabled(): Promise<boolean>;

export function pickFiles(mimeTypes?: string[]): Promise<unknown>;
export function pickMedia(): Promise<unknown>;
export function thumbnail(source: string, dest: string, mime?: string | null, size?: number): Promise<boolean>;
export function openFile(uri: string, mime?: string | null): Promise<boolean>;

export const Events: {
    readonly PeerFound: 'Protendai\\Lan\\Events\\PeerFound';
    readonly UploadRequested: 'Protendai\\Lan\\Events\\UploadRequested';
    readonly UploadProgress: 'Protendai\\Lan\\Events\\UploadProgress';
    readonly UploadComplete: 'Protendai\\Lan\\Events\\UploadComplete';
    readonly SessionCancelled: 'Protendai\\Lan\\Events\\SessionCancelled';
    readonly ServerError: 'Protendai\\Lan\\Events\\ServerError';
    readonly FilesPicking: 'Protendai\\Lan\\Events\\FilesPicking';
    readonly FilesPicked: 'Protendai\\Lan\\Events\\FilesPicked';
};

export const CancelReasons: {
    readonly SENDER: 'sender';
    readonly RECEIVER: 'receiver';
    readonly INTERRUPTED: 'interrupted';
    readonly TIMEOUT: 'timeout';
    readonly STORAGE: 'storage';
    readonly STOPPED: 'stopped';
    readonly ERROR: 'error';
};

export function on(eventName: typeof Events.PeerFound, callback: (payload: PeerFoundPayload, eventName: string) => void): () => void;
export function on(eventName: typeof Events.UploadRequested, callback: (payload: UploadRequestedPayload, eventName: string) => void): () => void;
export function on(eventName: typeof Events.UploadProgress, callback: (payload: UploadProgressPayload, eventName: string) => void): () => void;
export function on(eventName: typeof Events.UploadComplete, callback: (payload: UploadCompletePayload, eventName: string) => void): () => void;
export function on(eventName: typeof Events.SessionCancelled, callback: (payload: SessionCancelledPayload, eventName: string) => void): () => void;
export function on(eventName: typeof Events.ServerError, callback: (payload: ServerErrorPayload, eventName: string) => void): () => void;
export function on(eventName: typeof Events.FilesPicking, callback: (payload: { count: number }, eventName: string) => void): () => void;
export function on(eventName: typeof Events.FilesPicked, callback: (payload: { files: PickedFile[] }, eventName: string) => void): () => void;
export function on(eventName: string, callback: (payload: any, eventName: string) => void): () => void;
