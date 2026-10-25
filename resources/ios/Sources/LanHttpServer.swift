import Foundation
import Network

/// The receiving half of the LAN protocol, served over a hand-rolled HTTP/1.1
/// listener (NWListener). Limits: 16 KB of headers (431), 1 MB JSON bodies
/// (413), a 30 s idle timeout, `maxConnections` simultaneous connections, and
/// upload bodies that must carry a Content-Length no larger than the size
/// declared in prepare-upload. Chunked bodies are rejected (501). One request
/// per connection ("Connection: close").
final class LanHttpServer {

    private let listener: NWListener
    private let manager: LanManager
    private let config: LanConfig
    private let queue = DispatchQueue(label: "com.protendai.lan.http")

    private let connectionsLock = NSLock()
    private var connections: [ObjectIdentifier: HttpConnection] = [:]
    private var stopped = false

    init(port: UInt16, config: LanConfig, manager: LanManager) throws {
        self.manager = manager
        self.config = config
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw NSError(domain: "nativephp.lan", code: 1, userInfo: [NSLocalizedDescriptionKey: "bad port"])
        }
        listener = try NWListener(using: params, on: nwPort)
    }

    /// Start listening and wait (briefly) for the bind to succeed or fail, so
    /// "address in use" surfaces here and the caller can fall back to another port.
    func start() throws {
        listener.newConnectionHandler = { [weak self] connection in
            guard let self = self else { connection.cancel(); return }
            self.accept(connection)
        }

        let settled = DispatchSemaphore(value: 0)
        let stateLock = NSLock()
        var failure: Error?
        var ready = false
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                stateLock.lock(); let first = !ready; ready = true; stateLock.unlock()
                if first { settled.signal() }
            case .failed(let error):
                stateLock.lock(); let starting = !ready; failure = error; ready = true; stateLock.unlock()
                if starting {
                    settled.signal()
                } else {
                    self?.manager.dispatch("ServerError", ["message": "listener: \(error.localizedDescription)"])
                }
            default:
                break
            }
        }
        listener.start(queue: queue)

        if settled.wait(timeout: .now() + 3) == .timedOut {
            listener.cancel()
            throw NSError(domain: "nativephp.lan", code: 2, userInfo: [NSLocalizedDescriptionKey: "listener did not start"])
        }
        stateLock.lock(); let error = failure; stateLock.unlock()
        if let error = error {
            listener.cancel()
            throw error
        }
    }

    private func accept(_ connection: NWConnection) {
        connectionsLock.lock()
        if stopped || connections.count >= config.maxConnections {
            connectionsLock.unlock()
            connection.cancel()
            return
        }
        let handler = HttpConnection(connection: connection, config: config, manager: manager) { [weak self] closed in
            guard let self = self else { return }
            self.connectionsLock.lock()
            self.connections.removeValue(forKey: ObjectIdentifier(closed))
            self.connectionsLock.unlock()
        }
        connections[ObjectIdentifier(handler)] = handler
        connectionsLock.unlock()
        handler.begin()
    }

    /// Stop listening and close every connection. Parked requests were already
    /// answered 503 by the manager; those replies go out before the close.
    func stop() {
        connectionsLock.lock()
        stopped = true
        let all = Array(connections.values)
        connectionsLock.unlock()

        listener.stateUpdateHandler = nil
        listener.newConnectionHandler = nil
        listener.cancel()
        all.forEach { $0.abort() }
    }
}

/// One request/response cycle. All state lives on `queue`, the queue the
/// NWConnection runs on, so callbacks never race each other.
private final class HttpConnection {

    private enum Phase {
        case headers
        case body
        case upload
        case parked
        case done
    }

    private final class Upload {
        let session: LanManager.Session
        let file: LanManager.SessionFile
        let handle: FileHandle
        let destination: String
        let total: Int64
        var received: Int64 = 0
        var lastEmit: TimeInterval = 0

        init(session: LanManager.Session, file: LanManager.SessionFile, handle: FileHandle, destination: String, total: Int64) {
            self.session = session
            self.file = file
            self.handle = handle
            self.destination = destination
            self.total = total
        }
    }

    private let connection: NWConnection
    private let config: LanConfig
    private let manager: LanManager
    private let onClose: (HttpConnection) -> Void
    private let queue = DispatchQueue(label: "com.protendai.lan.http.conn")

    private var phase = Phase.headers
    private var buffer = Data()
    private var method = ""
    private var path = ""
    private var query: [String: String] = [:]
    private var headers: [String: String] = [:]
    private var contentLength: Int64?
    private var remoteIp = ""

    private var bodyHandler: ((Data) -> Void)?
    private var upload: Upload?
    private var lastActivity = Date()
    private var idleTimer: DispatchSourceTimer?
    private var responding = false
    private var closed = false

    init(connection: NWConnection, config: LanConfig, manager: LanManager, onClose: @escaping (HttpConnection) -> Void) {
        self.connection = connection
        self.config = config
        self.manager = manager
        self.onClose = onClose
    }

    func begin() {
        remoteIp = HttpConnection.ip(of: connection.endpoint)
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.peerClosed()
            default:
                break
            }
        }
        connection.start(queue: queue)
        queue.async {
            self.startIdleTimer()
            self.receive()
        }
    }

    /// Called by the server on stop(). A reply already on its way finishes first.
    func abort() {
        queue.async {
            if self.closed || self.responding { return }
            self.discardUpload(reason: nil)
            self.close()
        }
    }

    // MARK: Reading

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
            guard let self = self, !self.closed else { return }
            if let data = data, !data.isEmpty {
                self.lastActivity = Date()
                self.onData(data)
            }
            if self.closed { return }
            if isComplete || error != nil {
                self.peerClosed()
                return
            }
            switch self.phase {
            case .headers, .body, .upload:
                self.receive()
            case .parked, .done:
                break
            }
        }
    }

    private func onData(_ data: Data) {
        switch phase {
        case .upload:
            writeUploadChunk(data)
        case .headers:
            buffer.append(data)
            guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if buffer.count > LanConfig.maxHeaderBytes { respondJson(431, ["message": "Headers too large"]) }
                return
            }
            if headerEnd.lowerBound - buffer.startIndex > LanConfig.maxHeaderBytes {
                respondJson(431, ["message": "Headers too large"])
                return
            }
            let headerData = buffer.subdata(in: buffer.startIndex..<headerEnd.lowerBound)
            let remainder = buffer.subdata(in: headerEnd.upperBound..<buffer.endIndex)
            buffer = Data()
            guard parseHeaders(headerData) else {
                respondJson(400, ["message": "Bad request"])
                return
            }
            route(initialBody: remainder)
        case .body:
            buffer.append(data)
            deliverBodyIfComplete()
        case .parked, .done:
            break
        }
    }

    /// Peer finished sending or the connection failed.
    private func peerClosed() {
        if closed { return }
        if phase == .parked { return } // the reply will fail to send and close; nothing else to do
        if let upload = upload, upload.received < upload.total {
            discardUpload(reason: "interrupted")
        }
        close()
    }

    // MARK: Parsing

    private func parseHeaders(_ data: Data) -> Bool {
        let text = String(decoding: data, as: UTF8.self)
        let lines = text.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return false }

        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2 else { return false }
        method = parts[0].uppercased()
        let target = String(parts[1])
        if let q = target.firstIndex(of: "?") {
            path = String(target[..<q])
            query = HttpConnection.parseQuery(String(target[target.index(after: q)...]))
        } else {
            path = target
        }

        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }

        if let raw = headers["content-length"] {
            guard let length = Int64(raw), length >= 0 else { return false }
            contentLength = length
        }
        return true
    }

    /// Chunked (or any other encoded) request bodies are not decoded.
    private var hasUnsupportedEncoding: Bool {
        guard let encoding = headers["transfer-encoding"]?.lowercased(), !encoding.isEmpty else { return false }
        return encoding != "identity"
    }

    // MARK: Routing

    private func route(initialBody: Data) {
        let normalized = path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path

        switch normalized {
        case config.endpoint("info"):
            respondJson(200, manager.deviceInfoJson())
        case config.endpoint("register"):
            readJsonBody(initialBody) { json in self.handleRegister(json) }
        case config.endpoint("prepare-upload"):
            let locked = manager.pinLockedSeconds(ip: remoteIp)
            if locked > 0 {
                respondJson(429, ["message": "Too many wrong PINs; retry in \(locked)s"], extraHeaders: ["Retry-After": "\(locked)"])
                return
            }
            readJsonBody(initialBody) { json in self.handlePrepareUpload(json) }
        case config.endpoint("upload"):
            startUpload(initialBody: initialBody)
        case config.endpoint("cancel"):
            if let sessionId = query["sessionId"] {
                manager.cancelFromSender(sessionId: sessionId, remoteIp: remoteIp)
            } else if let fingerprint = query["fingerprint"] {
                manager.cancelPendingFrom(fingerprint: fingerprint, remoteIp: remoteIp)
            }
            respondJson(200, [:])
        default:
            respondJson(404, ["message": "Not found"])
        }
    }

    /// Collect a JSON body of at most 1 MB, then hand it over (nil when absent or invalid).
    private func readJsonBody(_ initial: Data, _ done: @escaping ([String: Any]?) -> Void) {
        if hasUnsupportedEncoding {
            respondJson(501, ["message": "Transfer-Encoding not supported"])
            return
        }
        let length = contentLength ?? 0
        if length > Int64(LanConfig.maxJsonBytes) {
            respondJson(413, ["message": "Body too large"])
            return
        }
        bodyHandler = { data in
            done((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])
        }
        phase = .body
        buffer = initial
        deliverBodyIfComplete()
    }

    private func deliverBodyIfComplete() {
        let length = Int(contentLength ?? 0)
        guard buffer.count >= length, let handler = bodyHandler else { return }
        let body = buffer.prefix(length)
        buffer = Data()
        bodyHandler = nil
        phase = .done
        handler(Data(body))
    }

    private func handleRegister(_ json: [String: Any]?) {
        if var info = json, (info["app"] as? String) == config.serviceId,
           let fingerprint = info["fingerprint"] as? String, !fingerprint.isEmpty {
            // Only the address we see counts; a declared "ip" is ignored.
            info["ip"] = remoteIp
            manager.emitPeerFound(LanManager.peer(from: info, ip: remoteIp, config: config))
        }
        respondJson(200, manager.deviceInfoJson())
    }

    // MARK: prepare-upload

    private func handlePrepareUpload(_ json: [String: Any]?) {
        guard let json = json else { respondJson(400, ["message": "Invalid JSON"]); return }
        let sender = json["info"] as? [String: Any] ?? [:]
        let filesMap = json["files"] as? [String: Any] ?? [:]

        if filesMap.isEmpty { respondJson(400, ["message": "No files"]); return }
        if filesMap.count > config.maxFiles { respondJson(413, ["message": "Too many files"]); return }

        var files: [LanManager.DeclaredFile] = []
        for (key, value) in filesMap {
            guard let file = value as? [String: Any] else { respondJson(400, ["message": "Invalid file entry"]); return }
            guard let size = (file["size"] as? NSNumber)?.int64Value, size >= 0 else {
                respondJson(400, ["message": "Missing file size"]); return
            }
            if config.maxFileSize > 0, size > config.maxFileSize { respondJson(413, ["message": "File too large"]); return }
            let id = (file["id"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? key
            files.append(LanManager.DeclaredFile(id: id, fileName: file["fileName"] as? String ?? "", size: size, json: file))
        }

        phase = .parked
        let parked = manager.parkUploadRequest(sender: sender, files: files, pinProvided: query["pin"], remoteIp: remoteIp) { [weak self] status, body in
            guard let self = self else { return }
            self.queue.async {
                if self.closed { return }
                self.phase = .done
                self.respondJson(status, body)
            }
        }
        if !parked {
            phase = .done
            respondJson(429, ["message": "Too many pending requests"])
        }
    }

    // MARK: upload streaming

    private func startUpload(initialBody: Data) {
        if hasUnsupportedEncoding { respondJson(501, ["message": "Transfer-Encoding not supported; send Content-Length"]); return }
        guard let total = contentLength else { respondJson(411, ["message": "Content-Length required"]); return }

        let session: LanManager.Session
        let file: LanManager.SessionFile
        switch manager.claim(sessionId: query["sessionId"], fileId: query["fileId"], token: query["token"]) {
        case .invalid:
            respondJson(403, ["message": "Invalid token"]); return
        case .used:
            respondJson(409, ["message": "Token already used"]); return
        case let .ok(claimedSession, claimedFile):
            session = claimedSession
            file = claimedFile
        }

        if total > file.size { respondJson(413, ["message": "Larger than declared"]); return }
        if config.maxFileSize > 0, total > config.maxFileSize { respondJson(413, ["message": "File too large"]); return }
        guard let dir = manager.incomingDirectory() else { respondJson(500, ["message": "No destination"]); return }
        if total > LanManager.freeSpace(dir) { respondJson(507, ["message": "Not enough storage"]); return }

        let sessionDir = (dir as NSString).appendingPathComponent(session.id)
        try? FileManager.default.createDirectory(atPath: sessionDir, withIntermediateDirectories: true)
        let destination = (sessionDir as NSString).appendingPathComponent(file.name)
        guard (destination as NSString).deletingLastPathComponent == sessionDir,
              FileManager.default.createFile(atPath: destination, contents: nil),
              let handle = FileHandle(forWritingAtPath: destination) else {
            respondJson(500, ["message": "Cannot open destination"]); return
        }

        upload = Upload(session: session, file: file, handle: handle, destination: destination, total: total)
        phase = .upload

        if total == 0 {
            finishUpload()
        } else if !initialBody.isEmpty {
            writeUploadChunk(initialBody)
        }
    }

    private func writeUploadChunk(_ data: Data) {
        guard let upload = upload else { return }

        if upload.session.cancelled {
            discardUpload(reason: nil)
            respondJson(410, ["message": "Session cancelled"])
            return
        }

        let remaining = upload.total - upload.received
        let slice = Int64(data.count) > remaining ? data.prefix(Int(remaining)) : data
        do {
            try upload.handle.write(contentsOf: slice)
        } catch {
            let full = HttpConnection.isDiskFull(error)
            discardUpload(reason: full ? "storage" : "error")
            respondJson(full ? 507 : 500, ["message": full ? "Not enough storage" : "Write failed"])
            return
        }
        upload.received += Int64(slice.count)

        let now = Date().timeIntervalSince1970
        // Each progress event costs PHP a DB write and a re-render; twice a second is plenty.
        if now - upload.lastEmit >= 0.5 {
            manager.emitProgress(sessionId: upload.session.id, fileId: upload.file.id, received: upload.received, total: upload.total)
            upload.lastEmit = now
        }

        if upload.received >= upload.total { finishUpload() }
    }

    private func finishUpload() {
        guard let upload = upload else { return }
        do {
            try upload.handle.close()
        } catch {
            let full = HttpConnection.isDiskFull(error)
            discardUpload(reason: full ? "storage" : "error")
            respondJson(full ? 507 : 500, ["message": full ? "Not enough storage" : "Write failed"])
            return
        }
        self.upload = nil
        phase = .done

        if upload.session.cancelled {
            try? FileManager.default.removeItem(atPath: upload.destination)
            respondJson(410, ["message": "Session cancelled"])
            return
        }

        manager.emitProgress(sessionId: upload.session.id, fileId: upload.file.id, received: upload.received, total: upload.total)
        manager.emitComplete(sessionId: upload.session.id, fileId: upload.file.id, path: upload.destination)
        respondJson(200, [:])
    }

    /// Drop a partial upload. With a reason, the session is cancelled too (PHP hears SessionCancelled once).
    private func discardUpload(reason: String?) {
        guard let upload = upload else { return }
        self.upload = nil
        phase = .done
        try? upload.handle.close()
        try? FileManager.default.removeItem(atPath: upload.destination)
        if let reason = reason {
            manager.cancelSession(sessionId: upload.session.id, reason: reason)
        }
    }

    // MARK: Idle timeout

    private func startIdleTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in
            guard let self = self, !self.closed, !self.responding, self.phase != .parked else { return }
            if Date().timeIntervalSince(self.lastActivity) > LanConfig.idleTimeout {
                self.discardUpload(reason: "interrupted")
                self.close()
            }
        }
        timer.resume()
        idleTimer = timer
    }

    // MARK: Writing

    private func respondJson(_ code: Int, _ body: [String: Any], extraHeaders: [String: String] = [:]) {
        if closed || responding { return }
        responding = true
        phase = .done
        let json = (try? JSONSerialization.data(withJSONObject: body)) ?? Data("{}".utf8)
        var head = "HTTP/1.1 \(code) \(HttpConnection.reason(code))\r\n" +
            "Content-Type: application/json\r\n" +
            "Content-Length: \(json.count)\r\n"
        for (name, value) in extraHeaders { head += "\(name): \(value)\r\n" }
        head += "Connection: close\r\n\r\n"
        var response = Data(head.utf8)
        response.append(json)
        connection.send(content: response, completion: .contentProcessed { [weak self] _ in
            guard let self = self else { return }
            self.queue.async { self.close() }
        })
    }

    private func close() {
        if closed { return }
        closed = true
        idleTimer?.cancel()
        idleTimer = nil
        connection.stateUpdateHandler = nil
        connection.cancel()
        onClose(self)
    }

    // MARK: Helpers

    private static func ip(of endpoint: NWEndpoint) -> String {
        guard case let .hostPort(host, _) = endpoint else { return "" }
        switch host {
        case let .ipv4(address):
            return LanManager.normalizeIp("\(address)")
        case let .ipv6(address):
            return LanManager.normalizeIp("\(address)")
        case let .name(name, _):
            return LanManager.normalizeIp(name)
        @unknown default:
            return LanManager.normalizeIp("\(host)")
        }
    }

    private static func isDiskFull(_ error: Error) -> Bool {
        var current: NSError? = error as NSError
        while let ns = current {
            if ns.domain == NSCocoaErrorDomain && ns.code == NSFileWriteOutOfSpaceError { return true }
            if ns.domain == NSPOSIXErrorDomain && ns.code == Int(ENOSPC) { return true }
            current = ns.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return false
    }

    /// "a=1&b=x%3Dy&c=hello+world" -> [a: 1, b: x=y, c: hello world]. Splits on the first "=" only.
    static func parseQuery(_ string: String) -> [String: String] {
        var result: [String: String] = [:]
        for pair in string.split(separator: "&", omittingEmptySubsequences: true) {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let decode: (Substring) -> String = { raw in
                let spaced = raw.replacingOccurrences(of: "+", with: " ")
                return spaced.removingPercentEncoding ?? spaced
            }
            let key = decode(parts[0])
            if key.isEmpty { continue }
            result[key] = parts.count > 1 ? decode(parts[1]) : ""
        }
        return result
    }

    private static func reason(_ code: Int) -> String {
        switch code {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 409: return "Conflict"
        case 410: return "Gone"
        case 411: return "Length Required"
        case 413: return "Payload Too Large"
        case 429: return "Too Many Requests"
        case 431: return "Request Header Fields Too Large"
        case 500: return "Internal Server Error"
        case 501: return "Not Implemented"
        case 503: return "Service Unavailable"
        case 507: return "Insufficient Storage"
        default: return "Error"
        }
    }
}
