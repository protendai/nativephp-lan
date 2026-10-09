import AVFoundation
import Foundation
import Network
import UIKit

// MARK: - Bridge functions
//
// Namespace: "Lan.*". Each function is thin; LanManager owns the multicast
// discovery loop and the receive HTTP server, both off the PHP UI thread.
// Results and progress return to PHP as events under Tuma\Lan\Events\*.
//
// NOTE: This iOS implementation mirrors the Android one and follows the
// documented BridgeFunction / LaravelBridge patterns, but it has NOT been
// compiled or run on a device from this environment. Verify on a Mac
// (Xcode 26 / iOS 18+) before shipping.

enum LanFunctions {

    class StartDiscovery: BridgeFunction {
        func execute(parameters: [String: Any]) throws -> [String: Any] {
            LanManager.shared.startDiscovery(deviceInfo: parameters["deviceInfo"] as? [String: Any] ?? [:])
            return BridgeResponse.success(data: ["ok": true])
        }
    }

    /// Write a small JPEG preview of an image or video file to `dest`.
    class Thumbnail: BridgeFunction {
        func execute(parameters: [String: Any]) throws -> [String: Any] {
            guard let source = parameters["source"] as? String,
                  let dest = parameters["dest"] as? String else {
                return BridgeResponse.success(data: ["ok": false])
            }
            let mime = parameters["mime"] as? String ?? ""
            let edge = CGFloat((parameters["size"] as? NSNumber)?.doubleValue ?? 256)
            let target = CGSize(width: edge, height: edge)

            var image: UIImage?
            if mime.hasPrefix("video/") {
                let generator = AVAssetImageGenerator(asset: AVURLAsset(url: URL(fileURLWithPath: source)))
                generator.appliesPreferredTrackTransform = true
                generator.maximumSize = target
                if let frame = try? generator.copyCGImage(at: .zero, actualTime: nil) {
                    image = UIImage(cgImage: frame)
                }
            } else {
                image = UIImage(contentsOfFile: source)?.preparingThumbnail(of: target)
            }

            guard let data = image?.jpegData(compressionQuality: 0.8) else {
                return BridgeResponse.success(data: ["ok": false])
            }
            let url = URL(fileURLWithPath: dest)
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let ok = (try? data.write(to: url)) != nil
            return BridgeResponse.success(data: ["ok": ok])
        }
    }

    /// Android-only for now: the multi-select picker. iOS keeps the single-file picker.
    class PickFiles: BridgeFunction {
        func execute(parameters: [String: Any]) throws -> [String: Any] {
            return BridgeResponse.success(data: ["ok": false])
        }
    }

    /// Android-only for now: the multi-select photo/video picker.
    class PickMedia: BridgeFunction {
        func execute(parameters: [String: Any]) throws -> [String: Any] {
            return BridgeResponse.success(data: ["ok": false])
        }
    }

    /// Android-only nudge for the queue worker; nothing to do on iOS.
    class WakeQueue: BridgeFunction {
        func execute(parameters: [String: Any]) throws -> [String: Any] {
            return BridgeResponse.success(data: ["ok": false])
        }
    }

    class StopDiscovery: BridgeFunction {
        func execute(parameters: [String: Any]) throws -> [String: Any] {
            LanManager.shared.stopDiscovery()
            return BridgeResponse.success(data: ["ok": true])
        }
    }

    class StartServer: BridgeFunction {
        func execute(parameters: [String: Any]) throws -> [String: Any] {
            let info = parameters["deviceInfo"] as? [String: Any] ?? [:]
            guard let dir = parameters["incomingDir"] as? String else {
                return BridgeResponse.success(data: ["ok": false])
            }
            // publicFolder (Downloads/{folder}) is Android-only; iOS keeps files in the app sandbox.
            guard let port = LanManager.shared.startServer(deviceInfo: info, incomingDir: dir) else {
                return BridgeResponse.success(data: ["ok": false])
            }
            return BridgeResponse.success(data: ["ok": true, "port": port])
        }
    }

    class StopServer: BridgeFunction {
        func execute(parameters: [String: Any]) throws -> [String: Any] {
            LanManager.shared.stopServer()
            return BridgeResponse.success(data: ["ok": true])
        }
    }

    class Respond: BridgeFunction {
        func execute(parameters: [String: Any]) throws -> [String: Any] {
            guard let requestId = parameters["requestId"] as? String else {
                return BridgeResponse.success(data: ["ok": false])
            }
            let accepted = (parameters["acceptedFileIds"] as? [String]) ?? []
            let sessionId = parameters["sessionId"] as? String
            let status = (parameters["status"] as? Int) ?? 200
            LanManager.shared.respond(requestId: requestId, acceptedFileIds: accepted, sessionId: sessionId, status: status)
            return BridgeResponse.success(data: ["ok": true])
        }
    }

    class CancelSession: BridgeFunction {
        func execute(parameters: [String: Any]) throws -> [String: Any] {
            guard let sessionId = parameters["sessionId"] as? String else {
                return BridgeResponse.success(data: ["ok": false])
            }
            LanManager.shared.cancelSession(sessionId: sessionId, reason: "sender")
            return BridgeResponse.success(data: ["ok": true])
        }
    }

    class LocalIp: BridgeFunction {
        func execute(parameters: [String: Any]) throws -> [String: Any] {
            return BridgeResponse.success(data: ["ip": LanManager.shared.localIp() ?? ""])
        }
    }

    /// Force light or dark mode, or follow the system ("system"). iOS does not
    /// persist this, so PHP re-applies the saved choice on launch.
    class SetAppearance: BridgeFunction {
        func execute(parameters: [String: Any]) throws -> [String: Any] {
            let style: UIUserInterfaceStyle
            switch parameters["mode"] as? String {
            case "light": style = .light
            case "dark": style = .dark
            default: style = .unspecified
            }
            DispatchQueue.main.async {
                for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
                    scene.windows.forEach { $0.overrideUserInterfaceStyle = style }
                }
            }
            return BridgeResponse.success(data: ["ok": true])
        }
    }

    /// Android-only (content:// URIs). iOS received files are plain paths that
    /// PHP opens with Share::file(), so this always reports "not handled".
    class OpenFile: BridgeFunction {
        func execute(parameters: [String: Any]) throws -> [String: Any] {
            return BridgeResponse.success(data: ["ok": false])
        }
    }
}

// MARK: - LanManager

final class LanManager {
    static let shared = LanManager()
    private init() {}

    static let multicastGroup = "224.0.0.167"
    static let multicastPort: UInt16 = 53480

    private var deviceInfo: [String: Any] = [:]
    private var incomingDir: String?

    private var server: LanHttpServer?
    private var discovery: DiscoveryManager?

    private let lock = NSLock()
    private var pending: [String: PendingRequest] = [:]
    private var sessions: [String: [String: String]] = [:]      // sessionId -> fileId -> token
    private var sessionFiles: [String: [String: String]] = [:]  // sessionId -> fileId -> fileName

    // ── Discovery ────────────────────────────────────────────────

    func startDiscovery(deviceInfo: [String: Any]) {
        self.deviceInfo = deviceInfo
        stopDiscovery()
        discovery = DiscoveryManager(deviceInfo: deviceInfo, manager: self)
        discovery?.start()
    }

    func stopDiscovery() {
        discovery?.stop()
        discovery = nil
    }

    // ── Server ───────────────────────────────────────────────────

    /// Bind on the announced port, falling back to port + 1 when it is busy.
    /// Returns the bound port (also written into the served device info), or nil.
    func startServer(deviceInfo: [String: Any], incomingDir: String) -> Int? {
        self.deviceInfo = deviceInfo
        self.incomingDir = incomingDir
        try? FileManager.default.createDirectory(atPath: incomingDir, withIntermediateDirectories: true)

        let preferred = (deviceInfo["port"] as? Int) ?? 53480
        stopServer()

        var lastError: Error?
        for port in [preferred, preferred + 1] {
            do {
                let httpServer = try LanHttpServer(port: UInt16(port), manager: self)
                try httpServer.start()
                server = httpServer
                self.deviceInfo["port"] = port
                return port
            } catch {
                lastError = error
            }
        }

        dispatch("ServerError", ["message": lastError?.localizedDescription ?? "Could not start listener"])
        return nil
    }

    func stopServer() {
        server?.stop()
        server = nil
        lock.lock()
        pending.removeAll()
        sessions.removeAll()
        sessionFiles.removeAll()
        lock.unlock()
    }

    func deviceInfoJson() -> [String: Any] { deviceInfo }
    func incomingDirectory() -> String? { incomingDir }

    // ── prepare-upload parking / respond ─────────────────────────

    func parkUploadRequest(sender: [String: Any], files: [[String: Any]], pinProvided: String?) -> PendingRequest {
        let requestId = UUID().uuidString
        let request = PendingRequest(requestId: requestId, files: files)

        lock.lock()
        pending[requestId] = request
        lock.unlock()

        var payload: [String: Any] = ["requestId": requestId, "sender": sender, "files": files]
        if let pin = pinProvided { payload["pinProvided"] = pin }
        dispatch("UploadRequested", payload)

        return request
    }

    func respond(requestId: String, acceptedFileIds: [String], sessionId: String?, status: Int) {
        lock.lock()
        guard let request = pending[requestId] else { lock.unlock(); return }
        request.status = status
        request.acceptedFileIds = acceptedFileIds

        if status == 200, let sessionId = sessionId {
            var tokens: [String: String] = [:]
            var names: [String: String] = [:]
            for file in request.files {
                guard let id = file["id"] as? String, acceptedFileIds.contains(id) else { continue }
                tokens[id] = UUID().uuidString
                names[id] = LanManager.sanitize((file["fileName"] as? String) ?? id)
            }
            request.sessionId = sessionId
            request.tokens = tokens
            sessions[sessionId] = tokens
            sessionFiles[sessionId] = names
        }
        lock.unlock()

        request.semaphore.signal()
    }

    func completePending(_ requestId: String) {
        lock.lock(); pending.removeValue(forKey: requestId); lock.unlock()
    }

    func validToken(sessionId: String?, fileId: String?, token: String?) -> Bool {
        guard let sessionId = sessionId, let fileId = fileId, let token = token else { return false }
        lock.lock(); defer { lock.unlock() }
        return sessions[sessionId]?[fileId] == token
    }

    func fileName(sessionId: String, fileId: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return sessionFiles[sessionId]?[fileId]
    }

    func cancelSession(sessionId: String, reason: String) {
        lock.lock()
        sessions.removeValue(forKey: sessionId)
        sessionFiles.removeValue(forKey: sessionId)
        lock.unlock()
        if let dir = incomingDir {
            try? FileManager.default.removeItem(atPath: (dir as NSString).appendingPathComponent(sessionId))
        }
        dispatch("SessionCancelled", ["sessionId": sessionId, "reason": reason])
    }

    func emitProgress(sessionId: String, fileId: String, received: Int, total: Int) {
        dispatch("UploadProgress", ["sessionId": sessionId, "fileId": fileId, "bytesReceived": received, "bytesTotal": total])
    }

    func emitComplete(sessionId: String, fileId: String, path: String) {
        dispatch("UploadComplete", ["sessionId": sessionId, "fileId": fileId, "path": path])
    }

    func emitPeerFound(_ peer: [String: Any]) { dispatch("PeerFound", peer) }

    // ── Local IP ─────────────────────────────────────────────────

    func localIp() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        var pointer = first
        while true {
            let interface = pointer.pointee
            let family = interface.ifa_addr.pointee.sa_family
            if family == UInt8(AF_INET) {
                let name = String(cString: interface.ifa_name)
                if name == "en0" {
                    var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len),
                                &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
                    address = String(cString: host)
                }
            }
            guard let next = interface.ifa_next else { break }
            pointer = next
        }
        freeifaddrs(ifaddr)
        return address
    }

    // ── Event bridge ─────────────────────────────────────────────

    func dispatch(_ event: String, _ payload: [String: Any]) {
        DispatchQueue.main.async {
            LaravelBridge.shared.send?("Tuma\\Lan\\Events\\\(event)", payload)
        }
    }

    static func sanitize(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "file" : cleaned
    }

    /// A parked prepare-upload request, blocking its connection handler until PHP answers.
    final class PendingRequest {
        let requestId: String
        let files: [[String: Any]]
        let semaphore = DispatchSemaphore(value: 0)
        var status: Int = 403
        var acceptedFileIds: [String] = []
        var sessionId: String?
        var tokens: [String: String] = [:]

        init(requestId: String, files: [[String: Any]]) {
            self.requestId = requestId
            self.files = files
        }

        /// Wait up to 60s for PHP; on timeout the receiver replies 403.
        func await() -> Bool {
            semaphore.wait(timeout: .now() + 60) == .success
        }
    }
}
