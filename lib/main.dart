import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/material.dart';
import 'package:nearby_connections/nearby_connections.dart';
import 'package:permission_handler/permission_handler.dart';

const String serviceId = 'com.example.network.inflata';
const int maxPeers = 20;
const int maxLogEntries = 200;

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
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
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

  bool _running = false;
  bool _advertising = false;
  bool _discovering = false;
  final Map<String, String> _endpointNames = <String, String>{};
  final Set<String> _connectedEndpoints = <String>{};
  final Set<String> _connectingEndpoints = <String>{};
  final List<String> _logs = <String>[];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _nameController.text = 'Inflata-${DateTime.now().millisecondsSinceEpoch % 10000}';
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

    try {
      _addLog('Starting advertising and discovery...');
      final advertising = await Nearby().startAdvertising(
        _deviceName,
        serviceId,
        Strategy.P2P_CLUSTER,
        onConnectionInitiated: _onConnectionInitiated,
        onConnectionResult: _onConnectionResult,
        onDisconnected: _onDisconnected,
      );

      final discovering = await Nearby().startDiscovery(
        _deviceName,
        serviceId,
        Strategy.P2P_CLUSTER,
        onEndpointFound: _onEndpointFound,
        onEndpointLost: _onEndpointLost,
      );

      if (!mounted) {
        return;
      }

      setState(() {
        _advertising = advertising;
        _discovering = discovering;
      });

      _addLog('Advertising: $advertising, Discovery: $discovering');
    } catch (error) {
      _addLog('Start error: $error');
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

  void _onEndpointFound(String endpointId, String endpointName, String service) {
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

  void _onEndpointLost(String endpointId) {
    if (!mounted) {
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
      onPayloadReceived: _onPayloadReceived,
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
    try {
      final data = jsonDecode(message);
      if (data is Map<String, dynamic>) {
        final type = data['type'];
        if (type == 'note_update') {
          _applyRemoteNoteUpdate(endpointId, data);
          return;
        }
        _addLog('From $endpointId: ${data.toString()}');
      } else {
        _addLog('From $endpointId: $message');
      }
    } catch (_) {
      _addLog('From $endpointId: $message');
    }
  }

  void _onPayloadTransferUpdate(String endpointId, PayloadTransferUpdate update) {
    if (update.status == PayloadStatus.SUCCESS) {
      _addLog('Payload transfer complete from $endpointId.');
    } else if (update.status == PayloadStatus.FAILURE) {
      _addLog('Payload transfer failed from $endpointId.');
    }
  }

  Future<void> _sendMessage() async {
    final text = _messageController.text.trim();
    if (text.isEmpty) {
      return;
    }

    if (_connectedEndpoints.isEmpty) {
      _addLog('No connected peers to send to.');
      return;
    }

    final data = <String, dynamic>{
      'type': 'chat',
      'message': text,
      'timestamp': DateTime.now().toIso8601String(),
      'from': _deviceName,
    };

    final jsonMessage = jsonEncode(data);
    final bytes = Uint8List.fromList(utf8.encode(jsonMessage));

    await _sendBytesToAll(bytes);

    _messageController.clear();
    _addLog('Sent message to ${_connectedEndpoints.length} peer(s).');
  }

  Future<void> _sendBytesToAll(Uint8List bytes) async {
    for (final endpointId in _connectedEndpoints) {
      try {
        await Nearby().sendBytesPayload(endpointId, bytes);
      } catch (error) {
        _addLog('Send failed to $endpointId: $error');
      }
    }
  }

  void _onSharedNoteChanged() {
    if (_suppressNoteBroadcast) {
      return;
    }

    _noteDebounce?.cancel();
    _noteDebounce = Timer(const Duration(milliseconds: 400), _broadcastNoteUpdate);
  }

  Future<void> _broadcastNoteUpdate() async {
    if (_connectedEndpoints.isEmpty) {
      return;
    }

    final note = _sharedNoteController.text;
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    _lastNoteUpdateMs = timestamp;

    final data = <String, dynamic>{
      'type': 'note_update',
      'note': note,
      'timestamp': timestamp,
      'from': _deviceName,
    };

    final jsonMessage = jsonEncode(data);
    final bytes = Uint8List.fromList(utf8.encode(jsonMessage));
    await _sendBytesToAll(bytes);
    _addLog('Synced shared note to ${_connectedEndpoints.length} peer(s).');
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
      appBar: AppBar(
        title: const Text('Inflata P2P'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _buildStatusCard(),
          const SizedBox(height: 16),
          _buildControlCard(),
          const SizedBox(height: 16),
          _buildPeersCard(),
          const SizedBox(height: 16),
          _buildMessageCard(),
          const SizedBox(height: 16),
          _buildSharedNoteCard(),
          const SizedBox(height: 16),
          _buildNotesCard(),
          const SizedBox(height: 16),
          _buildLogsCard(),
        ],
      ),
    );
  }

  Widget _buildStatusCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Status',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text('Running: ${_running ? 'Yes' : 'No'}'),
            Text('Advertising: ${_advertising ? 'Yes' : 'No'}'),
            Text('Discovery: ${_discovering ? 'Yes' : 'No'}'),
            Text('Connected: ${_connectedEndpoints.length}/$maxPeers'),
          ],
        ),
      ),
    );
  }

  Widget _buildControlCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Controls',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _nameController,
              decoration: const InputDecoration(
                labelText: 'Device name',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
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
    final peers = _endpointNames.entries.toList();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Peers',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            if (peers.isEmpty)
              const Text('No peers discovered yet.')
            else
              ...peers.map((entry) {
                final status = _connectedEndpoints.contains(entry.key)
                    ? 'connected'
                    : _connectingEndpoints.contains(entry.key)
                        ? 'connecting'
                        : 'discovered';
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Text('${entry.value} (${entry.key}) - $status'),
                );
              }),
          ],
        ),
      ),
    );
  }

  Widget _buildMessageCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Send Message',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _messageController,
              minLines: 1,
              maxLines: 3,
              decoration: const InputDecoration(
                labelText: 'Message',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _sendMessage,
                child: const Text('Send to all connected'),
              ),
            ),
            const SizedBox(height: 4),
            const Text(
              'Tip: Nearby Connections supports ~4MB per bytes payload. Chunk larger data.',
              style: TextStyle(fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSharedNoteCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Shared Note (Syncs to all connected phones)',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _sharedNoteController,
              minLines: 5,
              maxLines: 10,
              decoration: const InputDecoration(
                hintText: 'Type here. Changes sync automatically.',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Updates are last-writer-wins using timestamps. Keep devices on similar clocks.',
              style: TextStyle(fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildNotesCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: const [
            Text(
              'Best Practices',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            SizedBox(height: 8),
            Text('Use physical Android devices. Emulators do not support Wi-Fi Direct.'),
            Text('Limit clusters to about 10-20 devices for reliability.'),
            Text('Start discovery only when needed to save battery.'),
            Text('Validate authentication tokens before auto-accept in production.'),
          ],
        ),
      ),
    );
  }

  Widget _buildLogsCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Logs',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: 220,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.black12),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: ListView.builder(
                  controller: _logScrollController,
                  padding: const EdgeInsets.all(8),
                  itemCount: _logs.length,
                  itemBuilder: (context, index) => Text(
                    _logs[index],
                    style: const TextStyle(fontSize: 12),
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
