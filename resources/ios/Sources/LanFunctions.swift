import AVFoundation
import Foundation
import UIKit

// MARK: - Bridge functions
//
// Namespace: "Lan.*". Each function is thin; LanManager owns the multicast
// discovery loop and the receive HTTP server, both off the PHP thread.
// Results and progress return to PHP as events under Protendai\Lan\Events\*.
// Start calls carry a "config" object (service id, API prefix, ports,
// limits) built by the PHP facade from config/lan.php.

enum LanFunctions {

    /// Params: deviceInfo, config.
    class StartDiscovery: BridgeFunction {
        func execute(parameters: [String: Any]) throws -> [String: Any] {
            LanManager.shared.startDiscovery(deviceInfo: parameters["deviceInfo"] as? [String: Any] ?? [:],
                                             config: LanConfig(parameters["config"]))
            return BridgeResponse.success(data: ["ok": true])
        }
    }

    /// Params: deviceInfo, prefix ("192.168.49"), seconds, config. Emits PeerFound for the first device that answers.
    class SweepSubnet: BridgeFunction {
        func execute(parameters: [String: Any]) throws -> [String: Any] {
            guard let raw = parameters["prefix"] as? String else { return BridgeResponse.success(data: ["ok": false]) }
            let prefix = raw.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
            let octets = prefix.split(separator: ".")
            guard octets.count == 3, octets.allSatisfy({ UInt8($0) != nil }) else {
                return BridgeResponse.success(data: ["ok": false])
            }
            let seconds = min(max(LanConfig.int(parameters["seconds"]) ?? 20, 1), 300)
            LanManager.shared.sweepSubnet(deviceInfo: parameters["deviceInfo"] as? [String: Any] ?? [:], prefix: prefix,
                                          seconds: seconds, config: LanConfig(parameters["config"]))
            return BridgeResponse.success(data: ["ok": true])
        }
    }

    /// Params: deviceInfo, host, port, seconds, config. POSTs register until the server answers.
    class Announce: BridgeFunction {
        func execute(parameters: [String: Any]) throws -> [String: Any] {
            guard let host = parameters["host"] as? String, !host.isEmpty else { return BridgeResponse.success(data: ["ok": false]) }
            let config = LanConfig(parameters["config"])
            let port = LanConfig.int(parameters["port"]).flatMap { (1...65535).contains($0) ? $0 : nil } ?? config.port
            let seconds = min(max(LanConfig.int(parameters["seconds"]) ?? 20, 1), 300)
            LanManager.shared.announce(deviceInfo: parameters["deviceInfo"] as? [String: Any] ?? [:], host: host, port: port,
                                       seconds: seconds, config: config)
            return BridgeResponse.success(data: ["ok": true])
        }
    }

    class StopDiscovery: BridgeFunction {
        func execute(parameters: [String: Any]) throws -> [String: Any] {
            LanManager.shared.stopDiscovery()
            return BridgeResponse.success(data: ["ok": true])
        }
    }

    /// Params: deviceInfo, incomingDir, config. publicFolder is Android-only; iOS keeps files in the app sandbox.
    class StartServer: BridgeFunction {
        func execute(parameters: [String: Any]) throws -> [String: Any] {
            guard let dir = parameters["incomingDir"] as? String, !dir.isEmpty else {
                return BridgeResponse.success(data: ["ok": false])
            }
            guard let port = LanManager.shared.startServer(deviceInfo: parameters["deviceInfo"] as? [String: Any] ?? [:],
                                                           incomingDir: dir, config: LanConfig(parameters["config"])) else {
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

    /// Params: requestId, acceptedFileIds, sessionId, status. ok=false when the request is gone.
    class Respond: BridgeFunction {
        func execute(parameters: [String: Any]) throws -> [String: Any] {
            guard let requestId = parameters["requestId"] as? String else {
                return BridgeResponse.success(data: ["ok": false, "error": "requestId is required"])
            }
            let accepted = (parameters["acceptedFileIds"] as? [Any])?.compactMap { $0 as? String } ?? []
            let sessionId = parameters["sessionId"] as? String
            let status = LanConfig.int(parameters["status"]) ?? 200
            let result = LanManager.shared.respond(requestId: requestId, acceptedFileIds: accepted, sessionId: sessionId, status: status)
            return BridgeResponse.success(data: result)
        }
    }

    /// Params: sessionId. The receiving app cancels: uploads stop, partial files go, SessionCancelled(receiver).
    class CancelSession: BridgeFunction {
        func execute(parameters: [String: Any]) throws -> [String: Any] {
            guard let sessionId = parameters["sessionId"] as? String else {
                return BridgeResponse.success(data: ["ok": false])
            }
            return BridgeResponse.success(data: ["ok": LanManager.shared.cancelSession(sessionId: sessionId, reason: "receiver")])
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

    /// Utility: multi-select document picker. Answers with FilesPicking then FilesPicked.
    class PickFiles: BridgeFunction {
        func execute(parameters: [String: Any]) throws -> [String: Any] {
            let mimeTypes = (parameters["mimeTypes"] as? [Any])?.compactMap { $0 as? String } ?? ["*/*"]
            return BridgeResponse.success(data: ["ok": LanPickers.shared.presentDocuments(mimeTypes: mimeTypes)])
        }
    }

    /// Utility: multi-select photo/video picker. Answers with FilesPicking then FilesPicked.
    class PickMedia: BridgeFunction {
        func execute(parameters: [String: Any]) throws -> [String: Any] {
            return BridgeResponse.success(data: ["ok": LanPickers.shared.presentMedia()])
        }
    }

    /// Utility: write a small JPEG preview of an image or video file to `dest`.
    class Thumbnail: BridgeFunction {
        func execute(parameters: [String: Any]) throws -> [String: Any] {
            guard let source = parameters["source"] as? String,
                  let dest = parameters["dest"] as? String else {
                return BridgeResponse.success(data: ["ok": false])
            }
            let mime = parameters["mime"] as? String ?? ""
            let edge = CGFloat(min(max(LanConfig.int(parameters["size"]) ?? 256, 16), 2048))
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

    /// Utility: show a file in Quick Look, with iOS's own share button. Params: uri (a file path or file:// URL).
    class OpenFile: BridgeFunction {
        func execute(parameters: [String: Any]) throws -> [String: Any] {
            guard let uri = parameters["uri"] as? String, !uri.isEmpty else {
                return BridgeResponse.success(data: ["ok": false])
            }
            let path = uri.hasPrefix("file://") ? (URL(string: uri)?.path ?? uri) : uri
            guard FileManager.default.fileExists(atPath: path) else {
                return BridgeResponse.success(data: ["ok": false])
            }
            return BridgeResponse.success(data: ["ok": LanQuickLook.shared.present(URL(fileURLWithPath: path))])
        }
    }
}

// MARK: - Config

/// Protocol and limit settings sent by PHP with every start call. A value type:
/// a running server or discovery loop keeps the copy it was started with.
struct LanConfig {
    var serviceId = "nativephp-lan"
    var apiPrefix = "/api/nativephp-lan/v1"
    var port = 53530
    var multicastGroup = "224.0.0.170"
    var multicastPort = 53530
    var prepareTimeout = 60
    var maxFileSize: Int64 = 0
    var maxFiles = 1000
    var maxConnections = 32
    var pinMaxAttempts = 3

    static let maxJsonBytes = 1 << 20
    static let maxHeaderBytes = 16 * 1024
    static let maxProbeBytes = 64 * 1024
    static let idleTimeout: TimeInterval = 30

    init() {}

    init(_ value: Any?) {
        guard let dict = value as? [String: Any] else { return }
        if let id = (dict["serviceId"] as? String)?.trimmingCharacters(in: .whitespaces), !id.isEmpty { serviceId = id }
        if let prefix = LanConfig.normalizePrefix(dict["apiPrefix"] as? String) { apiPrefix = prefix }
        if let p = LanConfig.int(dict["port"]), (1...65534).contains(p) { port = p }
        if let group = (dict["multicastGroup"] as? String)?.trimmingCharacters(in: .whitespaces), !group.isEmpty { multicastGroup = group }
        if let p = LanConfig.int(dict["multicastPort"]), (1...65535).contains(p) { multicastPort = p }
        if let t = LanConfig.int(dict["prepareTimeout"]) { prepareTimeout = min(max(t, 5), 600) }
        if let n = dict["maxFileSize"] as? NSNumber { maxFileSize = max(n.int64Value, 0) }
        if let n = LanConfig.int(dict["maxFiles"]) { maxFiles = min(max(n, 1), 100_000) }
        if let n = LanConfig.int(dict["maxConnections"]) { maxConnections = min(max(n, 4), 256) }
        if let n = LanConfig.int(dict["pinMaxAttempts"]) { pinMaxAttempts = min(max(n, 1), 100) }
    }

    func endpoint(_ name: String) -> String { apiPrefix + "/" + name }

    static func int(_ value: Any?) -> Int? {
        if let n = value as? NSNumber { return n.intValue }
        if let s = value as? String { return Int(s) }
        return nil
    }

    private static func normalizePrefix(_ raw: String?) -> String? {
        guard let raw = raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        if trimmed.isEmpty || trimmed.contains(where: { $0.isWhitespace || $0 == "?" || $0 == "#" }) { return nil }
        return "/" + trimmed
    }
}

// MARK: - File names

/// Received file names: never a path, never empty, "." / ".." or a control
/// character, at most 255 UTF-8 bytes, unique within a session.
enum LanFileNames {
    private static let maxBytes = 255
    private static let forbidden: Set<Character> = ["/", "\\", ":", "*", "?", "\"", "<", ">", "|"]

    static func sanitize(_ name: String?) -> String {
        var out = ""
        for scalar in (name ?? "").unicodeScalars {
            if scalar.value < 0x20 || scalar.value == 0x7f { continue }
            let ch = Character(scalar)
            out.append(forbidden.contains(ch) ? "_" : ch)
        }
        let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.allSatisfy({ $0 == "." }) { return "file" }
        return fit(trimmed)
    }

    /// `name`, or "name (2).ext", "name (3).ext"... when `taken` (case-insensitive) has it. Records the result.
    static func unique(_ name: String, taken: inout Set<String>) -> String {
        var candidate = name
        var counter = 2
        let ext = (name as NSString).pathExtension
        let base = ext.isEmpty ? name : (name as NSString).deletingPathExtension
        while taken.contains(candidate.lowercased()) {
            candidate = fit(ext.isEmpty ? "\(base) (\(counter))" : "\(base) (\(counter)).\(ext)")
            counter += 1
        }
        taken.insert(candidate.lowercased())
        return candidate
    }

    /// Cut to 255 UTF-8 bytes on a character boundary, keeping a short extension.
    private static func fit(_ name: String) -> String {
        if name.utf8.count <= maxBytes { return name }
        let ext = (name as NSString).pathExtension
        let suffix = (!ext.isEmpty && ext.count <= 15) ? "." + ext : ""
        let base = suffix.isEmpty ? name : (name as NSString).deletingPathExtension
        let budget = maxBytes - suffix.utf8.count
        var out = ""
        var used = 0
        for ch in base {
            let bytes = String(ch).utf8.count
            if used + bytes > budget { break }
            out.append(ch)
            used += bytes
        }
        return (out.isEmpty ? "file" : out) + suffix
    }
}
