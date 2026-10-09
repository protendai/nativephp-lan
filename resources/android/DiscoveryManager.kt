package com.tuma.lan

import android.content.Context
import android.net.wifi.WifiManager
import android.util.Log
import org.json.JSONObject
import java.net.DatagramPacket
import java.net.InetAddress
import java.net.MulticastSocket
import kotlin.concurrent.thread

/**
 * UDP multicast discovery, LocalSend style: announce our device info to
 * 224.0.0.167:53317 every 5s and listen for other devices' announcements,
 * emitting PeerFound for each. Needs a held MulticastLock or most Wi-Fi
 * chipsets drop multicast frames.
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
                val listenSocket = MulticastSocket(port).apply {
                    reuseAddress = true
                    joinGroup(group)
                }
                socket = listenSocket

                Log.d(LanManager.TAG, "discovery started on ${LanManager.MULTICAST_GROUP}:$port")
                thread(name = "tuma-announce") { announceLoop(listenSocket) }

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

    private fun handlePacket(packet: DatagramPacket) {
        val text = String(packet.data, 0, packet.length)
        val info = runCatching { JSONObject(text) }.getOrNull() ?: return

        val fingerprint = info.optString("fingerprint")
        if (fingerprint.isEmpty() || fingerprint == myFingerprint) return

        val ip = packet.address.hostAddress ?: return

        Log.d(LanManager.TAG, "peer announce from $ip (${info.optString("alias")})")

        val peer = JSONObject()
            .put("alias", info.optString("alias"))
            .put("fingerprint", fingerprint)
            .put("ip", ip)
            .put("port", info.optInt("port", 53317))
            .put("protocol", info.optString("protocol", "http"))
            .put("deviceModel", info.optString("deviceModel"))
            .put("deviceType", info.optString("deviceType"))

        manager.emitPeerFound(peer)

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
