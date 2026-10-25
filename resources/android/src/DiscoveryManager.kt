package com.tuma.lan

import android.content.Context
import android.net.wifi.WifiManager
import android.util.Log
import org.json.JSONObject
import java.net.DatagramPacket
import java.net.Inet4Address
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.MulticastSocket
import java.net.NetworkInterface
import java.net.Socket
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import kotlin.concurrent.thread

/**
 * UDP multicast discovery: announce our device info to
 * 224.0.0.167:53480 every 5s and listen for other devices' announcements,
 * emitting PeerFound for each. Needs a held MulticastLock or most Wi-Fi
 * chipsets drop multicast frames.
 *
 * The socket is pinned to the Wi-Fi interface: left to the default route,
 * Android joins/sends on mobile data and peers never hear us. Because many
 * routers drop multicast anyway, start() also sweeps the /24 over HTTP
 * (GET /api/tumira/v1/info). Only devices announcing app=tumira count, so
 * LocalSend and other apps on the same group never show up.
 */
class DiscoveryManager(
    private val context: Context,
    private val deviceInfo: JSONObject,
    private val manager: LanManager,
) {
    private val group: InetAddress = InetAddress.getByName(LanManager.MULTICAST_GROUP)
    private val port = LanManager.MULTICAST_PORT
    private val myFingerprint = deviceInfo.optString("fingerprint")

    private var socket: MulticastSocket? = null
    private var multicastLock: WifiManager.MulticastLock? = null

    @Volatile
    private var running = false

    fun start() {
        if (running) return
        running = true

        val wifi = context.getSystemService(Context.WIFI_SERVICE) as? WifiManager
        multicastLock = wifi?.createMulticastLock("tuma-lan")?.apply {
            setReferenceCounted(true)
            acquire()
        }

        thread(name = "tuma-discovery") {
            try {
                val wifiInterface = wifiInterface()
                // Built outside apply {}: inside it, `port` is MulticastSocket.getPort() (-1 while unconnected).
                val bindAddress = InetSocketAddress(port)
                val groupAddress = InetSocketAddress(group, port)
                val listenSocket = MulticastSocket(null).apply {
                    reuseAddress = true
                    bind(bindAddress)
                    if (wifiInterface != null) {
                        networkInterface = wifiInterface
                        joinGroup(groupAddress, wifiInterface)
                    } else {
                        joinGroup(group)
                    }
                }
                socket = listenSocket

                Log.d(LanManager.TAG, "discovery started on ${LanManager.MULTICAST_GROUP}:$port via ${wifiInterface?.name ?: "default"}")
                thread(name = "tuma-announce") { announceLoop(listenSocket) }
                thread(name = "tuma-scan") { scanSubnet() }

                val buffer = ByteArray(8192)
                while (running) {
                    val packet = DatagramPacket(buffer, buffer.size)
                    try {
                        listenSocket.receive(packet)
                    } catch (e: Exception) {
                        if (!running) break else continue
                    }
                    handlePacket(packet)
                }
            } catch (e: Exception) {
                manager.dispatch("ServerError", JSONObject().put("message", e.message ?: "discovery error"))
            }
        }
    }

    private fun announceLoop(socket: MulticastSocket) {
        while (running) {
            try {
                val announce = JSONObject(deviceInfo.toString()).put("announce", true)
                val data = announce.toString().toByteArray()
                socket.send(DatagramPacket(data, data.size, group, port))
            } catch (_: Exception) {
            }
            try {
                Thread.sleep(5000)
            } catch (_: InterruptedException) {
                break
            }
        }
    }

    /** The interface carrying our Wi-Fi IPv4 address, or null to use the default. */
    private fun wifiInterface(): NetworkInterface? = runCatching {
        val ip = manager.localIp()
        val candidates = NetworkInterface.getNetworkInterfaces().toList()
            .filter { it.isUp && !it.isLoopback && it.supportsMulticast() }
        candidates.firstOrNull { nif -> nif.inetAddresses.toList().any { it.hostAddress == ip } }
            ?: candidates.firstOrNull { it.name.startsWith("wlan") }
    }.getOrNull()

    /**
     * Probe every host on our /24 for a Tumira info endpoint. Raw sockets
     * rather than HttpURLConnection so Android's cleartext policy can't block it.
     */
    private fun scanSubnet() {
        val ip = manager.localIp() ?: return
        val parts = ip.split(".")
        if (parts.size != 4) return
        val prefix = parts.take(3).joinToString(".")
        val ports = listOf(port, port + 1).distinct()

        Log.d(LanManager.TAG, "http scan of $prefix.0/24 started")
        val pool = Executors.newFixedThreadPool(48)
        for (host in 1..254) {
            val target = "$prefix.$host"
            if (target == ip) continue
            for (targetPort in ports) {
                pool.execute {
                    if (running) probe(target, targetPort)?.let { emitPeer(it, target) }
                }
            }
        }
        pool.shutdown()
        runCatching { pool.awaitTermination(30, TimeUnit.SECONDS) }
        Log.d(LanManager.TAG, "http scan of $prefix.0/24 finished")
    }

    /**
     * Sweep one /24 (e.g. the Wi-Fi Direct group 192.168.49) in rounds until a
     * Tumira device answers or the time runs out. Used by a sender hosting a
     * pairing code: it learns the joining phone's IP this way. Blocking; call
     * off the main thread.
     */
    fun sweep(prefix: String, seconds: Int) {
        running = true
        val deadline = System.currentTimeMillis() + seconds * 1000L
        var found = false
        Log.d(LanManager.TAG, "sweep of $prefix.0/24 for ${seconds}s")
        var round = 0
        while (!found && System.currentTimeMillis() < deadline) {
            round++
            val errors = java.util.concurrent.ConcurrentHashMap<String, Int>()
            val pool = Executors.newFixedThreadPool(48)
            for (host in 2..254) {
                val target = "$prefix.$host"
                pool.execute {
                    probeOrError(target, port) { error -> errors.merge(error, 1, Int::plus) }?.let { info ->
                        if (info.optString("app") == LanManager.APP_ID && info.optString("fingerprint") != myFingerprint) {
                            found = true
                            emitPeer(info, target)
                        }
                    }
                }
            }
            pool.shutdown()
            runCatching { pool.awaitTermination(10, TimeUnit.SECONDS) }
            if (!found && round <= 2) Log.d(LanManager.TAG, "sweep round $round errors: $errors")
            if (!found) runCatching { Thread.sleep(1500) }
        }
        running = false
        Log.d(LanManager.TAG, "sweep of $prefix.0/24 ${if (found) "found a peer" else "found nothing"}")
    }

    /** probe(), reporting why it failed (exception class + message) for diagnostics. */
    private fun probeOrError(host: String, targetPort: Int, onError: (String) -> Unit): JSONObject? = try {
        Socket().use { socket ->
            socket.connect(InetSocketAddress(host, targetPort), 600)
            socket.soTimeout = 1500
            val request = "GET /api/tumira/v1/info?fingerprint=$myFingerprint HTTP/1.1\r\n" +
                "Host: $host:$targetPort\r\nConnection: close\r\n\r\n"
            socket.getOutputStream().apply { write(request.toByteArray()); flush() }
            val response = socket.getInputStream().readBytes().toString(Charsets.UTF_8)
            JSONObject(response.substringAfter("\r\n\r\n", "")).takeIf { it.has("fingerprint") }
        }
    } catch (e: Exception) {
        onError("${e.javaClass.simpleName}: ${e.message?.substringAfterLast(": ")?.take(40)}")
        null
    }

    private fun probe(host: String, targetPort: Int): JSONObject? = runCatching {
        Socket().use { socket ->
            socket.connect(InetSocketAddress(host, targetPort), 400)
            socket.soTimeout = 1500
            val request = "GET /api/tumira/v1/info?fingerprint=$myFingerprint HTTP/1.1\r\n" +
                "Host: $host:$targetPort\r\nConnection: close\r\n\r\n"
            socket.getOutputStream().apply { write(request.toByteArray()); flush() }
            val response = socket.getInputStream().readBytes().toString(Charsets.UTF_8)
            val body = response.substringAfter("\r\n\r\n", "")
            JSONObject(body).takeIf { it.has("fingerprint") }
        }
    }.getOrNull()

    private fun emitPeer(info: JSONObject, ip: String) {
        if (info.optString("app") != LanManager.APP_ID) return
        val fingerprint = info.optString("fingerprint")
        if (fingerprint.isEmpty() || fingerprint == myFingerprint) return

        Log.d(LanManager.TAG, "peer at $ip (${info.optString("alias")})")

        val peer = JSONObject()
            .put("alias", info.optString("alias"))
            .put("fingerprint", fingerprint)
            .put("ip", ip)
            .put("port", info.optInt("port", 53480))
            .put("protocol", info.optString("protocol", "http"))
            .put("deviceModel", info.optString("deviceModel"))
            .put("deviceType", info.optString("deviceType"))

        manager.emitPeerFound(peer)
    }

    private fun handlePacket(packet: DatagramPacket) {
        val text = String(packet.data, 0, packet.length)
        val info = runCatching { JSONObject(text) }.getOrNull() ?: return

        val fingerprint = info.optString("fingerprint")
        if (fingerprint.isEmpty() || fingerprint == myFingerprint) return

        val ip = packet.address.hostAddress ?: return
        emitPeer(info, ip)

        // Reply directly so the other device learns about us too.
        if (info.optBoolean("announce", false)) {
            runCatching {
                val reply = JSONObject(deviceInfo.toString()).put("announce", false)
                val data = reply.toString().toByteArray()
                socket?.send(DatagramPacket(data, data.size, packet.address, packet.port))
            }
        }
    }

    fun stop() {
        running = false
        runCatching { socket?.leaveGroup(group) }
        runCatching { socket?.close() }
        socket = null
        multicastLock?.let { runCatching { it.release() } }
        multicastLock = null
    }
}
