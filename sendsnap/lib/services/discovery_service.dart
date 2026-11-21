import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import '../models/device.dart';
import 'network_info_service.dart';
import 'http_transfer_client.dart';
import 'http_transfer_server.dart';

class DiscoveryService {
  static const int discoveryPort = 53317;
  static const String protocolTag = 'sendsnap-v1';
  static const String multicastGroup = '224.0.0.167';

  final HttpTransferClient _probeClient = HttpTransferClient();

  RawDatagramSocket? _socket;
  Timer? _broadcastTimer;
  Timer? _cleanupTimer;
  Timer? _sweepTimer;
  Timer? _initialSweepDelayTimer;
  final List<Timer> _burstTimers = [];

  NearbyDevice? _myDevice;
  Set<String> _localIps = {};
  bool _isReceiver = false;
  bool _isPassive = false;
  bool _running = false;
  bool _isSweeping = false;
  bool _isCleaningUp = false;

  final Map<String, NearbyDevice> _discoveredDevices = {};

  // Callbacks
  Function(NearbyDevice)? onDeviceFound;
  Function(String)? onDeviceLost;

  List<NearbyDevice> get devices => _discoveredDevices.values.toList();
  bool get isRunning => _running;
  bool get isPassive => _isPassive;

  /// Filters incoming discovery packets by local vs remote role so idle/sender apps
  /// running warm discovery do not appear as receivers.
  static bool shouldAcceptPacket({
    required bool localIsReceiver,
    required String? remoteRole,
  }) {
    if (!localIsReceiver) {
      return remoteRole == null || remoteRole == 'receiver';
    }
    return true;
  }

  Future<bool> startDiscovery({
    required NearbyDevice localDevice,
    bool isReceiver = false,
    bool isPassive = false,
  }) async {
    _myDevice = localDevice;
    _isReceiver = isReceiver;
    _isPassive = isPassive;

    if (_running && _socket != null) {
      // Update in-place without clearing discovered peers or bouncing sockets
      _refreshTimers();
      unawaited(triggerBurst());
      return true;
    }

    _discoveredDevices.clear();
    _running = true;

    await NetworkInfoService.acquireMulticastLock();
    await _refreshLocalIps();

    try {
      _socket = await _bindDiscoverySocket();
      _socket!.broadcastEnabled = true;

      await _joinMulticastOnLanInterfaces(_socket!);

      _socket!.listen(
        (RawSocketEvent event) {
          if (event == RawSocketEvent.read) {
            Datagram? datagram;
            while ((datagram = _socket?.receive()) != null) {
              _handleIncomingDatagram(datagram!);
            }
          }
        },
        onError: (e) {
          debugPrint('[DiscoveryService] Socket error: $e');
        },
      );

      // Rapid initial burst so peers appear in <300ms
      _scheduleInitialBurst();

      // Periodic UDP heartbeat & cleanup & fast subnet sweep
      _refreshTimers();

      if (!_isReceiver) {
        _initialSweepDelayTimer?.cancel();
        _initialSweepDelayTimer = Timer(const Duration(milliseconds: 350), () {
          if (_running && !_isReceiver) {
            _performSubnetSweep();
          }
        });
      }

      debugPrint(
        '[DiscoveryService] Started (receiver=$_isReceiver, passive=$_isPassive) on port $discoveryPort for ${localDevice.name}',
      );
      return true;
    } catch (e) {
      debugPrint('[DiscoveryService] Failed to start discovery: $e');
      _running = false;
      return false;
    }
  }

  Future<RawDatagramSocket> _bindDiscoverySocket() async {
    if (!Platform.isWindows) {
      try {
        return await RawDatagramSocket.bind(
          InternetAddress.anyIPv4,
          discoveryPort,
          reuseAddress: true,
          reusePort: true,
        );
      } catch (_) {
        // Fallback if OS / kernel rejects SO_REUSEPORT
      }
    }
    return await RawDatagramSocket.bind(
      InternetAddress.anyIPv4,
      discoveryPort,
      reuseAddress: true,
    );
  }

  Future<void> _joinMulticastOnLanInterfaces(RawDatagramSocket socket) async {
    final groupAddr = InternetAddress(multicastGroup);
    bool joinedAny = false;
    try {
      final interfaces = await NetworkInfoService.getLanInterfaces();
      for (final iface in interfaces) {
        try {
          socket.joinMulticast(groupAddr, iface);
          joinedAny = true;
        } catch (e) {
          debugPrint('[DiscoveryService] Multicast join note on ${iface.name}: $e');
        }
      }
    } catch (_) {}

    if (!joinedAny) {
      try {
        socket.joinMulticast(groupAddr);
      } catch (e) {
        debugPrint('[DiscoveryService] Default multicast join note: $e');
      }
    }
  }

  Future<void> _refreshLocalIps() async {
    try {
      final ips = await NetworkInfoService.getLocalIpAddresses();
      _localIps = ips.toSet();
      if (_myDevice != null && ips.isNotEmpty && !ips.contains(_myDevice!.ip)) {
        _myDevice = _myDevice!.copyWith(ip: ips.first);
      }
    } catch (_) {}
  }

  void updateLocalDevice(NearbyDevice device) {
    _myDevice = device;
  }

  /// Switches between passive warm-up cadence and active Send cadence without
  /// tearing down sockets or clearing already-discovered devices.
  void setPassiveMode(bool isPassive) {
    final wasPassive = _isPassive;
    _isPassive = isPassive;
    if (!_running) return;
    _refreshTimers();
    if (wasPassive && !isPassive) {
      unawaited(triggerBurst());
    }
  }

  Future<void> triggerBurst() async {
    if (!_running || _socket == null || _myDevice == null) return;
    await _refreshLocalIps();
    _scheduleInitialBurst();
    if (!_isReceiver) {
      unawaited(_performSubnetSweep());
    }
  }

  void _refreshTimers() {
    _broadcastTimer?.cancel();
    final udpInterval = _isPassive
        ? const Duration(milliseconds: 3500)
        : const Duration(milliseconds: 1500);
    _broadcastTimer = Timer.periodic(udpInterval, (_) {
      if (_running) {
        _sendBroadcast(_isReceiver ? 'ANNOUNCE' : 'DISCOVER');
      }
    });

    _cleanupTimer?.cancel();
    _cleanupTimer = Timer.periodic(const Duration(seconds: 4), (_) {
      if (_running) {
        _cleanupStaleDevices();
      }
    });

    _sweepTimer?.cancel();
    if (!_isReceiver) {
      final sweepInterval = _isPassive
          ? const Duration(seconds: 20)
          : const Duration(seconds: 8);
      _sweepTimer = Timer.periodic(sweepInterval, (_) {
        if (!_running || _isReceiver) return;
        if (!_isPassive || _discoveredDevices.isEmpty) {
          _performSubnetSweep();
        }
      });
    }
  }

  void _scheduleInitialBurst() {
    _cancelBurstTimers();
    final type = _isReceiver ? 'ANNOUNCE' : 'DISCOVER';
    _sendBroadcast(type);
    for (final delayMs in const [150, 400, 900]) {
      _burstTimers.add(
        Timer(Duration(milliseconds: delayMs), () {
          if (_running) {
            _sendBroadcast(type);
          }
        }),
      );
    }
  }

  void _cancelBurstTimers() {
    for (final t in _burstTimers) {
      t.cancel();
    }
    _burstTimers.clear();
  }

  void _handleIncomingDatagram(Datagram datagram) {
    try {
      final message = utf8.decode(datagram.data, allowMalformed: true);
      final json = jsonDecode(message) as Map<String, dynamic>;

      if (json['protocol'] != protocolTag) return;

      final type = json['type'] as String?;
      final remoteRole = json['role'] as String?;
      final deviceData = json['device'] as Map<String, dynamic>?;

      if (deviceData == null) return;

      final device = NearbyDevice.fromJson(deviceData);

      // Ignore our own broadcast / looped-back multicast packets
      final senderAddr = datagram.address.address;
      if (_myDevice != null &&
          (device.id == _myDevice!.id ||
              _localIps.contains(senderAddr) ||
              (device.ip.isNotEmpty &&
                  device.ip != '0.0.0.0' &&
                  _localIps.contains(device.ip)))) {
        return;
      }

      // Receiver always replies immediately with double unicast ANNOUNCE when pinged with DISCOVER
      if (type == 'DISCOVER' && _isReceiver && _myDevice != null) {
        _sendDirect(datagram.address, discoveryPort, 'ANNOUNCE');
        if (datagram.port != discoveryPort) {
          _sendDirect(datagram.address, datagram.port, 'ANNOUNCE');
        }
        Timer(const Duration(milliseconds: 80), () {
          if (_running && _isReceiver) {
            _sendDirect(datagram.address, discoveryPort, 'ANNOUNCE');
          }
        });
      }

      if (!shouldAcceptPacket(localIsReceiver: _isReceiver, remoteRole: remoteRole)) {
        return;
      }

      if (_isReceiver) return;

      final verifiedIp =
          (device.ip.isEmpty || device.ip == '0.0.0.0') ? senderAddr : device.ip;

      final updatedDevice = device.copyWith(
        ip: verifiedIp,
        connectionType: 'lan',
        lastSeen: DateTime.now(),
      );

      if (type == 'ANNOUNCE' || type == 'DISCOVER') {
        _discoveredDevices[updatedDevice.id] = updatedDevice;
        onDeviceFound?.call(updatedDevice);
      } else if (type == 'BYE') {
        _discoveredDevices.remove(device.id);
        onDeviceLost?.call(device.id);
      }
    } catch (_) {
      // Malformed or unrelated packet
    }
  }

  Future<void> _sendBroadcast(String type) async {
    if (_socket == null || _myDevice == null) return;

    try {
      final localIps = await NetworkInfoService.getLocalIpAddresses();
      if (localIps.isEmpty) return;

      final broadcastIps = await NetworkInfoService.getBroadcastAddresses();
      final packetData = utf8.encode(jsonEncode({
        'protocol': protocolTag,
        'type': type,
        'role': _isReceiver ? 'receiver' : 'sender',
        'device': _myDevice!.toJson(),
      }));

      for (final broadcastIp in broadcastIps) {
        try {
          _socket?.send(packetData, InternetAddress(broadcastIp), discoveryPort);
        } catch (_) {}
      }
    } catch (e) {
      debugPrint('[DiscoveryService] Broadcast error: $e');
    }
  }

  void _sendDirect(InternetAddress address, int port, String type) {
    if (_socket == null || _myDevice == null) return;
    try {
      final packetData = utf8.encode(jsonEncode({
        'protocol': protocolTag,
        'type': type,
        'role': _isReceiver ? 'receiver' : 'sender',
        'device': _myDevice!.toJson(),
      }));
      _socket?.send(packetData, address, port);
    } catch (e) {
      debugPrint('[DiscoveryService] Direct send error: $e');
    }
  }

  /// Concurrently sweeps all valid LAN /24 subnets using a 64-worker pool and
  /// fast 350ms TCP port probes (~1.2s total worst-case instead of ~80s).
  Future<void> _performSubnetSweep() async {
    if (_isSweeping || _myDevice == null || !_running) return;
    _isSweeping = true;

    try {
      final ips = await NetworkInfoService.getLocalIpAddresses();
      if (ips.isEmpty) return;

      final seenPrefixes = <String>{};
      final targetIps = <String>[];

      for (final localIp in ips) {
        final parts = localIp.split('.');
        if (parts.length != 4) continue;
        final prefix = '${parts[0]}.${parts[1]}.${parts[2]}.';
        if (!seenPrefixes.add(prefix)) continue;

        final myLastOctet = int.tryParse(parts[3]) ?? -1;
        final orderedOctets = _buildPrioritizedOctets(myLastOctet);
        for (final octet in orderedOctets) {
          targetIps.add('$prefix$octet');
        }
      }

      if (targetIps.isEmpty) return;

      int cursor = 0;
      const workerCount = 64;
      final effectiveWorkers =
          targetIps.length < workerCount ? targetIps.length : workerCount;

      Future<void> runWorker() async {
        while (_running && _socket != null) {
          final idx = cursor++;
          if (idx >= targetIps.length) break;
          final targetIp = targetIps[idx];
          try {
            final dev = await _probeClient.fastProbe(
              targetIp,
              HttpTransferServer.defaultPort,
              connectTimeout: const Duration(milliseconds: 350),
            );
            if (dev != null && dev.id != _myDevice?.id && _running) {
              final verified = dev.copyWith(
                connectionType: 'lan',
                lastSeen: DateTime.now(),
              );
              _discoveredDevices[verified.id] = verified;
              onDeviceFound?.call(verified);
              debugPrint(
                '[DiscoveryService] Discovered via fast sweep: ${verified.name} at ${verified.ip}',
              );
            }
          } catch (_) {}
        }
      }

      await Future.wait(List.generate(effectiveWorkers, (_) => runWorker()));
    } catch (e) {
      debugPrint('[DiscoveryService] Subnet sweep error: $e');
    } finally {
      _isSweeping = false;
    }
  }

  List<int> _buildPrioritizedOctets(int myLastOctet) {
    final added = <int>{};
    final result = <int>[];

    void addIfValid(int host) {
      if (host >= 1 && host <= 254 && host != myLastOctet && added.add(host)) {
        result.add(host);
      }
    }

    // 1. Closest neighbor IPs around local address
    if (myLastOctet >= 1 && myLastOctet <= 254) {
      for (int offset = 1; offset <= 25; offset++) {
        addIfValid(myLastOctet + offset);
        addIfValid(myLastOctet - offset);
      }
    }

    // 2. Common DHCP / router-assigned pools
    for (int host = 1; host <= 40; host++) {
      addIfValid(host);
    }
    for (int host = 100; host <= 160; host++) {
      addIfValid(host);
    }

    // 3. Remaining /24 space
    for (int host = 1; host <= 254; host++) {
      addIfValid(host);
    }

    return result;
  }

  void triggerSubnetSweep() {
    _performSubnetSweep();
  }

  Future<void> _cleanupStaleDevices() async {
    if (_isCleaningUp) return;
    _isCleaningUp = true;

    try {
      final now = DateTime.now();
      final entries = _discoveredDevices.entries.toList();

      for (final entry in entries) {
        final ageSeconds = now.difference(entry.value.lastSeen).inSeconds;
        if (ageSeconds <= 8) continue;

        bool stillAlive = false;
        if (entry.value.hasLanIp) {
          final pinged = await _probeClient.ping(
            entry.value.ip,
            entry.value.port,
            timeout: const Duration(milliseconds: 900),
          );
          if (pinged != null) {
            stillAlive = true;
            _discoveredDevices[entry.key] = pinged.copyWith(
              connectionType: 'lan',
              p2pDeviceAddress: entry.value.p2pDeviceAddress,
              p2pSsid: entry.value.p2pSsid,
              p2pPassphrase: entry.value.p2pPassphrase,
              p2pGoIp: entry.value.p2pGoIp,
              lastSeen: DateTime.now(),
            );
          }
        }

        if (!stillAlive && ageSeconds > 15) {
          _discoveredDevices.remove(entry.key);
          onDeviceLost?.call(entry.key);
        }
      }
    } finally {
      _isCleaningUp = false;
    }
  }

  /// Manually add a device discovered by direct IP ping or QR code.
  void registerManualDevice(NearbyDevice device) {
    _discoveredDevices[device.id] = device;
    onDeviceFound?.call(device);
  }

  Future<void> stopDiscovery() async {
    _running = false;
    _cancelBurstTimers();
    _initialSweepDelayTimer?.cancel();
    _initialSweepDelayTimer = null;

    try {
      if (_socket != null && _myDevice != null) {
        await _sendBroadcast('BYE');
      }
    } catch (_) {}

    _broadcastTimer?.cancel();
    _broadcastTimer = null;
    _cleanupTimer?.cancel();
    _cleanupTimer = null;
    _sweepTimer?.cancel();
    _sweepTimer = null;

    try {
      _socket?.close();
      _socket = null;
    } catch (_) {}

    _discoveredDevices.clear();
    await NetworkInfoService.releaseMulticastLock();
    debugPrint('[DiscoveryService] Stopped discovery');
  }
}
