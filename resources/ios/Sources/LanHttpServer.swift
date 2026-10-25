import Foundation
import Network

/// The receiving half of the Tumira LAN protocol, served over a hand-rolled HTTP/1.1
/// listener (NWListener). JSON routes buffer their small bodies; the upload
/// route streams straight to disk. Only metadata and progress cross back to
/// PHP as events.
///
/// NOTE: unverified from this environment — validate on a Mac before shipping.
final class LanHttpServer {

    private let listener: NWListener
    private let manager: LanManager
    private let queue = DispatchQueue(label: "com.tuma.lan.http")

    init(port: UInt16, manager: LanManager) throws {
        self.manager = manager
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw NSError(domain: "tuma.lan", code: 1, userInfo: [NSLocalizedDescriptionKey: "bad port"])
        }
        listener = try NWListener(using: params, on: nwPort)
    }

    /// Start listening and wait (briefly) for the bind to succeed or fail, so
    /// "address in use" surfaces here and the caller can fall back to another port.
    func start() throws {
        listener.newConnectionHandler = { [weak self] connection in
            guard let self = self else { return }
            // Own queue per connection: prepare-upload blocks while the user decides,
            // and must not stall other requests (cancel, other senders).
            connection.start(queue: DispatchQueue(label: "com.tuma.lan.http.conn"))
            HttpConnection(connection: connection, manager: self.manager).begin()
        }

        let settled = DispatchSemaphore(value: 0)
        var failure: Error?
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                settled.signal()
            case .failed(let error):
                failure = error
                settled.signal()
            default:
                break
            }
        }
        listener.start(queue: queue)

        if settled.wait(timeout: .now() + 3) == .timedOut {
            listener.cancel()
            throw NSError(domain: "tuma.lan", code: 2, userInfo: [NSLocalizedDescriptionKey: "listener did not start"])
        }
        if let failure = failure {
            listener.cancel()
            throw failure
        }
        listener.stateUpdateHandler = nil
    }

    func stop() {
        listener.cancel()
    }
}

/// One request/response cycle. Accumulates bytes until the header block is
/// complete, then routes. The upload route keeps draining the body to a file.
private final class HttpConnection {

    private let connection: NWConnection
    private let manager: LanManager
    private let apiPrefix = "/api/tumira/v1/"

    private var buffer = Data()
    private var headersParsed = false
    private var method = ""
    private var path = ""
    private var query: [String: String] = [:]
    private var headers: [String: String] = [:]
    private var contentLength = 0

    // Upload streaming state
    private var uploadHandle: FileHandle?
    private var uploadSessionId = ""
    private var uploadFileId = ""
    private var uploadDestination = ""
    private var uploadReceived = 0
    private var lastEmit: TimeInterval = 0

    init(connection: NWConnection, manager: LanManager) {
        self.connection = connection
        self.manager = manager
    }

    /// Nothing else holds a connection handler, so keep it alive here until
    /// close(); without this it was freed at once and requests got no answer.
    private static var live: [ObjectIdentifier: HttpConnection] = [:]
    private static let liveLock = NSLock()

    func begin() {
        HttpConnection.liveLock.lock()
        HttpConnection.live[ObjectIdentifier(self)] = self
        HttpConnection.liveLock.unlock()
        receive()
    }

    private func close() {
        connection.cancel()
        HttpConnection.liveLock.lock()
        HttpConnection.live.removeValue(forKey: ObjectIdentifier(self))
        HttpConnection.liveLock.unlock()
    }

    /// Reads until the headers are in; after that only the upload route keeps
    /// reading here (other routes read their body via bufferBody, and two
    /// concurrent receives would split the bytes between them).
    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
            if let data = data, !data.isEmpty {
                self.onData(data)
            }
            if isComplete || error != nil {
                self.finishUploadIfStreaming()
                self.close()
                return
            }
            if !self.headersParsed || self.uploadHandle != nil {
                self.receive()
            }
        }
    }

    private func onData(_ data: Data) {
        if uploadHandle != nil {
            writeUploadChunk(data)
            return
        }

        buffer.append(data)

        if !headersParsed {
            guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else { return }
            let headerData = buffer.subdata(in: buffer.startIndex..<headerEnd.lowerBound)
            parseHeaders(headerData)
            headersParsed = true

            let bodyStart = headerEnd.upperBound
            let remainder = buffer.subdata(in: bodyStart..<buffer.endIndex)
            buffer.removeAll(keepingCapacity: false)
            route(initialBody: remainder)
        }
    }

    private func parseHeaders(_ data: Data) {
        let text = String(decoding: data, as: UTF8.self)
        let lines = text.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return }

        let parts = requestLine.components(separatedBy: " ")
        if parts.count >= 2 {
            method = parts[0].uppercased()
            let target = parts[1]
            if let q = target.firstIndex(of: "?") {
                path = String(target[..<q])
                query = HttpConnection.parseQuery(String(target[target.index(after: q)...]))
            } else {
                path = target
            }
        }

        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }
        contentLength = Int(headers["content-length"] ?? "0") ?? 0
    }

    private func route(initialBody: Data) {
        let normalized = path.hasSuffix("/") ? String(path.dropLast()) : path

        switch normalized {
        case endpoint("info"):
            respondJson(200, manager.deviceInfoJson())
        case endpoint("register"):
            bufferBody(initialBody) { body in
                if var json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                   (json["app"] as? String) == "tumira" {
                    // The caller's address as we see it (a phone that joined a pairing code announces itself this way).
                    if (json["ip"] as? String ?? "").isEmpty, case let .hostPort(host, _) = self.connection.endpoint {
                        json["ip"] = "\(host)".components(separatedBy: "%").first ?? "\(host)"
                    }
                    self.manager.emitPeerFound(json)
                }
                self.respondJson(200, self.manager.deviceInfoJson())
            }
        case endpoint("prepare-upload"):
            bufferBody(initialBody) { body in self.handlePrepareUpload(body) }
        case endpoint("upload"):
            startUpload(initialBody: initialBody)
        case endpoint("cancel"):
            if let sessionId = query["sessionId"] { self.manager.cancelSession(sessionId: sessionId, reason: "sender") }
            respondJson(200, [:])
        default:
            respondJson(404, ["message": "Not found"])
        }
    }

    // ── prepare-upload ───────────────────────────────────────────

    private func handlePrepareUpload(_ body: Data) {
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        let sender = json["info"] as? [String: Any] ?? [:]
        let filesMap = json["files"] as? [String: Any] ?? [:]
        let files = filesMap.values.compactMap { $0 as? [String: Any] }
        let pin = query["pin"]

        let request = manager.parkUploadRequest(sender: sender, files: files, pinProvided: pin)
        // Blocking wait is fine: this runs on the listener queue per-connection.
        let answered = request.await()
        manager.completePending(request.requestId)

        if !answered || request.status == 403 {
            respondJson(403, ["message": "declined"]); return
        }
        if request.status == 401 { respondJson(401, ["message": "PIN required"]); return }
        if request.status == 429 { respondJson(429, ["message": "Too many requests"]); return }

        respondJson(200, ["sessionId": request.sessionId ?? "", "files": request.tokens])
    }

    // ── upload streaming ─────────────────────────────────────────

    private func startUpload(initialBody: Data) {
        let sessionId = query["sessionId"]
        let fileId = query["fileId"]
        let token = query["token"]

        guard manager.validToken(sessionId: sessionId, fileId: fileId, token: token),
              let sessionId = sessionId, let fileId = fileId,
              let dir = manager.incomingDirectory(),
              let name = manager.fileName(sessionId: sessionId, fileId: fileId) else {
            respondJson(403, ["message": "invalid token"]); return
        }

        let sessionDir = (dir as NSString).appendingPathComponent(sessionId)
        try? FileManager.default.createDirectory(atPath: sessionDir, withIntermediateDirectories: true)
        let destination = (sessionDir as NSString).appendingPathComponent(name)
        FileManager.default.createFile(atPath: destination, contents: nil)

        uploadHandle = FileHandle(forWritingAtPath: destination)
        uploadSessionId = sessionId
        uploadFileId = fileId
        uploadDestination = destination
        uploadReceived = 0

        if !initialBody.isEmpty { writeUploadChunk(initialBody) }
        // Body with no Content-Length or already fully delivered: finish now.
        if contentLength > 0 && uploadReceived >= contentLength { finishUploadIfStreaming() }
    }

    private func writeUploadChunk(_ data: Data) {
        uploadHandle?.write(data)
        uploadReceived += data.count

        let now = Date().timeIntervalSince1970
        if now - lastEmit >= 0.25 {
            manager.emitProgress(sessionId: uploadSessionId, fileId: uploadFileId,
                                 received: uploadReceived, total: contentLength > 0 ? contentLength : uploadReceived)
            lastEmit = now
        }

        if contentLength > 0 && uploadReceived >= contentLength { finishUploadIfStreaming() }
    }

    private func finishUploadIfStreaming() {
        guard uploadHandle != nil else { return }
        uploadHandle?.closeFile()
        uploadHandle = nil

        manager.emitProgress(sessionId: uploadSessionId, fileId: uploadFileId,
                             received: uploadReceived, total: contentLength > 0 ? contentLength : uploadReceived)
        manager.emitComplete(sessionId: uploadSessionId, fileId: uploadFileId, path: uploadDestination)
        respondJson(200, [:])
    }

    // ── helpers ──────────────────────────────────────────────────

    private func bufferBody(_ initial: Data, _ done: @escaping (Data) -> Void) {
        var body = initial
        if body.count >= contentLength { done(body); return }

        func pump() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
                if let data = data { body.append(data) }
                if body.count >= self.contentLength || isComplete || error != nil {
                    done(body)
                } else {
                    pump()
                }
            }
        }
        pump()
    }

    private func endpoint(_ name: String) -> String {
        let full = apiPrefix + name
        return full.hasSuffix("/") ? String(full.dropLast()) : full
    }

    private func respondJson(_ code: Int, _ body: [String: Any]) {
        let json = (try? JSONSerialization.data(withJSONObject: body)) ?? Data("{}".utf8)
        let head = "HTTP/1.1 \(code) \(HttpConnection.reason(code))\r\n" +
            "Content-Type: application/json\r\n" +
            "Content-Length: \(json.count)\r\n" +
            "Connection: close\r\n\r\n"
        var response = Data(head.utf8)
        response.append(json)
        connection.send(content: response, completion: .contentProcessed { _ in
            self.close()
        })
    }

    private static func parseQuery(_ string: String) -> [String: String] {
        var result: [String: String] = [:]
        for pair in string.components(separatedBy: "&") {
            let kv = pair.components(separatedBy: "=")
            if kv.count == 2 {
                let key = kv[0].removingPercentEncoding ?? kv[0]
                let value = kv[1].removingPercentEncoding ?? kv[1]
                result[key] = value
            }
        }
        return result
    }

    private static func reason(_ code: Int) -> String {
        switch code {
        case 200: return "OK"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 429: return "Too Many Requests"
        default: return "Error"
        }
    }
}
