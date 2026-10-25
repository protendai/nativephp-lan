import Foundation
import Network

/// UDP multicast discovery: announce our device info to the configured group
/// every 5 s and emit PeerFound for every other device of the same service.
/// The first multicast use triggers the iOS local-network permission prompt,
/// which is why discovery starts from StartDiscovery rather than at launch.
///
/// Sending to a multicast group needs Apple's
/// com.apple.developer.networking.multicast entitlement; without it the group
/// fails and PHP receives ServerError. Peers still find this device through
/// their HTTP subnet probe and the HTTP register answer below.
final class LanDiscovery {

    private let deviceInfo: [String: Any]
    private let config: LanConfig
    private let manager: LanManager
    private let myFingerprint: String
    private let queue = DispatchQueue(label: "com.protendai.lan.discovery")

    // Touched only on `queue`.
    private var group: NWConnectionGroup?
    private var timer: DispatchSourceTimer?
    private var lastRegistered: [String: Date] = [:]
    private var stopped = false

    init(deviceInfo: [String: Any], config: LanConfig, manager: LanManager) {
        self.deviceInfo = deviceInfo
        self.config = config
        self.manager = manager
        self.myFingerprint = (deviceInfo["fingerprint"] as? String) ?? ""
    }

    func start() {
        queue.async { self.startOnQueue() }
    }

    private func startOnQueue() {
        if stopped || group != nil { return }
        guard let port = NWEndpoint.Port(rawValue: UInt16(clamping: config.multicastPort)) else { return }
        do {
            let multicast = try NWMulticastGroup(for: [.hostPort(host: NWEndpoint.Host(config.multicastGroup), port: port)])
            let connectionGroup = NWConnectionGroup(with: multicast, using: .udp)
            connectionGroup.setReceiveHandler(maximumMessageSize: 65536, rejectOversizedMessages: true) { [weak self] message, content, _ in
                if let content = content { self?.handle(content, from: message.remoteEndpoint) }
            }
            connectionGroup.stateUpdateHandler = { [weak self] state in
                guard let self = self else { return }
                switch state {
                case .ready:
                    self.startAnnouncing()
                case .failed(let error):
                    self.manager.dispatch("ServerError", ["message": "discovery: \(error.localizedDescription)"])
                    self.stopOnQueue()
                default:
                    break
                }
            }
            connectionGroup.start(queue: queue)
            group = connectionGroup
        } catch {
            manager.dispatch("ServerError", ["message": "discovery: \(error.localizedDescription)"])
        }
    }

    private func startAnnouncing() {
        if stopped || timer != nil { return }
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
            return LanManager.normalizeIp("\(address)")
        case let .ipv6(address):
            return LanManager.normalizeIp("\(address)")
        default:
            return ""
        }
    }

    private func handle(_ content: Data, from endpoint: NWEndpoint?) {
        if stopped { return }
        guard let info = (try? JSONSerialization.jsonObject(with: content)) as? [String: Any] else { return }
        guard (info["app"] as? String) == config.serviceId else { return }
        let fingerprint = (info["fingerprint"] as? String) ?? ""
        if fingerprint.isEmpty || fingerprint == myFingerprint { return }

        // The address is the datagram's source, never a declared one.
        let senderIp = Self.ipv4(of: endpoint)
        guard !senderIp.isEmpty else { return }
        manager.emitPeerFound(LanManager.peer(from: info, ip: senderIp, config: config))

        if info["announce"] as? Bool == true {
            var reply = deviceInfo
            reply["announce"] = false
            if let data = try? JSONSerialization.data(withJSONObject: reply) {
                group?.send(content: data) { _ in }
            }
            // Multicast from iOS often never reaches the other phone, so also
            // answer over HTTP (POST register): the sender then learns our
            // current address. At most once per peer every 20 s.
            if shouldRegister(with: fingerprint) {
                let port = LanConfig.int(info["port"]) ?? config.port
                manager.announce(deviceInfo: reply, host: senderIp, port: port, seconds: 3, config: config)
            }
        }
    }

    private func shouldRegister(with fingerprint: String) -> Bool {
        if let last = lastRegistered[fingerprint], Date().timeIntervalSince(last) < 20 { return false }
        if lastRegistered.count > 256 { lastRegistered.removeAll() }
        lastRegistered[fingerprint] = Date()
        return true
    }

    func stop() {
        queue.async { self.stopOnQueue() }
    }

    private func stopOnQueue() {
        stopped = true
        timer?.cancel()
        timer = nil
        group?.stateUpdateHandler = nil
        group?.cancel()
        group = nil
    }
}
