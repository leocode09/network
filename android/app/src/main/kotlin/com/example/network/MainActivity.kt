package com.example.network

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.NetworkInfo
import android.net.wifi.p2p.WifiP2pConfig
import android.net.wifi.p2p.WifiP2pDevice
import android.net.wifi.p2p.WifiP2pDeviceList
import android.net.wifi.p2p.WifiP2pInfo
import android.net.wifi.p2p.WifiP2pManager
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.io.BufferedReader
import java.io.BufferedWriter
import java.io.InputStreamReader
import java.io.OutputStreamWriter
import java.io.PrintWriter
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors

class MainActivity : FlutterActivity(), EventChannel.StreamHandler {
    companion object {
        private const val WIFI_DIRECT_CHANNEL = "inflata/wifi_direct"
        private const val WIFI_DIRECT_EVENTS = "inflata/wifi_direct_events"
        private const val WIFI_DIRECT_PORT = 42113
        private const val CONNECT_TIMEOUT_MS = 3500
    }

    private val mainHandler = Handler(Looper.getMainLooper())
    private val executor = Executors.newCachedThreadPool()

    private var eventSink: EventChannel.EventSink? = null

    private var manager: WifiP2pManager? = null
    private var channel: WifiP2pManager.Channel? = null
    private var receiver: BroadcastReceiver? = null
    private val intentFilter = IntentFilter().apply {
        addAction(WifiP2pManager.WIFI_P2P_STATE_CHANGED_ACTION)
        addAction(WifiP2pManager.WIFI_P2P_PEERS_CHANGED_ACTION)
        addAction(WifiP2pManager.WIFI_P2P_CONNECTION_CHANGED_ACTION)
        addAction(WifiP2pManager.WIFI_P2P_THIS_DEVICE_CHANGED_ACTION)
    }

    private var started = false
    private var hostPreferred = false
    private var deviceId: String = ""
    private var deviceName: String = ""
    private var isGroupOwner = false
    private var connecting = false
    private var groupOwnerAddress: InetAddress? = null
    private var serverSocket: ServerSocket? = null
    private val connections = ConcurrentHashMap<String, PeerConnection>()
    private val discoveredPeers = mutableListOf<WifiP2pDevice>()

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, WIFI_DIRECT_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "start" -> {
                        val args = call.arguments as? Map<*, *>
                        val host = args?.get("host") as? Boolean ?: false
                        val id = args?.get("deviceId") as? String ?: ""
                        val name = args?.get("deviceName") as? String ?: ""
                        val ok = startWifiDirect(host, id, name)
                        result.success(ok)
                    }
                    "stop" -> {
                        stopWifiDirect()
                        result.success(true)
                    }
                    "send" -> {
                        val args = call.arguments as? Map<*, *>
                        val payload = args?.get("payload") as? String ?: ""
                        sendToPeers(payload)
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, WIFI_DIRECT_EVENTS)
            .setStreamHandler(this)
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
        sendStatus()
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }

    override fun onResume() {
        super.onResume()
        if (started) {
            registerReceiver()
        }
    }

    override fun onPause() {
        if (started) {
            unregisterReceiver()
        }
        super.onPause()
    }

    private fun startWifiDirect(host: Boolean, id: String, name: String): Boolean {
        if (started) {
            return true
        }

        deviceId = id
        deviceName = name
        hostPreferred = host

        manager = getSystemService(Context.WIFI_P2P_SERVICE) as WifiP2pManager
        channel = manager?.initialize(this, mainLooper, null)
        if (manager == null || channel == null) {
            sendLog("Wi-Fi Direct not available.")
            return false
        }

        registerReceiver()
        started = true

        if (hostPreferred) {
            manager?.createGroup(channel, object : WifiP2pManager.ActionListener {
                override fun onSuccess() {
                    sendLog("Wi-Fi Direct group created.")
                }

                override fun onFailure(reason: Int) {
                    sendLog("Wi-Fi Direct createGroup failed: $reason")
                }
            })
        }

        discoverPeers()
        sendStatus()
        return true
    }

    private fun stopWifiDirect() {
        started = false
        connecting = false
        isGroupOwner = false
        groupOwnerAddress = null
        discoveredPeers.clear()

        try {
            unregisterReceiver()
        } catch (_: IllegalArgumentException) {
        }

        manager?.stopPeerDiscovery(channel, null)
        manager?.removeGroup(channel, null)

        closeServer()
        closeConnections()
        sendStatus()
    }

    private fun registerReceiver() {
        if (receiver != null) {
            return
        }
        receiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) {
                when (intent.action) {
                    WifiP2pManager.WIFI_P2P_STATE_CHANGED_ACTION -> {
                        val state =
                            intent.getIntExtra(WifiP2pManager.EXTRA_WIFI_STATE, -1)
                        if (state != WifiP2pManager.WIFI_P2P_STATE_ENABLED) {
                            sendLog("Wi-Fi Direct disabled.")
                        }
                    }
                    WifiP2pManager.WIFI_P2P_PEERS_CHANGED_ACTION -> {
                        requestPeers()
                    }
                    WifiP2pManager.WIFI_P2P_CONNECTION_CHANGED_ACTION -> {
                        val info =
                            intent.getParcelableExtra<NetworkInfo>(
                                WifiP2pManager.EXTRA_NETWORK_INFO
                            )
                        if (info?.isConnected == true) {
                            requestConnectionInfo()
                        } else {
                            handleDisconnected()
                        }
                    }
                }
            }
        }
        registerReceiver(receiver, intentFilter)
    }

    private fun unregisterReceiver() {
        val current = receiver ?: return
        receiver = null
        unregisterReceiver(current)
    }

    private fun discoverPeers() {
        manager?.discoverPeers(channel, object : WifiP2pManager.ActionListener {
            override fun onSuccess() {
                sendLog("Wi-Fi Direct discovery started.")
            }

            override fun onFailure(reason: Int) {
                sendLog("Wi-Fi Direct discovery failed: $reason")
            }
        })
    }

    private fun requestPeers() {
        manager?.requestPeers(channel) { peers: WifiP2pDeviceList ->
            discoveredPeers.clear()
            discoveredPeers.addAll(peers.deviceList)
            sendStatus()

            if (!hostPreferred && connections.isEmpty() && !connecting) {
                val target = discoveredPeers.firstOrNull()
                if (target != null) {
                    connectToPeer(target)
                }
            }
        }
    }

    private fun connectToPeer(device: WifiP2pDevice) {
        val config = WifiP2pConfig().apply {
            deviceAddress = device.deviceAddress
            groupOwnerIntent = if (hostPreferred) 15 else 0
        }
        connecting = true
        manager?.connect(channel, config, object : WifiP2pManager.ActionListener {
            override fun onSuccess() {
                sendLog("Connecting to ${device.deviceName}")
            }

            override fun onFailure(reason: Int) {
                connecting = false
                sendLog("Connect failed: $reason")
            }
        })
    }

    private fun requestConnectionInfo() {
        manager?.requestConnectionInfo(channel) { info: WifiP2pInfo ->
            if (!info.groupFormed) {
                return@requestConnectionInfo
            }

            isGroupOwner = info.isGroupOwner
            groupOwnerAddress = info.groupOwnerAddress
            connecting = false
            sendStatus()

            if (isGroupOwner) {
                startServer()
            } else {
                connectToGroupOwner(info.groupOwnerAddress)
            }
        }
    }

    private fun handleDisconnected() {
        isGroupOwner = false
        groupOwnerAddress = null
        connecting = false
        closeConnections()
        closeServer()
        sendStatus()
    }

    private fun startServer() {
        if (serverSocket != null) {
            return
        }
        executor.execute {
            try {
                serverSocket = ServerSocket(WIFI_DIRECT_PORT)
                sendLog("Wi-Fi Direct server listening on $WIFI_DIRECT_PORT")
                while (started && serverSocket != null && !serverSocket!!.isClosed) {
                    val socket = serverSocket!!.accept()
                    registerConnection(socket, outbound = false)
                }
            } catch (error: Exception) {
                sendLog("Wi-Fi Direct server error: ${error.message}")
            } finally {
                closeServer()
            }
        }
    }

    private fun connectToGroupOwner(address: InetAddress?) {
        if (address == null) {
            return
        }
        val key = address.hostAddress ?: return
        if (connections.containsKey(key)) {
            return
        }
        executor.execute {
            try {
                val socket = Socket()
                socket.connect(InetSocketAddress(address, WIFI_DIRECT_PORT), CONNECT_TIMEOUT_MS)
                registerConnection(socket, outbound = true)
            } catch (error: Exception) {
                sendLog("Wi-Fi Direct connect error: ${error.message}")
            }
        }
    }

    private fun registerConnection(socket: Socket, outbound: Boolean) {
        val key = socket.inetAddress?.hostAddress ?: socket.remoteSocketAddress.toString()
        if (connections.containsKey(key)) {
            socket.close()
            return
        }
        val connection = PeerConnection(key, socket, outbound)
        connections[key] = connection
        connection.start()
        sendHello(connection)
        sendStatus()
    }

    private fun sendHello(connection: PeerConnection) {
        val json = JSONObject()
        json.put("type", "hello")
        json.put("id", deviceId)
        json.put("name", deviceName)
        connection.send(json.toString())
    }

    private fun sendToPeers(payload: String) {
        if (payload.isEmpty()) {
            return
        }
        connections.values.forEach { connection ->
            connection.send(payload)
        }
    }

    private fun forwardToOthers(source: PeerConnection, payload: String) {
        connections.values.forEach { connection ->
            if (connection != source) {
                connection.send(payload)
            }
        }
    }

    private fun closeConnections() {
        connections.values.forEach { it.close() }
        connections.clear()
    }

    private fun closeServer() {
        try {
            serverSocket?.close()
        } catch (_: Exception) {
        }
        serverSocket = null
    }

    private fun sendStatus() {
        sendEvent(
            mapOf(
                "type" to "status",
                "running" to started,
                "connected" to connections.size,
                "discovered" to discoveredPeers.size,
                "host" to hostPreferred
            )
        )
    }

    private fun sendLog(message: String) {
        sendEvent(mapOf("type" to "log", "message" to message))
    }

    private fun sendEvent(data: Map<String, Any?>) {
        mainHandler.post {
            eventSink?.success(data)
        }
    }

    inner class PeerConnection(
        private val key: String,
        private val socket: Socket,
        private val outbound: Boolean
    ) {
        private val writer = PrintWriter(
            BufferedWriter(OutputStreamWriter(socket.getOutputStream())),
            true
        )
        private var running = true
        var peerId: String? = null
        var peerName: String? = null

        fun start() {
            executor.execute {
                try {
                    val reader = BufferedReader(InputStreamReader(socket.getInputStream()))
                    while (running) {
                        val line = reader.readLine() ?: break
                        handleLine(this, line)
                    }
                } catch (_: Exception) {
                } finally {
                    close()
                }
            }
        }

        fun send(payload: String) {
            if (!running) {
                return
            }
            writer.println(payload)
        }

        fun close() {
            if (!running) {
                return
            }
            running = false
            try {
                socket.close()
            } catch (_: Exception) {
            }
            connections.remove(key)
            sendStatus()
        }
    }

    private fun handleLine(connection: PeerConnection, line: String) {
        try {
            val json = JSONObject(line)
            if (json.optString("type") == "hello") {
                connection.peerId = json.optString("id")
                connection.peerName = json.optString("name")
                sendEvent(
                    mapOf(
                        "type" to "peer_connected",
                        "id" to connection.peerId,
                        "name" to connection.peerName
                    )
                )
                return
            }
        } catch (_: Exception) {
        }

        if (isGroupOwner) {
            forwardToOthers(connection, line)
        }

        sendEvent(
            mapOf(
                "type" to "message",
                "payload" to line,
                "fromId" to connection.peerId,
                "fromName" to connection.peerName
            )
        )
    }
}
