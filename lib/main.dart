import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:nearby_connections/nearby_connections.dart';
import 'package:permission_handler/permission_handler.dart';

const String serviceId = 'com.example.network.inflata';
const int maxPeers = 20;
const int maxLogEntries = 200;
const int lanDiscoveryPort = 42111;
const int lanTcpPort = 42112;
const Duration lanAnnounceInterval = Duration(seconds: 2);
const Duration lanPeerTimeout = Duration(seconds: 6);
const int maxRecentMessages = 300;

const MethodChannel _wifiDirectChannel = MethodChannel('inflata/wifi_direct');
const EventChannel _wifiDirectEvents = EventChannel(
  'inflata/wifi_direct_events',
);

const Color _kInk = Color(0xFF0F172A);
const Color _kMuted = Color(0xFF64748B);
const Color _kSurface = Color(0xFFFFFFFF);
const Color _kSurfaceAlt = Color(0xFFF1F5F9);
const Color _kBorder = Color(0xFFE2E8F0);
const Color _kAccent = Color(0xFF0F766E);
const Color _kAccentSoft = Color(0xFFE6F4F1);

void main() {
  runApp(const InflataApp());
}

class InflataApp extends StatelessWidget {
  const InflataApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Inflata',
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: _kAccent,
          brightness: Brightness.light,
          surface: _kSurface,
        ),
        scaffoldBackgroundColor: const Color(0xFFF6F7F4),
        textTheme: GoogleFonts.manropeTextTheme().apply(
          bodyColor: _kInk,
          displayColor: _kInk,
        ),
        appBarTheme: AppBarTheme(
          backgroundColor: Colors.transparent,
          elevation: 0,
          surfaceTintColor: Colors.transparent,
          titleTextStyle: GoogleFonts.manrope(
            fontSize: 20,
            fontWeight: FontWeight.w600,
            color: _kInk,
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: _kSurface,
          labelStyle: const TextStyle(color: _kMuted),
          hintStyle: const TextStyle(color: _kMuted),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: const BorderSide(color: _kBorder),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: const BorderSide(color: _kBorder),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: const BorderSide(color: _kAccent, width: 1.2),
          ),
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: _kAccent,
            foregroundColor: Colors.white,
            textStyle: const TextStyle(fontWeight: FontWeight.w600),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
            padding: const EdgeInsets.symmetric(vertical: 14),
          ),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
            foregroundColor: _kAccent,
            side: const BorderSide(color: _kBorder),
            textStyle: const TextStyle(fontWeight: FontWeight.w600),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
            padding: const EdgeInsets.symmetric(vertical: 14),
          ),
        ),
      ),
      home: const InflataHomePage(),
    );
  }
}

class InflataHomePage extends StatefulWidget {
  const InflataHomePage({super.key});

  @override
  State<InflataHomePage> createState() => _InflataHomePageState();
}

class _InflataHomePageState extends State<InflataHomePage>
    with WidgetsBindingObserver {
  final DeviceInfoPlugin _deviceInfo = DeviceInfoPlugin();
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _messageController = TextEditingController();
  final TextEditingController _sharedNoteController = TextEditingController();
  final ScrollController _logScrollController = ScrollController();
  Timer? _noteDebounce;
  bool _suppressNoteBroadcast = false;
  int _lastNoteUpdateMs = 0;
  final String _deviceId =
      '${DateTime.now().microsecondsSinceEpoch}-${Random().nextInt(1 << 32)}';
  final Set<String> _recentMessageIds = <String>{};
  final List<String> _recentMessageOrder = <String>[];
  int _messageCounter = 0;

  bool _running = false;
  bool _advertising = false;
  bool _discovering = false;
  final Map<String, String> _endpointNames = <String, String>{};
  final Set<String> _connectedEndpoints = <String>{};
  final Set<String> _connectingEndpoints = <String>{};
  final List<String> _logs = <String>[];

  bool _lanRunning = false;
  RawDatagramSocket? _lanSocket;
  ServerSocket? _lanServer;
  Timer? _lanAnnounceTimer;
  final Map<String, _LanPeer> _lanPeers = <String, _LanPeer>{};
  final Map<String, _LanConnection> _lanConnections =
      <String, _LanConnection>{};
  final Set<String> _lanPendingConnections = <String>{};

  StreamSubscription<dynamic>? _wifiDirectSubscription;
  bool _wifiDirectRunning = false;
  bool _wifiDirectHostPreferred = false;
  int _wifiDirectConnected = 0;
  int _wifiDirectDiscovered = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _nameController.text =
        'Inflata-${DateTime.now().millisecondsSinceEpoch % 10000}';
    _sharedNoteController.addListener(_onSharedNoteChanged);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _nameController.dispose();
    _messageController.dispose();
    _sharedNoteController.removeListener(_onSharedNoteChanged);
    _sharedNoteController.dispose();
    _logScrollController.dispose();
    _noteDebounce?.cancel();
    _stopLan();
    _stopWifiDirect();
    Nearby().stopAllEndpoints();
    Nearby().stopDiscovery();
    Nearby().stopAdvertising();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused && _running) {
      _addLog('App paused. Consider stopping to save battery.');
    }
  }

  String get _deviceName => _nameController.text.trim();

  Future<void> _startInflata() async {
    if (_running) {
      return;
    }

    if (_deviceName.isEmpty) {
      _addLog('Device name is required.');
      return;
    }

    final hasPermission = await _ensurePermissions();
    if (!hasPermission) {
      _addLog('Required permissions not granted.');
      return;
    }

    if (!mounted) {
      return;
    }

    setState(() {
      _running = true;
    });

    await _startLan();
    await _startWifiDirect();

    var advertising = false;
    var discovering = false;
    try {
      _addLog('Starting advertising and discovery...');
      advertising = await Nearby().startAdvertising(
        _deviceName,
        Strategy.P2P_CLUSTER,
        onConnectionInitiated: _onConnectionInitiated,
        onConnectionResult: _onConnectionResult,
        onDisconnected: _onDisconnected,
        serviceId: serviceId,
      );

      discovering = await Nearby().startDiscovery(
        _deviceName,
        Strategy.P2P_CLUSTER,
        onEndpointFound: _onEndpointFound,
        onEndpointLost: _onEndpointLost,
        serviceId: serviceId,
      );
    } catch (error) {
      _addLog('Nearby start error: $error');
    }

    if (!mounted) {
      return;
    }

    setState(() {
      _advertising = advertising;
      _discovering = discovering;
    });

    _addLog(
      "Advertising: $advertising, Discovery: $discovering, LAN: ${_lanRunning ? 'on' : 'off'}, Wi-Fi Direct: ${_wifiDirectRunning ? 'on' : 'off'}",
    );

    if (!advertising && !discovering && !_lanRunning && !_wifiDirectRunning) {
      _addLog('All transports failed to start.');
      await _stopInflata();
    }
  }

  Future<void> _stopInflata() async {
    try {
      Nearby().stopDiscovery();
      Nearby().stopAdvertising();
      Nearby().stopAllEndpoints();
    } catch (error) {
      _addLog('Stop error: $error');
    }

    await _stopLan();
    await _stopWifiDirect();

    if (!mounted) {
      return;
    }

    setState(() {
      _running = false;
      _advertising = false;
      _discovering = false;
      _connectedEndpoints.clear();
      _connectingEndpoints.clear();
      _endpointNames.clear();
    });
  }

  Future<bool> _ensurePermissions() async {
    if (!Platform.isAndroid) {
      return true;
    }

    final androidInfo = await _deviceInfo.androidInfo;
    final sdkInt = androidInfo.version.sdkInt;

    if (sdkInt >= 33) {
      final status = await Permission.nearbyWifiDevices.request();
      if (status.isGranted) {
        return true;
      }

      if (status.isPermanentlyDenied) {
        await openAppSettings();
      }

      return false;
    }

    final status = await Permission.location.request();
    if (status.isGranted) {
      return true;
    }

    if (status.isPermanentlyDenied) {
      await openAppSettings();
    }

    return false;
  }

  Future<void> _startLan() async {
    if (_lanRunning) {
      return;
    }

    try {
      _lanServer = await ServerSocket.bind(
        InternetAddress.anyIPv4,
        lanTcpPort,
        shared: true,
      );
      _lanServer!.listen(
        (socket) => _handleLanSocket(socket, outbound: false),
        onError: (error) => _addLog('LAN server error: $error'),
      );

      _lanSocket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        lanDiscoveryPort,
        reuseAddress: true,
        reusePort: true,
      );
      _lanSocket!.broadcastEnabled = true;
      _lanSocket!.listen(
        _handleLanDatagram,
        onError: (error) => _addLog('LAN discovery error: $error'),
      );

      _lanAnnounceTimer?.cancel();
      _lanAnnounceTimer = Timer.periodic(
        lanAnnounceInterval,
        (_) => _sendLanAnnounce(),
      );
      _sendLanAnnounce();

      if (!mounted) {
        return;
      }

      setState(() {
        _lanRunning = true;
      });

      _addLog(
        'LAN discovery running on UDP $lanDiscoveryPort / TCP $lanTcpPort.',
      );
    } catch (error) {
      _addLog('LAN start failed: $error');
      await _stopLan();
    }
  }

  Future<void> _stopLan() async {
    _lanAnnounceTimer?.cancel();
    _lanAnnounceTimer = null;

    _lanSocket?.close();
    _lanSocket = null;

    final server = _lanServer;
    _lanServer = null;
    if (server != null) {
      await server.close();
    }

    final connections = _lanConnections.values.toList();
    _lanConnections.clear();
    for (final connection in connections) {
      await connection.close();
    }
    _lanPendingConnections.clear();
    _lanPeers.clear();

    if (!mounted) {
      return;
    }

    setState(() {
      _lanRunning = false;
    });
  }

  Future<void> _startWifiDirect() async {
    if (!Platform.isAndroid) {
      return;
    }
    try {
      _wifiDirectSubscription ??= _wifiDirectEvents
          .receiveBroadcastStream()
          .listen(
            _onWifiDirectEvent,
            onError: (error) {
              _addLog('Wi-Fi Direct event error: $error');
            },
          );

      final result = await _wifiDirectChannel
          .invokeMethod<bool>('start', <String, dynamic>{
            'deviceId': _deviceId,
            'deviceName': _deviceName,
            'host': _wifiDirectHostPreferred,
          });

      if (!mounted) {
        return;
      }

      setState(() {
        _wifiDirectRunning = result ?? false;
      });
    } catch (error) {
      _addLog('Wi-Fi Direct start failed: $error');
    }
  }

  Future<void> _stopWifiDirect() async {
    if (!Platform.isAndroid) {
      return;
    }
    try {
      await _wifiDirectChannel.invokeMethod('stop');
    } catch (error) {
      _addLog('Wi-Fi Direct stop failed: $error');
    }

    await _wifiDirectSubscription?.cancel();
    _wifiDirectSubscription = null;

    if (!mounted) {
      return;
    }

    setState(() {
      _wifiDirectRunning = false;
      _wifiDirectConnected = 0;
      _wifiDirectDiscovered = 0;
    });
  }

  void _onWifiDirectEvent(dynamic event) {
    if (!mounted) {
      return;
    }

    if (event is Map) {
      final type = event['type'];
      if (type == 'status') {
        setState(() {
          _wifiDirectRunning = event['running'] == true;
          final connected = event['connected'];
          final discovered = event['discovered'];
          if (connected is int) {
            _wifiDirectConnected = connected;
          }
          if (discovered is int) {
            _wifiDirectDiscovered = discovered;
          }
        });
        return;
      }

      if (type == 'message') {
        final payload = event['payload'];
        if (payload is String) {
          final fromName = event['fromName'];
          final fromId = event['fromId'];
          final label = fromName is String && fromName.isNotEmpty
              ? 'WFD:$fromName'
              : fromId is String && fromId.isNotEmpty
              ? 'WFD:$fromId'
              : 'WFD:peer';
          _handleIncomingMessage(label, payload);
        }
        return;
      }

      if (type == 'peer_connected') {
        final name = event['name'];
        final id = event['id'];
        if (name is String && name.isNotEmpty) {
          _addLog('Wi-Fi Direct connected: $name.');
        } else if (id is String && id.isNotEmpty) {
          _addLog('Wi-Fi Direct connected: $id.');
        } else {
          _addLog('Wi-Fi Direct connected.');
        }

        if (_lastNoteUpdateMs > 0) {
          unawaited(_sendNoteUpdateToWifiDirect());
        }
        return;
      }

      if (type == 'log') {
        final message = event['message'];
        if (message is String && message.isNotEmpty) {
          _addLog('WFD: $message');
        }
        return;
      }
    }
  }

  void _handleLanDatagram(RawSocketEvent event) {
    if (event != RawSocketEvent.read) {
      return;
    }

    final socket = _lanSocket;
    if (socket == null) {
      return;
    }

    Datagram? datagram;
    while ((datagram = socket.receive()) != null) {
      final message = utf8.decode(datagram!.data);
      try {
        final data = jsonDecode(message);
        if (data is! Map<String, dynamic>) {
          continue;
        }
        if (data['type'] != 'lan_announce') {
          continue;
        }

        final peerId = data['id'];
        if (peerId is! String || peerId == _deviceId) {
          continue;
        }

        final peerName = data['name'] is String
            ? data['name'] as String
            : peerId;
        final port = data['port'] is int ? data['port'] as int : lanTcpPort;
        final now = DateTime.now();
        final peer = _LanPeer(
          id: peerId,
          name: peerName,
          address: datagram.address,
          port: port,
          lastSeen: now,
        );

        final existing = _lanPeers[peerId];
        _lanPeers[peerId] = peer;
        if (existing == null && mounted) {
          setState(() {});
        }

        _maybeConnectToLanPeer(peer);
      } catch (_) {
        // Ignore malformed LAN discovery packets.
      }
    }
  }

  void _sendLanAnnounce() {
    final socket = _lanSocket;
    if (socket == null) {
      return;
    }

    final data = <String, dynamic>{
      'type': 'lan_announce',
      'id': _deviceId,
      'name': _deviceName,
      'port': lanTcpPort,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    };
    final bytes = utf8.encode(jsonEncode(data));
    try {
      socket.send(bytes, InternetAddress('255.255.255.255'), lanDiscoveryPort);
    } catch (error) {
      _addLog('LAN announce failed: $error');
    }

    _pruneLanPeers();
  }

  void _pruneLanPeers() {
    if (_lanPeers.isEmpty) {
      return;
    }

    final now = DateTime.now();
    final stalePeers = _lanPeers.entries
        .where((entry) => now.difference(entry.value.lastSeen) > lanPeerTimeout)
        .map((entry) => entry.key)
        .toList();

    if (stalePeers.isEmpty) {
      return;
    }

    for (final peerId in stalePeers) {
      _lanPeers.remove(peerId);
    }

    if (mounted) {
      setState(() {});
    }
  }

  void _maybeConnectToLanPeer(_LanPeer peer) {
    if (_lanConnections.containsKey(peer.id) ||
        _lanPendingConnections.contains(peer.id)) {
      return;
    }

    if (!_shouldInitiateLanConnection(peer.id)) {
      return;
    }

    _lanPendingConnections.add(peer.id);
    unawaited(_connectToLanPeer(peer));
  }

  bool _shouldInitiateLanConnection(String peerId) {
    return _deviceId.compareTo(peerId) < 0;
  }

  Future<void> _connectToLanPeer(_LanPeer peer) async {
    try {
      final socket = await Socket.connect(
        peer.address,
        peer.port,
        timeout: const Duration(seconds: 3),
      );
      _handleLanSocket(socket, outbound: true);
    } catch (error) {
      _addLog(
        'LAN connect failed to ${peer.name} (${peer.address.address}:${peer.port}): $error',
      );
    } finally {
      _lanPendingConnections.remove(peer.id);
    }
  }

  void _handleLanSocket(Socket socket, {required bool outbound}) {
    final connection = _LanConnection(socket: socket, outbound: outbound);
    connection.subscription = socket
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          (line) => _onLanLine(connection, line),
          onError: (error) => _removeLanConnection(connection, error: error),
          onDone: () => _removeLanConnection(connection),
          cancelOnError: true,
        );

    _sendLanHello(connection);
  }

  void _sendLanHello(_LanConnection connection) {
    final data = <String, dynamic>{
      'type': 'lan_hello',
      'id': _deviceId,
      'name': _deviceName,
    };
    connection.sendJson(jsonEncode(data));
  }

  void _onLanLine(_LanConnection connection, String line) {
    try {
      final data = jsonDecode(line);
      if (data is! Map<String, dynamic>) {
        return;
      }

      final type = data['type'];
      if (type == 'lan_hello') {
        final peerId = data['id'];
        final peerName = data['name'];
        if (peerId is String) {
          _registerLanConnection(
            connection,
            peerId: peerId,
            peerName: peerName is String ? peerName : peerId,
          );
        }
        return;
      }

      if (connection.peerId != null) {
        final label = 'LAN:${connection.peerName ?? connection.peerId}';
        _handleIncomingMessage(label, line);
      }
    } catch (_) {
      if (connection.peerId != null) {
        final label = 'LAN:${connection.peerName ?? connection.peerId}';
        _handleIncomingMessage(label, line);
      }
    }
  }

  void _registerLanConnection(
    _LanConnection connection, {
    required String peerId,
    required String peerName,
  }) {
    if (peerId == _deviceId) {
      unawaited(connection.close());
      return;
    }

    final existing = _lanConnections[peerId];
    if (existing != null && existing != connection) {
      final preferOutbound = _shouldInitiateLanConnection(peerId);
      final keepNew = preferOutbound
          ? connection.outbound
          : !connection.outbound;
      if (!keepNew) {
        unawaited(connection.close());
        return;
      }
      unawaited(existing.close());
    }

    connection.peerId = peerId;
    connection.peerName = peerName;
    _lanConnections[peerId] = connection;

    if (mounted) {
      setState(() {});
    }

    _addLog('LAN connected: $peerName ($peerId).');

    if (_lastNoteUpdateMs > 0) {
      _sendNoteUpdateToLanPeer(peerId, _lastNoteUpdateMs);
      _addLog('Sent shared note snapshot to LAN peer $peerName.');
    }
  }

  void _removeLanConnection(_LanConnection connection, {Object? error}) {
    final peerId = connection.peerId;
    if (peerId != null && _lanConnections[peerId] == connection) {
      _lanConnections.remove(peerId);
      if (mounted) {
        setState(() {});
      }
      final name = connection.peerName ?? peerId;
      _addLog('LAN disconnected: $name.');
    }

    if (error != null) {
      _addLog('LAN socket error: $error');
    }

    unawaited(connection.close());
  }

  void _onEndpointFound(
    String endpointId,
    String endpointName,
    String service,
  ) {
    if (!mounted) {
      return;
    }
    if (_endpointNames.containsKey(endpointId)) {
      return;
    }

    if (_connectedEndpoints.length >= maxPeers) {
      _addLog('Max peers reached ($maxPeers). Ignoring $endpointName.');
      return;
    }

    setState(() {
      _endpointNames[endpointId] = endpointName;
      _connectingEndpoints.add(endpointId);
    });

    _addLog('Found peer: $endpointName ($endpointId). Requesting connection.');

    Nearby().requestConnection(
      _deviceName,
      endpointId,
      onConnectionInitiated: _onConnectionInitiated,
      onConnectionResult: _onConnectionResult,
      onDisconnected: _onDisconnected,
    );
  }

  void _onEndpointLost(String? endpointId) {
    if (!mounted) {
      return;
    }
    if (endpointId == null) {
      _addLog('Lost peer with unknown endpoint id.');
      return;
    }
    final name = _endpointNames[endpointId] ?? endpointId;
    _addLog('Lost peer: $name ($endpointId).');
    setState(() {
      _endpointNames.remove(endpointId);
      _connectedEndpoints.remove(endpointId);
      _connectingEndpoints.remove(endpointId);
    });
  }

  void _onConnectionInitiated(String endpointId, ConnectionInfo info) {
    if (_connectedEndpoints.length >= maxPeers) {
      _addLog('Rejecting $endpointId. Max peers reached.');
      Nearby().rejectConnection(endpointId);
      return;
    }

    if (mounted && !_endpointNames.containsKey(endpointId)) {
      setState(() {
        _endpointNames[endpointId] = info.endpointName;
        _connectingEndpoints.add(endpointId);
      });
    }

    _addLog(
      'Connection initiated with ${info.endpointName}. Token: ${info.authenticationToken}',
    );

    Nearby().acceptConnection(
      endpointId,
      onPayLoadRecieved: _onPayloadReceived,
      onPayloadTransferUpdate: _onPayloadTransferUpdate,
    );
  }

  void _onConnectionResult(String endpointId, Status status) {
    if (!mounted) {
      return;
    }
    final name = _endpointNames[endpointId] ?? endpointId;
    _addLog('Connection result for $name: $status');

    setState(() {
      _connectingEndpoints.remove(endpointId);
      if (status == Status.CONNECTED) {
        _connectedEndpoints.add(endpointId);
      } else {
        _connectedEndpoints.remove(endpointId);
      }
    });

    if (status == Status.CONNECTED && _lastNoteUpdateMs > 0) {
      unawaited(_sendNoteUpdateToEndpoint(endpointId, _lastNoteUpdateMs));
      _addLog('Sent shared note snapshot to $name.');
    }
  }

  void _onDisconnected(String endpointId) {
    if (!mounted) {
      return;
    }
    final name = _endpointNames[endpointId] ?? endpointId;
    _addLog('Disconnected from $name ($endpointId).');
    setState(() {
      _connectedEndpoints.remove(endpointId);
    });
  }

  void _onPayloadReceived(String endpointId, Payload payload) {
    if (payload.type != PayloadType.BYTES) {
      _addLog('Received non-bytes payload from $endpointId.');
      return;
    }

    final bytes = payload.bytes;
    if (bytes == null) {
      _addLog('Received empty payload from $endpointId.');
      return;
    }

    final message = utf8.decode(bytes);
    _handleIncomingMessage(endpointId, message);
  }

  void _onPayloadTransferUpdate(
    String endpointId,
    PayloadTransferUpdate update,
  ) {
    if (update.status == PayloadStatus.SUCCESS) {
      _addLog('Payload transfer complete from $endpointId.');
    } else if (update.status == PayloadStatus.FAILURE) {
      _addLog('Payload transfer failed from $endpointId.');
    }
  }

  String _newMessageId() {
    final id =
        '$_deviceId-${DateTime.now().microsecondsSinceEpoch}-${_messageCounter++}';
    _rememberMessageId(id);
    return id;
  }

  bool _rememberMessageId(String id) {
    if (_recentMessageIds.contains(id)) {
      return false;
    }
    _recentMessageIds.add(id);
    _recentMessageOrder.add(id);
    if (_recentMessageOrder.length > maxRecentMessages) {
      final oldest = _recentMessageOrder.removeAt(0);
      _recentMessageIds.remove(oldest);
    }
    return true;
  }

  void _handleIncomingMessage(String endpointLabel, String message) {
    try {
      final data = jsonDecode(message);
      if (data is Map<String, dynamic>) {
        final id = data['id'];
        if (id is String && !_rememberMessageId(id)) {
          return;
        }
        final type = data['type'];
        if (type == 'note_update') {
          _applyRemoteNoteUpdate(endpointLabel, data);
          return;
        }
        if (type == 'chat') {
          final text = data['message'];
          final from = data['from'];
          if (text is String) {
            final sender = from is String && from.isNotEmpty
                ? from
                : endpointLabel;
            _addLog('Message from $sender: $text');
            return;
          }
        }
        _addLog('From $endpointLabel: ${data.toString()}');
      } else {
        _addLog('From $endpointLabel: $message');
      }
    } catch (_) {
      _addLog('From $endpointLabel: $message');
    }
  }

  Future<void> _sendMessage() async {
    final text = _messageController.text.trim();
    if (text.isEmpty) {
      return;
    }

    if (_connectedEndpoints.isEmpty &&
        _lanConnections.isEmpty &&
        _wifiDirectConnected == 0) {
      _addLog('No connected peers to send to.');
      return;
    }

    final data = <String, dynamic>{
      'id': _newMessageId(),
      'type': 'chat',
      'message': text,
      'timestamp': DateTime.now().toIso8601String(),
      'from': _deviceName,
    };

    await _sendJsonToAll(data);
    _messageController.clear();
    _addLog(
      'Sent message to ${_connectedEndpoints.length + _lanConnections.length + _wifiDirectConnected} peer(s).',
    );
  }

  Future<void> _sendJsonToAll(Map<String, dynamic> data) async {
    final jsonMessage = jsonEncode(data);
    final bytes = Uint8List.fromList(utf8.encode(jsonMessage));
    for (final endpointId in _connectedEndpoints) {
      try {
        await Nearby().sendBytesPayload(endpointId, bytes);
      } catch (error) {
        _addLog('Send failed to $endpointId: $error');
      }
    }

    _sendJsonToLan(jsonMessage);
    await _sendJsonToWifiDirect(jsonMessage);
  }

  Future<void> _sendBytesToEndpoint(String endpointId, Uint8List bytes) async {
    try {
      await Nearby().sendBytesPayload(endpointId, bytes);
    } catch (error) {
      _addLog('Send failed to $endpointId: $error');
    }
  }

  void _sendJsonToLan(String jsonMessage) {
    if (_lanConnections.isEmpty) {
      return;
    }
    for (final connection in _lanConnections.values) {
      connection.sendJson(jsonMessage);
    }
  }

  void _sendJsonToLanPeer(String peerId, String jsonMessage) {
    final connection = _lanConnections[peerId];
    if (connection == null) {
      return;
    }
    connection.sendJson(jsonMessage);
  }

  Future<void> _sendJsonToWifiDirect(String jsonMessage) async {
    if (!_wifiDirectRunning) {
      return;
    }
    try {
      await _wifiDirectChannel.invokeMethod('send', <String, dynamic>{
        'payload': jsonMessage,
      });
    } catch (error) {
      _addLog('Wi-Fi Direct send failed: $error');
    }
  }

  Future<void> _sendNoteUpdateToWifiDirect() async {
    if (_lastNoteUpdateMs <= 0) {
      return;
    }

    final data = <String, dynamic>{
      'id': _newMessageId(),
      'type': 'note_update',
      'note': _sharedNoteController.text,
      'timestamp': _lastNoteUpdateMs,
      'from': _deviceName,
    };

    final jsonMessage = jsonEncode(data);
    await _sendJsonToWifiDirect(jsonMessage);
  }

  void _onSharedNoteChanged() {
    if (_suppressNoteBroadcast) {
      return;
    }

    _noteDebounce?.cancel();
    _noteDebounce = Timer(
      const Duration(milliseconds: 400),
      _broadcastNoteUpdate,
    );
  }

  Future<void> _broadcastNoteUpdate() async {
    final note = _sharedNoteController.text;
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    _lastNoteUpdateMs = timestamp;

    if (_connectedEndpoints.isEmpty &&
        _lanConnections.isEmpty &&
        _wifiDirectConnected == 0) {
      return;
    }

    final data = <String, dynamic>{
      'id': _newMessageId(),
      'type': 'note_update',
      'note': note,
      'timestamp': timestamp,
      'from': _deviceName,
    };

    await _sendJsonToAll(data);
    _addLog(
      'Synced shared note to ${_connectedEndpoints.length + _lanConnections.length + _wifiDirectConnected} peer(s).',
    );
  }

  Future<void> _sendNoteUpdateToEndpoint(
    String endpointId,
    int timestamp,
  ) async {
    final data = <String, dynamic>{
      'id': _newMessageId(),
      'type': 'note_update',
      'note': _sharedNoteController.text,
      'timestamp': timestamp,
      'from': _deviceName,
    };

    final jsonMessage = jsonEncode(data);
    final bytes = Uint8List.fromList(utf8.encode(jsonMessage));
    await _sendBytesToEndpoint(endpointId, bytes);
  }

  void _sendNoteUpdateToLanPeer(String peerId, int timestamp) {
    final data = <String, dynamic>{
      'id': _newMessageId(),
      'type': 'note_update',
      'note': _sharedNoteController.text,
      'timestamp': timestamp,
      'from': _deviceName,
    };

    final jsonMessage = jsonEncode(data);
    _sendJsonToLanPeer(peerId, jsonMessage);
  }

  void _applyRemoteNoteUpdate(String endpointId, Map<String, dynamic> data) {
    final timestamp = data['timestamp'];
    if (timestamp is! int) {
      _addLog('Invalid note update from $endpointId.');
      return;
    }

    if (timestamp <= _lastNoteUpdateMs) {
      return;
    }

    final note = data['note'];
    if (note is! String) {
      _addLog('Invalid note payload from $endpointId.');
      return;
    }

    _lastNoteUpdateMs = timestamp;
    _suppressNoteBroadcast = true;
    _sharedNoteController.text = note;
    _sharedNoteController.selection = TextSelection.collapsed(
      offset: _sharedNoteController.text.length,
    );
    _suppressNoteBroadcast = false;
    _addLog('Applied shared note from $endpointId.');
  }

  void _addLog(String message) {
    if (!mounted) {
      return;
    }

    final timestamp = TimeOfDay.now().format(context);
    setState(() {
      _logs.add('[$timestamp] $message');
      if (_logs.length > maxLogEntries) {
        _logs.removeAt(0);
      }
    });

    if (_logScrollController.hasClients) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_logScrollController.hasClients) {
          _logScrollController.jumpTo(
            _logScrollController.position.maxScrollExtent,
          );
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(title: const Text('Inflata')),
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [Color(0xFFF6F7F4), Color(0xFFE8F1EC)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: SafeArea(
          child: CustomScrollView(
            slivers: [
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
                  child: _buildHeader(),
                ),
              ),
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
                sliver: SliverList(
                  delegate: SliverChildListDelegate([
                    _buildStatusCard(),
                    const SizedBox(height: 16),
                    _buildControlCard(),
                    const SizedBox(height: 16),
                    _buildMessageCard(),
                    const SizedBox(height: 16),
                    _buildSharedNoteCard(),
                    const SizedBox(height: 16),
                    _buildPeersCard(),
                    const SizedBox(height: 16),
                    _buildNotesCard(),
                    const SizedBox(height: 16),
                    _buildLogsCard(),
                  ]),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Peer-to-peer workspace',
          style: Theme.of(
            context,
          ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 6),
        Text(
          'Connect nearby devices, sync notes, and broadcast updates securely.',
          style: Theme.of(
            context,
          ).textTheme.bodyMedium?.copyWith(color: _kMuted),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _StatusPill(
              label: 'Session',
              value: _running ? 'Active' : 'Idle',
              isActive: _running,
            ),
            _StatusPill(
              label: 'Peers',
              value:
                  '${_connectedEndpoints.length + _lanConnections.length + _wifiDirectConnected}',
              isActive:
                  _connectedEndpoints.isNotEmpty ||
                  _lanConnections.isNotEmpty ||
                  _wifiDirectConnected > 0,
            ),
            _StatusPill(
              label: 'LAN',
              value: _lanRunning ? 'On' : 'Off',
              isActive: _lanRunning,
            ),
            if (Platform.isAndroid)
              _StatusPill(
                label: 'Wi-Fi Direct',
                value: _wifiDirectRunning ? 'On' : 'Off',
                isActive: _wifiDirectRunning,
              ),
          ],
        ),
      ],
    );
  }

  Widget _buildStatusCard() {
    return _SurfaceCard(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _SectionHeader(title: 'Status', subtitle: 'Live transport health'),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _StatusPill(
                  label: 'Running',
                  value: _running ? 'On' : 'Off',
                  isActive: _running,
                ),
                _StatusPill(
                  label: 'Advertising',
                  value: _advertising ? 'On' : 'Off',
                  isActive: _advertising,
                ),
                _StatusPill(
                  label: 'Discovery',
                  value: _discovering ? 'On' : 'Off',
                  isActive: _discovering,
                ),
                _StatusPill(
                  label: 'Nearby',
                  value: '${_connectedEndpoints.length}/$maxPeers',
                  isActive: _connectedEndpoints.isNotEmpty,
                ),
                _StatusPill(
                  label: 'LAN',
                  value: _lanRunning ? 'On' : 'Off',
                  isActive: _lanRunning,
                ),
                _StatusPill(
                  label: 'LAN peers',
                  value: '${_lanConnections.length}',
                  isActive: _lanConnections.isNotEmpty,
                ),
                if (Platform.isAndroid) ...[
                  _StatusPill(
                    label: 'Wi-Fi Direct',
                    value: _wifiDirectRunning ? 'On' : 'Off',
                    isActive: _wifiDirectRunning,
                  ),
                  _StatusPill(
                    label: 'WFD peers',
                    value: '$_wifiDirectConnected',
                    isActive: _wifiDirectConnected > 0,
                  ),
                  _StatusPill(
                    label: 'WFD seen',
                    value: '$_wifiDirectDiscovered',
                    isActive: _wifiDirectDiscovered > 0,
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildControlCard() {
    return _SurfaceCard(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _SectionHeader(title: 'Controls', subtitle: 'Name and session'),
            const SizedBox(height: 14),
            TextField(
              controller: _nameController,
              decoration: const InputDecoration(labelText: 'Device name'),
            ),
            if (Platform.isAndroid) ...[
              const SizedBox(height: 14),
              _InlineSwitch(
                title: 'Wi-Fi Direct host',
                subtitle: 'Enable on one device to act as group owner.',
                value: _wifiDirectHostPreferred,
                onChanged: _running
                    ? null
                    : (value) {
                        setState(() {
                          _wifiDirectHostPreferred = value;
                        });
                      },
              ),
            ],
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: ElevatedButton(
                    onPressed: _running ? null : _startInflata,
                    child: const Text('Start'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton(
                    onPressed: _running ? _stopInflata : null,
                    child: const Text('Stop'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPeersCard() {
    final nearbyPeers = _endpointNames.entries.toList();
    final lanPeers = _lanConnections.values.toList();
    return _SurfaceCard(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _SectionHeader(title: 'Peers', subtitle: 'Active connections'),
            const SizedBox(height: 12),
            Text(
              'Nearby',
              style: Theme.of(
                context,
              ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
            ),
            if (nearbyPeers.isEmpty)
              Text(
                'No Nearby peers discovered yet.',
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: _kMuted),
              )
            else
              ...nearbyPeers.map((entry) {
                final status = _connectedEndpoints.contains(entry.key)
                    ? 'connected'
                    : _connectingEndpoints.contains(entry.key)
                    ? 'connecting'
                    : 'discovered';
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Text(
                    '${entry.value} (${entry.key}) - $status',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                );
              }),
            const SizedBox(height: 12),
            Text(
              'LAN',
              style: Theme.of(
                context,
              ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
            ),
            if (lanPeers.isEmpty)
              Text(
                'No LAN peers connected yet.',
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: _kMuted),
              )
            else
              ...lanPeers.map((peer) {
                final label = peer.peerName ?? peer.peerId ?? 'unknown';
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Text(
                    "$label (${peer.peerId ?? 'unknown'}) - connected",
                  ),
                );
              }),
          ],
        ),
      ),
    );
  }

  Widget _buildMessageCard() {
    return _SurfaceCard(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _SectionHeader(
              title: 'Broadcast',
              subtitle: 'Send a message to all connected peers',
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _messageController,
              minLines: 1,
              maxLines: 3,
              decoration: const InputDecoration(labelText: 'Message'),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _sendMessage,
                child: const Text('Send to all connected'),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Tip: Nearby Connections supports ~4MB per bytes payload. Chunk larger data.',
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: _kMuted),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSharedNoteCard() {
    return _SurfaceCard(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _SectionHeader(
              title: 'Shared Note',
              subtitle: 'Live sync to every connected device',
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _sharedNoteController,
              minLines: 5,
              maxLines: 10,
              decoration: const InputDecoration(
                hintText: 'Type here. Changes sync automatically.',
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Updates are last-writer-wins using timestamps. Keep devices on similar clocks.',
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: _kMuted),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildNotesCard() {
    return _SurfaceCard(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _SectionHeader(
              title: 'Best Practices',
              subtitle: 'Operational reminders',
            ),
            const SizedBox(height: 12),
            _BulletLine(
              text:
                  'Use physical Android devices. Emulators do not support Wi-Fi Direct.',
            ),
            const SizedBox(height: 6),
            const _BulletLine(
              text: 'Limit clusters to about 10-20 devices for reliability.',
            ),
            const SizedBox(height: 6),
            const _BulletLine(
              text: 'Start discovery only when needed to save battery.',
            ),
            const SizedBox(height: 6),
            const _BulletLine(
              text:
                  'Validate authentication tokens before auto-accept in production.',
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLogsCard() {
    return _SurfaceCard(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _SectionHeader(title: 'Logs', subtitle: 'Recent activity'),
            const SizedBox(height: 12),
            SizedBox(
              height: 220,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: _kSurfaceAlt,
                  border: Border.all(color: _kBorder),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: ListView.builder(
                  controller: _logScrollController,
                  padding: const EdgeInsets.all(12),
                  itemCount: _logs.length,
                  itemBuilder: (context, index) => Text(
                    _logs[index],
                    style: Theme.of(
                      context,
                    ).textTheme.bodySmall?.copyWith(color: _kMuted),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SurfaceCard extends StatelessWidget {
  const _SurfaceCard({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: _kSurface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: _kBorder),
        boxShadow: const [
          BoxShadow(
            color: Color(0x12000000),
            blurRadius: 16,
            offset: Offset(0, 8),
          ),
        ],
      ),
      child: child,
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, required this.subtitle});

  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: Theme.of(
            context,
          ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 4),
        Text(
          subtitle,
          style: Theme.of(
            context,
          ).textTheme.bodySmall?.copyWith(color: _kMuted),
        ),
      ],
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({
    required this.label,
    required this.value,
    required this.isActive,
  });

  final String label;
  final String value;
  final bool isActive;

  @override
  Widget build(BuildContext context) {
    final background = isActive ? _kAccentSoft : _kSurfaceAlt;
    final border = isActive ? _kAccent : _kBorder;
    final textColor = isActive ? _kAccent : _kMuted;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: textColor,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            value,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: textColor),
          ),
        ],
      ),
    );
  }
}

class _InlineSwitch extends StatelessWidget {
  const _InlineSwitch({
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: _kSurfaceAlt,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _kBorder),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: Theme.of(
                    context,
                  ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 4),
                Text(
                  subtitle,
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(color: _kMuted),
                ),
              ],
            ),
          ),
          Switch(value: value, onChanged: onChanged),
        ],
      ),
    );
  }
}

class _BulletLine extends StatelessWidget {
  const _BulletLine({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          margin: const EdgeInsets.only(top: 6),
          height: 6,
          width: 6,
          decoration: const BoxDecoration(
            color: _kAccent,
            shape: BoxShape.circle,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            text,
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(color: _kMuted),
          ),
        ),
      ],
    );
  }
}

class _LanPeer {
  _LanPeer({
    required this.id,
    required this.name,
    required this.address,
    required this.port,
    required this.lastSeen,
  });

  final String id;
  final String name;
  final InternetAddress address;
  final int port;
  final DateTime lastSeen;
}

class _LanConnection {
  _LanConnection({required this.socket, required this.outbound});

  final Socket socket;
  final bool outbound;
  String? peerId;
  String? peerName;
  StreamSubscription<String>? subscription;

  void sendJson(String jsonMessage) {
    socket.add(utf8.encode(jsonMessage));
    socket.add(const [10]);
  }

  Future<void> close() async {
    await subscription?.cancel();
    socket.destroy();
  }
}
