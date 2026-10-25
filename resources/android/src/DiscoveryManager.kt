package com.protendai.lan

import android.content.Context
import android.net.wifi.WifiManager
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.net.DatagramPacket
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.MulticastSocket
import java.net.NetworkInterface
import java.net.Socket
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.concurrent.thread

/**
 * UDP multicast discovery: announce our device info to the configured group
 * every 5 s and listen for other devices' announcements, emitting PeerFound
 * for each. Holds a MulticastLock or most Wi-Fi chipsets drop multicast.
 *
 * The socket is pinned to the Wi-Fi interface: left to the default route,
 * Android joins/sends on mobile data and peers never hear us. Because many
 * routers drop multicast anyway, start() also probes the /24 over HTTP
 * (GET {apiPrefix}/info). Only devices announcing "app": serviceId count.
 *
 * stop() is safe at any moment, including before the listener thread has
 * opened its socket; sweeps stop too.
 */
class DiscoveryManager(
    private val context: Context,
    private val deviceInfo: JSONObject,
    private val config: LanConfig,
    private val manager: LanManager,
) {
    private val port = config.multicastPort
    private val myFingerprint = deviceInfo.optString("fingerprint")
    private val lock = Any()

    private var group: InetAddress? = null
    private var socket: MulticastSocket? = null
    private var multicastLock: WifiManager.MulticastLock? = null
    private var pools = mutableListOf<ExecutorService>()

    @Volatile
    private var running = false

    /** Set by stop(); a stopped manager never runs again. */
    @Volatile
    private var stopped = false

    fun start() {
        synchronized(lock) {
            if (running || stopped) return
            running = true

            val wifi = context.applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
            multicastLock = runCatching {
                wifi?.createMulticastLock("nativephp-lan")?.apply {
                    setReferenceCounted(false)
                    acquire()
                }
            }.getOrNull()
        }

        thread(name = "lan-discovery") {
            try {
                val groupAddress = InetAddress.getByName(config.multicastGroup)
                val wifiInterface = wifiInterface()
                // Built outside apply {}: inside it, `port` is MulticastSocket.getPort() (-1 while unconnected).
                val bindAddress = InetSocketAddress(port)
                val groupSocketAddress = InetSocketAddress(groupAddress, port)
                val listenSocket = MulticastSocket(null).apply {
                    reuseAddress = true
                    bind(bindAddress)
                    if (wifiInterface != null) {
                        networkInterface = wifiInterface
                        joinGroup(groupSocketAddress, wifiInterface)
                    } else {
                        @Suppress("DEPRECATION")
                        joinGroup(groupAddress)
                    }
                }

                synchronized(lock) {
                    if (!running) {
                        runCatching { listenSocket.close() }
                        return@thread
                    }
                    group = groupAddress
                    socket = listenSocket
                }

                thread(name = "lan-announce") { announceLoop(listenSocket, groupAddress) }
                thread(name = "lan-scan") { scanSubnet() }

                val buffer = ByteArray(8192)
                while (running) {
                    val packet = DatagramPacket(buffer, buffer.size)
                    try {
                        listenSocket.receive(packet)
                    } catch (e: Exception) {
                        if (!running) break else continue
                    }
                    handlePacket(packet, listenSocket)
                }
            } catch (e: Exception) {
                if (running) manager.dispatch("ServerError", JSONObject().put("message", "discovery: ${e.message ?: "error"}"))
            }
        }
    }

    private fun announceLoop(socket: MulticastSocket, groupAddress: InetAddress) {
        val data = JSONObject(deviceInfo.toString()).put("announce", true).toString().toByteArray()
        while (running) {
            runCatching { socket.send(DatagramPacket(data, data.size, groupAddress, port)) }
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

    private fun newPool(): ExecutorService? = synchronized(lock) {
        if (!running) return null
        Executors.newFixedThreadPool(48).also { pools.add(it) }
    }

    private fun releasePool(pool: ExecutorService) = synchronized(lock) { pools.remove(pool) }

    /**
     * Probe every host on our /24 for an info endpoint. Raw sockets rather
     * than HttpURLConnection so Android's cleartext policy can't block it.
     */
    private fun scanSubnet() {
        val ip = manager.localIp() ?: return
        val parts = ip.split(".")
        if (parts.size != 4) return
        val prefix = parts.take(3).joinToString(".")
        val ports = listOf(config.port, config.port + 1).distinct()

        val pool = newPool() ?: return
        try {
            for (host in 1..254) {
                val target = "$prefix.$host"
                if (target == ip) continue
                for (targetPort in ports) {
                    pool.execute {
                        if (running) probe(target, targetPort, 400)?.let { emitPeer(it, target) }
                    }
                }
            }
            pool.shutdown()
            runCatching { pool.awaitTermination(30, TimeUnit.SECONDS) }
        } catch (_: Exception) {
            pool.shutdownNow()
        } finally {
            releasePool(pool)
        }
    }

    /**
     * Sweep one /24 (e.g. a Wi-Fi Direct group, "192.168.49") in rounds until
     * a device answers, [seconds] pass or stop() is called. Blocking; call
     * off the main thread.
     */
    fun sweep(prefix: String, seconds: Int) {
        synchronized(lock) {
            if (stopped) return
            running = true
        }
        val deadline = System.currentTimeMillis() + seconds * 1000L
        val found = AtomicBoolean(false)

        while (running && !found.get() && System.currentTimeMillis() < deadline) {
            val pool = newPool() ?: break
            try {
                for (host in 2..254) {
                    val target = "$prefix.$host"
                    pool.execute {
                        if (!running || found.get()) return@execute
                        probe(target, config.port, 600)?.let { info ->
                            if (info.optString("app") == config.serviceId &&
                                info.optString("fingerprint") != myFingerprint &&
                                found.compareAndSet(false, true)
                            ) {
                                emitPeer(info, target)
                            }
                        }
                    }
                }
                pool.shutdown()
                runCatching { pool.awaitTermination(10, TimeUnit.SECONDS) }
            } catch (_: Exception) {
                pool.shutdownNow()
            } finally {
                releasePool(pool)
            }
            if (!found.get() && running) runCatching { Thread.sleep(1500) }
        }
        synchronized(lock) { running = false }
    }

    /** GET {prefix}/info, reading at most 64 KB of response. */
    private fun probe(host: String, targetPort: Int, connectTimeout: Int): JSONObject? = runCatching {
        Socket().use { socket ->
            socket.connect(InetSocketAddress(host, targetPort), connectTimeout)
            socket.soTimeout = 1500
            val request = "GET ${config.endpoint("info")}?fingerprint=$myFingerprint HTTP/1.1\r\n" +
                "Host: $host:$targetPort\r\nConnection: close\r\n\r\n"
            socket.getOutputStream().apply { write(request.toByteArray()); flush() }

            val out = ByteArrayOutputStream()
            val buffer = ByteArray(8192)
            val input = socket.getInputStream()
            while (out.size() < LanConfig.MAX_PROBE_BYTES) {
                val read = input.read(buffer, 0, minOf(buffer.size, LanConfig.MAX_PROBE_BYTES - out.size()))
                if (read < 0) break
                out.write(buffer, 0, read)
            }
            val response = out.toString("UTF-8")
            JSONObject(response.substringAfter("\r\n\r\n", "")).takeIf { it.has("fingerprint") }
        }
    }.getOrNull()

    private fun emitPeer(info: JSONObject, ip: String) {
        if (info.optString("app") != config.serviceId) return
        val fingerprint = info.optString("fingerprint")
        if (fingerprint.isEmpty() || fingerprint == myFingerprint) return

        val peer = JSONObject()
            .put("alias", info.optString("alias"))
            .put("fingerprint", fingerprint)
            .put("ip", ip)
            .put("port", info.optInt("port", config.port))
            .put("protocol", info.optString("protocol", "http"))
            .put("deviceModel", info.optString("deviceModel"))
            .put("deviceType", info.optString("deviceType"))

        manager.emitPeerFound(peer)
    }

    private fun handlePacket(packet: DatagramPacket, socket: MulticastSocket) {
        val text = String(packet.data, 0, packet.length, Charsets.UTF_8)
        val info = runCatching { JSONObject(text) }.getOrNull() ?: return

        val fingerprint = info.optString("fingerprint")
        if (fingerprint.isEmpty() || fingerprint == myFingerprint) return
        if (info.optString("app") != config.serviceId) return

        // The address is the datagram's source, never a declared one.
        val ip = packet.address?.hostAddress ?: return
        emitPeer(info, ip)

        // Reply directly so the other device learns about us too.
        if (info.optBoolean("announce", false)) {
            runCatching {
                val data = JSONObject(deviceInfo.toString()).put("announce", false).toString().toByteArray()
                socket.send(DatagramPacket(data, data.size, packet.address, packet.port))
            }
        }
    }

    fun stop() {
        val (closing, closingGroup, pending) = synchronized(lock) {
            stopped = true
            running = false
            val snapshot = Triple(socket, group, pools.toList())
            socket = null
            group = null
            pools.clear()
            multicastLock?.let { runCatching { if (it.isHeld) it.release() } }
            multicastLock = null
            snapshot
        }
        pending.forEach { it.shutdownNow() }
        @Suppress("DEPRECATION")
        runCatching { if (closing != null && closingGroup != null) closing.leaveGroup(closingGroup) }
        runCatching { closing?.close() }
    }
}
