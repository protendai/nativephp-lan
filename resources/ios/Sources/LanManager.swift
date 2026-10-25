import Foundation
import Network

/// Owns discovery and the receive listener. Lifecycle calls are serialised by
/// `lifecycle`; request and session state is guarded by `lock` and touched
/// from the per-connection queues. Nothing here blocks a queue while PHP decides.
final class LanManager {
    static let shared = LanManager()
    private init() {}

    private static let eventNamespace = "Protendai\\Lan\\Events\\"

    /// Prepare-upload requests allowed to wait for PHP at once; more get 429.
    private static let maxPending = 8

    private let lifecycle = NSLock()
    private let lock = NSLock()
    private let timerQueue = DispatchQueue(label: "com.protendai.lan.timers")

    // Guarded by `lock`.
    private var config = LanConfig()
    private var deviceInfo: [String: Any] = [:]
    private var incomingDir: String?
    private var pending: [String: PendingRequest] = [:]
    private var sessions: [String: Session] = [:]
    private var pinGuard = PinGuard(maxAttempts: 3)
    private var discoveryGeneration = 0

    // Guarded by `lifecycle`.
    private var server: LanHttpServer?
    private var discovery: LanDiscovery?

    // MARK: Discovery

    func startDiscovery(deviceInfo: [String: Any], config: LanConfig) {
        lifecycle.lock(); defer { lifecycle.unlock() }
        stopDiscoveryLocked()
        let manager = LanDiscovery(deviceInfo: withServiceId(deviceInfo, config), config: config, manager: self)
        discovery = manager
        manager.start()
    }

    func stopDiscovery() {
        lifecycle.lock(); defer { lifecycle.unlock() }
        stopDiscoveryLocked()
    }

    private func stopDiscoveryLocked() {
        discovery?.stop()
        discovery = nil
        lock.lock(); discoveryGeneration += 1; lock.unlock()
    }

    /// Bumped by stopDiscovery(); sweeps and announces stop when it changes.
    func currentGeneration() -> Int {
        lock.lock(); defer { lock.unlock() }
        return discoveryGeneration
    }

    private func withServiceId(_ info: [String: Any], _ config: LanConfig) -> [String: Any] {
        var copy = info
        if ((copy["app"] as? String) ?? "").isEmpty { copy["app"] = config.serviceId }
        return copy
    }

    // MARK: Server

    /// Bind on the configured port, falling back to port + 1 when it is busy.
    /// Returns the bound port (also written into the served device info), or nil.
    func startServer(deviceInfo info: [String: Any], incomingDir dir: String, config cfg: LanConfig) -> Int? {
        lifecycle.lock(); defer { lifecycle.unlock() }
        stopServerLocked()

        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        var snapshot = withServiceId(info, cfg)
        let declared = LanConfig.int(snapshot["port"]) ?? cfg.port
        let preferred = (1...65534).contains(declared) ? declared : cfg.port

        lock.lock()
        config = cfg
        incomingDir = dir
        pinGuard = PinGuard(maxAttempts: cfg.pinMaxAttempts)
        lock.unlock()

        var lastError: Error?
        for port in [preferred, preferred + 1] {
            do {
                let httpServer = try LanHttpServer(port: UInt16(port), config: cfg, manager: self)
                try httpServer.start()
                server = httpServer
                snapshot["port"] = port
                lock.lock(); deviceInfo = snapshot; lock.unlock()
                return port
            } catch {
                lastError = error
            }
        }

        dispatch("ServerError", ["message": lastError?.localizedDescription ?? "Could not start listener"])
        return nil
    }

    func stopServer() {
        lifecycle.lock(); defer { lifecycle.unlock() }
        stopServerLocked()
    }

    /// Release parked requests (503), cancel live sessions (their partial files
    /// go), stop listening and close every connection.
    private func stopServerLocked() {
        lock.lock()
        let parked = Array(pending.values)
        pending.removeAll()
        let active = Array(sessions.values)
        sessions.removeAll()
        let dir = incomingDir
        lock.unlock()

        parked.forEach { $0.resolve(503, ["message": "Receiver stopped"]) }
        active.forEach { $0.cancel() }

        server?.stop()
        server = nil

        for session in active {
            if let dir = dir {
                try? FileManager.default.removeItem(atPath: (dir as NSString).appendingPathComponent(session.id))
            }
            dispatch("SessionCancelled", ["sessionId": session.id, "reason": "stopped"])
        }
    }

    /// A copy of the served device info.
    func deviceInfoJson() -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        return deviceInfo
    }

    func incomingDirectory() -> String? {
        lock.lock(); defer { lock.unlock() }
        return incomingDir
    }

    // MARK: prepare-upload parking / respond

    func pinLockedSeconds(ip: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return pinGuard.lockedSeconds(ip)
    }

    /// Park a request until PHP answers via respond() or the prepare timeout
    /// passes. `completion` runs exactly once, on an arbitrary queue. Returns
    /// false (without parking) when too many requests are already waiting.
    func parkUploadRequest(sender: [String: Any], files: [DeclaredFile], pinProvided: String?, remoteIp: String,
                           completion: @escaping (Int, [String: Any]) -> Void) -> Bool {
        let requestId = UUID().uuidString
        let request = PendingRequest(requestId: requestId, files: files, senderFingerprint: sender["fingerprint"] as? String ?? "",
                                     remoteIp: remoteIp, pinProvided: pinProvided, completion: completion)

        lock.lock()
        if pending.count >= LanManager.maxPending { lock.unlock(); return false }
        pending[requestId] = request
        let timeout = config.prepareTimeout
        lock.unlock()

        timerQueue.asyncAfter(deadline: .now() + .seconds(timeout)) { [weak self] in self?.expire(requestId) }

        // The sender's self-declared address is never trusted: report the one we see.
        var senderOut = sender
        senderOut["ip"] = remoteIp
        var payload: [String: Any] = [
            "requestId": requestId,
            "sender": senderOut,
            "files": files.map(\.json),
            "remoteIp": remoteIp,
        ]
        if let pin = pinProvided { payload["pinProvided"] = pin }
        dispatch("UploadRequested", payload)
        return true
    }

    /// PHP never answered: tell the sender 403 and PHP SessionCancelled(timeout).
    private func expire(_ requestId: String) {
        lock.lock()
        let request = pending.removeValue(forKey: requestId)
        lock.unlock()
        guard let request = request else { return }
        request.resolve(403, ["message": "timeout"])
        dispatch("SessionCancelled", ["requestId": requestId, "reason": "timeout"])
    }

    /// PHP's answer. Any status is passed to the sender as-is; 200 needs a sessionId (else the sender gets 500).
    func respond(requestId: String, acceptedFileIds: [String], sessionId: String?, status: Int) -> [String: Any] {
        lock.lock()
        guard let request = pending.removeValue(forKey: requestId) else {
            lock.unlock()
            return ["ok": false, "error": "unknown request (already answered, timed out or withdrawn)"]
        }

        if status != 200 {
            if status == 401, request.pinProvided != nil { pinGuard.failed(request.remoteIp) }
            lock.unlock()
            let code = (400...599).contains(status) ? status : 500
            request.resolve(code, ["message": LanManager.message(for: code)])
            return code == status ? ["ok": true] : ["ok": false, "error": "invalid status \(status)"]
        }

        guard let sessionId = sessionId, !sessionId.isEmpty else {
            lock.unlock()
            request.resolve(500, ["message": "Receiver error"])
            return ["ok": false, "error": "sessionId is required with status 200"]
        }

        var taken = Set<String>()
        var files: [String: SessionFile] = [:]
        let accepted = Set(acceptedFileIds)
        for file in request.files where accepted.contains(file.id) && files[file.id] == nil {
            let name = LanFileNames.unique(LanFileNames.sanitize(file.fileName.isEmpty ? file.id : file.fileName), taken: &taken)
            files[file.id] = SessionFile(id: file.id, name: name, size: file.size, token: UUID().uuidString)
        }
        let dir = incomingDir
        lock.unlock()

        let needed = files.values.reduce(Int64(0)) { $0 + $1.size }
        if needed > 0, needed > LanManager.freeSpace(dir) {
            request.resolve(507, ["message": "Not enough storage"])
            return ["ok": false, "error": "insufficient storage"]
        }

        lock.lock()
        if request.pinProvided != nil { pinGuard.succeeded(request.remoteIp) }
        sessions[sessionId] = Session(id: sessionId, senderIp: request.remoteIp, files: files)
        lock.unlock()

        request.resolve(200, ["sessionId": sessionId, "files": files.mapValues(\.token)])
        return ["ok": true]
    }

    enum Claim {
        case ok(Session, SessionFile)
        case invalid
        case used
    }

    /// Validate an upload's token and mark it used (tokens are one-shot).
    func claim(sessionId: String?, fileId: String?, token: String?) -> Claim {
        guard let sessionId = sessionId, let fileId = fileId, let token = token else { return .invalid }
        lock.lock(); defer { lock.unlock() }
        guard let session = sessions[sessionId], let file = session.files[fileId], file.token == token else { return .invalid }
        if file.used { return .used }
        file.used = true
        return .ok(session, file)
    }

    static func freeSpace(_ dir: String?) -> Int64 {
        guard let dir = dir else { return .max }
        let url = URL(fileURLWithPath: dir)
        if let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let capacity = values.volumeAvailableCapacityForImportantUsage {
            return capacity
        }
        if let attributes = try? FileManager.default.attributesOfFileSystem(forPath: dir),
           let free = attributes[.systemFreeSize] as? NSNumber {
            return free.int64Value
        }
        return .max
    }

    private static func message(for status: Int) -> String {
        switch status {
        case 401: return "PIN required"
        case 403: return "Declined"
        case 409: return "Busy"
        case 413: return "Too large"
        case 429: return "Too many requests"
        case 503: return "Unavailable"
        case 507: return "Not enough storage"
        default: return "Error"
        }
    }

    // MARK: Cancelling

    /// End a session: uploads stop at their next chunk, partial files go, PHP hears SessionCancelled once.
    @discardableResult
    func cancelSession(sessionId: String, reason: String) -> Bool {
        lock.lock()
        let session = sessions.removeValue(forKey: sessionId)
        let dir = incomingDir
        lock.unlock()
        guard let session = session else { return false }
        session.cancel()
        if let dir = dir {
            try? FileManager.default.removeItem(atPath: (dir as NSString).appendingPathComponent(sessionId))
        }
        dispatch("SessionCancelled", ["sessionId": sessionId, "reason": reason])
        return true
    }

    /// POST /cancel?sessionId=…: honoured only from the address that opened the session.
    func cancelFromSender(sessionId: String, remoteIp: String) {
        lock.lock()
        let matches = sessions[sessionId]?.senderIp == remoteIp
        lock.unlock()
        if matches { cancelSession(sessionId: sessionId, reason: "sender") }
    }

    /// POST /cancel?fingerprint=…: the sender withdrew before anyone answered (same address only).
    func cancelPendingFrom(fingerprint: String, remoteIp: String) {
        guard !fingerprint.isEmpty else { return }
        lock.lock()
        let withdrawn = pending.values.filter { $0.senderFingerprint == fingerprint && $0.remoteIp == remoteIp }
        withdrawn.forEach { pending.removeValue(forKey: $0.requestId) }
        lock.unlock()
        for request in withdrawn {
            request.resolve(403, ["message": "withdrawn"])
            dispatch("SessionCancelled", ["requestId": request.requestId, "reason": "sender"])
        }
    }

    // MARK: Events

    func emitProgress(sessionId: String, fileId: String, received: Int64, total: Int64) {
        dispatch("UploadProgress", ["sessionId": sessionId, "fileId": fileId, "bytesReceived": received, "bytesTotal": total])
    }

    func emitComplete(sessionId: String, fileId: String, path: String) {
        dispatch("UploadComplete", ["sessionId": sessionId, "fileId": fileId, "path": path])
    }

    func emitPeerFound(_ peer: [String: Any]) { dispatch("PeerFound", peer) }

    func dispatch(_ event: String, _ payload: [String: Any]) {
        DispatchQueue.main.async {
            LaravelBridge.shared.send?(LanManager.eventNamespace + event, payload)
        }
    }

    // MARK: Outbound HTTP (announce, sweeps, probes)

    /// One raw HTTP/1.1 exchange over TCP (no URLSession, so App Transport
    /// Security never blocks plain http to a LAN address). Reads at most 64 KB.
    static func rawHttp(host: String, port: Int, request: Data, timeout: TimeInterval, completion: @escaping (String?) -> Void) {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else { completion(nil); return }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        let queue = DispatchQueue(label: "com.protendai.lan.client")
        var finished = false
        var received = Data()

        let finish: (String?) -> Void = { result in
            queue.async {
                if finished { return }
                finished = true
                connection.cancel()
                completion(result)
            }
        }
        func readAll() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { data, _, isComplete, error in
                if let data = data { received.append(data) }
                if received.count >= LanConfig.maxProbeBytes {
                    finish(String(decoding: received.prefix(LanConfig.maxProbeBytes), as: UTF8.self))
                } else if isComplete || error != nil {
                    finish(String(decoding: received, as: UTF8.self))
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
            case .failed, .cancelled, .waiting:
                finish(nil)
            default:
                break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + timeout) { finish(nil) }
    }

    /// POST register to a server until it answers 200, `seconds` pass or stopDiscovery() runs.
    func announce(deviceInfo: [String: Any], host: String, port: Int, seconds: Int, config: LanConfig) {
        guard let body = try? JSONSerialization.data(withJSONObject: withServiceId(deviceInfo, config)) else { return }
        var request = Data("POST \(config.endpoint("register")) HTTP/1.1\r\nHost: \(host):\(port)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
        request.append(body)
        let deadline = Date().addingTimeInterval(TimeInterval(seconds))
        let generation = currentGeneration()

        func attempt() {
            LanManager.rawHttp(host: host, port: port, request: request, timeout: 3) { response in
                if let response = response, response.hasPrefix("HTTP/1.1 200") || response.hasPrefix("HTTP/1.0 200") { return }
                if Date() < deadline, self.currentGeneration() == generation {
                    DispatchQueue.global().asyncAfter(deadline: .now() + 1) { attempt() }
                }
            }
        }
        attempt()
    }

    /// Probe one /24 in rounds until a device of this service answers, `seconds` pass or stopDiscovery() runs.
    func sweepSubnet(deviceInfo: [String: Any], prefix: String, seconds: Int, config: LanConfig) {
        let myFingerprint = deviceInfo["fingerprint"] as? String ?? ""
        let port = config.port
        let deadline = Date().addingTimeInterval(TimeInterval(seconds))
        let generation = currentGeneration()
        let foundLock = NSLock()
        var found = false
        let path = config.endpoint("info")

        func round() {
            let group = DispatchGroup()
            for hostNumber in 2...254 {
                let host = "\(prefix).\(hostNumber)"
                let request = Data("GET \(path)?fingerprint=\(myFingerprint) HTTP/1.1\r\nHost: \(host):\(port)\r\nConnection: close\r\n\r\n".utf8)
                group.enter()
                LanManager.rawHttp(host: host, port: port, request: request, timeout: 2) { response in
                    defer { group.leave() }
                    guard self.currentGeneration() == generation,
                          let body = response?.components(separatedBy: "\r\n\r\n").dropFirst().joined(separator: "\r\n\r\n"),
                          let info = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
                          (info["app"] as? String) == config.serviceId,
                          let fingerprint = info["fingerprint"] as? String, !fingerprint.isEmpty, fingerprint != myFingerprint else { return }
                    foundLock.lock()
                    let first = !found
                    found = true
                    foundLock.unlock()
                    if first { self.emitPeerFound(LanManager.peer(from: info, ip: host, config: config)) }
                }
            }
            group.notify(queue: .global()) {
                foundLock.lock()
                let done = found
                foundLock.unlock()
                if !done, Date() < deadline, self.currentGeneration() == generation {
                    DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) { round() }
                }
            }
        }
        round()
    }

    /// The PeerFound payload for a device-info JSON seen at `ip`.
    static func peer(from info: [String: Any], ip: String, config: LanConfig) -> [String: Any] {
        return [
            "alias": info["alias"] as? String ?? "",
            "fingerprint": info["fingerprint"] as? String ?? "",
            "ip": ip,
            "port": LanConfig.int(info["port"]) ?? config.port,
            "protocol": info["protocol"] as? String ?? "http",
            "deviceModel": info["deviceModel"] as? String ?? "",
            "deviceType": info["deviceType"] as? String ?? "",
        ]
    }

    // MARK: Local IP

    func localIp() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        var pointer = first
        while true {
            let interface = pointer.pointee
            if let addr = interface.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) {
                let name = String(cString: interface.ifa_name)
                if name == "en0" {
                    var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
                    address = String(cString: host)
                }
            }
            guard let next = interface.ifa_next else { break }
            pointer = next
        }
        freeifaddrs(ifaddr)
        return address
    }

    /// "::ffff:192.168.1.5" and "fe80::1%en0" -> plain address.
    static func normalizeIp(_ raw: String) -> String {
        let ip = raw.components(separatedBy: "%").first ?? raw
        return ip.lowercased().hasPrefix("::ffff:") ? String(ip.dropFirst(7)) : ip
    }

    // MARK: Types

    /// One file as the sender declared it in prepare-upload.
    struct DeclaredFile {
        let id: String
        let fileName: String
        let size: Int64
        let json: [String: Any]
    }

    final class SessionFile {
        let id: String
        let name: String
        let size: Int64
        let token: String
        /// Guarded by LanManager.lock.
        var used = false

        init(id: String, name: String, size: Int64, token: String) {
            self.id = id
            self.name = name
            self.size = size
            self.token = token
        }
    }

    final class Session {
        let id: String
        let senderIp: String
        let files: [String: SessionFile]
        private let flagLock = NSLock()
        private var cancelledFlag = false

        init(id: String, senderIp: String, files: [String: SessionFile]) {
            self.id = id
            self.senderIp = senderIp
            self.files = files
        }

        var cancelled: Bool {
            flagLock.lock(); defer { flagLock.unlock() }
            return cancelledFlag
        }

        func cancel() {
            flagLock.lock(); cancelledFlag = true; flagLock.unlock()
        }
    }

    /// A parked prepare-upload request. Holds the connection's reply callback, never a thread.
    final class PendingRequest {
        let requestId: String
        let files: [DeclaredFile]
        let senderFingerprint: String
        let remoteIp: String
        let pinProvided: String?
        private let resolveLock = NSLock()
        private var completion: ((Int, [String: Any]) -> Void)?

        init(requestId: String, files: [DeclaredFile], senderFingerprint: String, remoteIp: String, pinProvided: String?,
             completion: @escaping (Int, [String: Any]) -> Void) {
            self.requestId = requestId
            self.files = files
            self.senderFingerprint = senderFingerprint
            self.remoteIp = remoteIp
            self.pinProvided = pinProvided
            self.completion = completion
        }

        /// Runs the reply callback once; later calls do nothing.
        func resolve(_ status: Int, _ body: [String: Any]) {
            resolveLock.lock()
            let callback = completion
            completion = nil
            resolveLock.unlock()
            callback?(status, body)
        }
    }

    /// Per-IP wrong-PIN counter: after `maxAttempts` wrong PINs the IP is locked
    /// out for 10 s, doubling per further failure up to 5 min. Guarded by LanManager.lock.
    struct PinGuard {
        let maxAttempts: Int
        private var failures: [String: Int] = [:]
        private var lockedUntil: [String: Date] = [:]

        init(maxAttempts: Int) { self.maxAttempts = maxAttempts }

        func lockedSeconds(_ ip: String) -> Int {
            guard let until = lockedUntil[ip] else { return 0 }
            let remaining = until.timeIntervalSinceNow
            return remaining > 0 ? Int(remaining.rounded(.up)) : 0
        }

        mutating func failed(_ ip: String) {
            let count = (failures[ip] ?? 0) + 1
            failures[ip] = count
            if count >= maxAttempts {
                let step = min(count - maxAttempts, 5)
                lockedUntil[ip] = Date().addingTimeInterval(min(300, 10 * pow(2, Double(step))))
            }
            if failures.count > 256, let first = failures.keys.first {
                failures.removeValue(forKey: first)
                lockedUntil.removeValue(forKey: first)
            }
        }

        mutating func succeeded(_ ip: String) {
            failures.removeValue(forKey: ip)
            lockedUntil.removeValue(forKey: ip)
        }
    }
}
