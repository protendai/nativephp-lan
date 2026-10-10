import Foundation
import Network

/// UDP multicast discovery: announce our device info to
/// 224.0.0.167:53480 every 5s and emit PeerFound for every other device's
/// announcement. The first multicast use triggers the iOS local-network
/// permission prompt, which is why discovery starts from StartDiscovery
/// rather than at launch.
///
/// NOTE: unverified from this environment — validate on a Mac before shipping.
final class DiscoveryManager {

    private let deviceInfo: [String: Any]
    private let manager: LanManager
    private let myFingerprint: String
    private let queue = DispatchQueue(label: "com.tuma.lan.discovery")

    private var group: NWConnectionGroup?
    private var timer: DispatchSourceTimer?

    init(deviceInfo: [String: Any], manager: LanManager) {
        self.deviceInfo = deviceInfo
        self.manager = manager
        self.myFingerprint = (deviceInfo["fingerprint"] as? String) ?? ""
    }

    func start() {
        do {
            let multicast = try NWMulticastGroup(
                for: [.hostPort(host: NWEndpoint.Host(LanManager.multicastGroup),
                                port: NWEndpoint.Port(rawValue: LanManager.multicastPort)!)]
            )

            let connectionGroup = NWConnectionGroup(with: multicast, using: .udp)
            connectionGroup.setReceiveHandler(maximumMessageSize: 65536, rejectOversizedMessages: true) { [weak self] message, content, _ in
                if let content = content { self?.handle(content, from: message.remoteEndpoint) }
            }
            connectionGroup.stateUpdateHandler = { [weak self] state in
                if case .ready = state { self?.startAnnouncing() }
            }
            connectionGroup.start(queue: queue)
            group = connectionGroup
        } catch {
            manager.dispatch("ServerError", ["message": "discovery: \(error.localizedDescription)"])
        }
    }

    private func startAnnouncing() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 5.0)
        timer.setEventHandler { [weak self] in self?.announce() }
        timer.resume()
        self.timer = timer
    }

    private func announce() {
        var announce = deviceInfo
        announce["announce"] = true
        guard let data = try? JSONSerialization.data(withJSONObject: announce) else { return }
        group?.send(content: data) { _ in }
    }

    /// "192.168.18.95" from the sender's endpoint (scope suffixes like %en0 stripped).
    private static func ipv4(of endpoint: NWEndpoint?) -> String {
        guard case let .hostPort(host, _)? = endpoint else { return "" }
        switch host {
        case let .ipv4(address):
            return "\(address)".components(separatedBy: "%").first ?? ""
        case let .name(name, _):
            return name
        default:
            return ""
        }
    }

    private func handle(_ content: Data, from endpoint: NWEndpoint?) {
        guard let info = (try? JSONSerialization.jsonObject(with: content)) as? [String: Any] else { return }
        guard (info["app"] as? String) == "tumira" else { return }
        let fingerprint = (info["fingerprint"] as? String) ?? ""
        if fingerprint.isEmpty || fingerprint == myFingerprint { return }

        // The sender's address comes from the datagram's remote endpoint.
        let senderIp = Self.ipv4(of: endpoint)
        let peer: [String: Any] = [
            "alias": info["alias"] as? String ?? "",
            "fingerprint": fingerprint,
            "ip": senderIp.isEmpty ? (info["ip"] as? String ?? "") : senderIp,
            "port": info["port"] as? Int ?? 53480,
            "protocol": info["protocol"] as? String ?? "http",
            "deviceModel": info["deviceModel"] as? String ?? "",
            "deviceType": info["deviceType"] as? String ?? "",
        ]
        manager.emitPeerFound(peer)

        if info["announce"] as? Bool == true {
            var reply = deviceInfo
            reply["announce"] = false
            if let data = try? JSONSerialization.data(withJSONObject: reply) {
                group?.send(content: data) { _ in }
            }
        }
    }

    func stop() {
        timer?.cancel()
        timer = nil
        group?.cancel()
        group = nil
    }
}
