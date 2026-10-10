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
    /// Params: mimeTypes (optional). Answers with FilesPicking then FilesPicked.
    class PickFiles: BridgeFunction {
        func execute(parameters: [String: Any]) throws -> [String: Any] {
            let mimeTypes = parameters["mimeTypes"] as? [String] ?? ["*/*"]
            return BridgeResponse.success(data: ["ok": TumaPickers.shared.presentDocuments(mimeTypes: mimeTypes)])
        }
    }

    /// Multi-select photo/video picker. Answers with FilesPicking then FilesPicked.
    class PickMedia: BridgeFunction {
        func execute(parameters: [String: Any]) throws -> [String: Any] {
            return BridgeResponse.success(data: ["ok": TumaPickers.shared.presentMedia()])
        }
    }

    /// Android-only nudge for the queue worker; nothing to do on iOS.
    class WakeQueue: BridgeFunction {
        func execute(parameters: [String: Any]) throws -> [String: Any] {
            return BridgeResponse.success(data: ["ok": false])
        }
    }

    /// Params: deviceInfo, prefix ("192.168.49"), seconds. Emits PeerFound for the first Tumira device that answers.
    class SweepSubnet: BridgeFunction {
        func execute(parameters: [String: Any]) throws -> [String: Any] {
            guard let prefix = parameters["prefix"] as? String else { return BridgeResponse.success(data: ["ok": false]) }
            let info = parameters["deviceInfo"] as? [String: Any] ?? [:]
            let seconds = (parameters["seconds"] as? NSNumber)?.intValue ?? 20
            LanManager.shared.sweepSubnet(deviceInfo: info, prefix: prefix, seconds: seconds)
            return BridgeResponse.success(data: ["ok": true])
        }
    }

    /// Params: deviceInfo, host, port, seconds. POSTs register until the server answers.
    class Announce: BridgeFunction {
        func execute(parameters: [String: Any]) throws -> [String: Any] {
            guard let host = parameters["host"] as? String else { return BridgeResponse.success(data: ["ok": false]) }
            let info = parameters["deviceInfo"] as? [String: Any] ?? [:]
            let port = (parameters["port"] as? NSNumber)?.intValue ?? 53480
            let seconds = (parameters["seconds"] as? NSNumber)?.intValue ?? 20
            LanManager.shared.announce(deviceInfo: info, host: host, port: port, seconds: seconds)
            return BridgeResponse.success(data: ["ok": true])
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

    /// iOS gives apps no Wi-Fi radio state; assume on.
    class WifiEnabled: BridgeFunction {
        func execute(parameters: [String: Any]) throws -> [String: Any] {
            return BridgeResponse.success(data: ["enabled": true])
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
        LanManager.prepareFilesAppFolder()

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

    /// The Files app shows our Documents folder (UIFileSharingEnabled) as
    /// On My iPhone › Tumira. Received files go to Documents/Tumira; NativePHP
    /// extracts the Laravel app into Documents/app, which users must not see
    /// or touch, so mark it hidden (re-applied on every start, since a
    /// re-extraction recreates it).
    static func prepareFilesAppFolder() {
        let fm = FileManager.default
        guard let documents = fm.urls(for: .documentDirectory, in: .userDomainMask).first else { return }

        try? fm.createDirectory(at: documents.appendingPathComponent("Tumira", isDirectory: true), withIntermediateDirectories: true)

        for hiddenName in ["app", "app.zip", ".DS_Store"] {
            var url = documents.appendingPathComponent(hiddenName)
            guard fm.fileExists(atPath: url.path) else { continue }
            var values = URLResourceValues()
            values.isHidden = true
            try? url.setResourceValues(values)
        }
    }

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

    // ── Pairing-code helpers (mirror the Android side) ───────────

    /// One raw HTTP/1.1 exchange over TCP (no URLSession, so App Transport
    /// Security never blocks plain http to a LAN or Wi-Fi Direct address).
    static func rawHttp(host: String, port: Int, request: Data, timeout: TimeInterval, completion: @escaping (String?) -> Void) {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else { completion(nil); return }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        let queue = DispatchQueue(label: "com.tuma.lan.http.\(host)")
        var finished = false
        let finish: (String?) -> Void = { result in
            queue.async {
                if finished { return }
                finished = true
                connection.cancel()
                completion(result)
            }
        }
        var received = Data()
        func readAll() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
                if let data = data { received.append(data) }
                if isComplete || error != nil {
                    finish(String(data: received, encoding: .utf8))
                } else {
                    readAll()
                }
            }
        }
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                connection.send(content: request, completion: .contentProcessed { error in
                    if error != nil { finish(nil) } else { readAll() }
                })
            case .failed, .cancelled:
                finish(nil)
            case .waiting:
                finish(nil)
            default:
                break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + timeout) { finish(nil) }
    }

    func announce(deviceInfo: [String: Any], host: String, port: Int, seconds: Int) {
        guard let body = try? JSONSerialization.data(withJSONObject: deviceInfo) else { return }
        var request = Data("POST /api/tumira/v1/register HTTP/1.1\r\nHost: \(host):\(port)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
        request.append(body)
        let deadline = Date().addingTimeInterval(TimeInterval(seconds))

        func attempt(_ n: Int) {
            LanManager.rawHttp(host: host, port: port, request: request, timeout: 3) { response in
                if let response = response, response.hasPrefix("HTTP/1.1 200") || response.hasPrefix("HTTP/1.0 200") {
                    NSLog("TumaLan: announced to \(host):\(port) (attempt \(n))")
                    return
                }
                NSLog("TumaLan: announce to \(host):\(port) failed (attempt \(n))")
                if Date() < deadline {
                    DispatchQueue.global().asyncAfter(deadline: .now() + 1) { attempt(n + 1) }
                }
            }
        }
        attempt(1)
    }

    func sweepSubnet(deviceInfo: [String: Any], prefix: String, seconds: Int) {
        let myFingerprint = deviceInfo["fingerprint"] as? String ?? ""
        let port = (deviceInfo["port"] as? Int) ?? 53480
        let deadline = Date().addingTimeInterval(TimeInterval(seconds))
        let lock = NSLock()
        var found = false

        func round() {
            let group = DispatchGroup()
            for hostNumber in 2...254 {
                let host = "\(prefix).\(hostNumber)"
                let request = Data("GET /api/tumira/v1/info?fingerprint=\(myFingerprint) HTTP/1.1\r\nHost: \(host):\(port)\r\nConnection: close\r\n\r\n".utf8)
                group.enter()
                LanManager.rawHttp(host: host, port: port, request: request, timeout: 2) { response in
                    defer { group.leave() }
                    guard let body = response?.components(separatedBy: "\r\n\r\n").dropFirst().joined(separator: "\r\n\r\n"),
                          var info = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
                          (info["app"] as? String) == "tumira",
                          let fingerprint = info["fingerprint"] as? String, !fingerprint.isEmpty, fingerprint != myFingerprint else { return }
                    lock.lock()
                    let first = !found
                    found = true
                    lock.unlock()
                    if first {
                        info["ip"] = host
                        self.emitPeerFound(info)
                    }
                }
            }
            group.notify(queue: .global()) {
                lock.lock()
                let done = found
                lock.unlock()
                if !done && Date() < deadline {
                    DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) { round() }
                }
            }
        }
        round()
    }

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
