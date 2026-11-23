import 'dart:async';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
import '../models/air_session.dart';
import '../models/device.dart';
import '../models/transfer.dart';
import 'network_info_service.dart';
import 'discovery_service.dart';
import 'direct_p2p_service.dart';
import 'http_transfer_server.dart';
import 'http_transfer_client.dart';

class NearbyService {
  final DiscoveryService _discoveryService = DiscoveryService();
  final DirectP2pService _directP2p = DirectP2pService();
  final HttpTransferServer _httpServer = HttpTransferServer();
  final HttpTransferClient _httpClient = HttpTransferClient();

  final Map<String, NearbyDevice> _knownDevices = {};
  NearbyDevice? _localDevice;
  String? _deviceId;

  bool _isAdvertising = false;
  bool _isActiveDiscovering = false;
  bool _isWarmDiscovering = false;
  DirectHotspotInfo? _activeHotspotInfo;
  Timer? _p2pCleanupTimer;

  // Callbacks for DeviceProvider
  Function(NearbyDevice)? onDeviceFound;
  Function(String)? onDeviceLost;
  Function(String, String)? onConnectionInitiated; // endpointId, deviceName
  Function(String, bool)? onConnectionResult; // endpointId, success
  Function(String)? onDisconnected;
  Function(DirectHotspotInfo?)? onHotspotInfoChanged;
  Function(bool)? onWifiStateChanged;
  Function(AirGrabSession)? onAirGrabReceived;
  Function(String token)? onAirCancelReceived;
  Function(String token, NearbyDevice claimer)? onAirClaimReceived;
  Function(NearbyDevice sender, String airToken)? onAirWifiDirectSenderFound;
  AirGrabSession? Function()? onAirActiveRequested;

  // Callbacks for TransferProvider
  Function(NearbyDevice sender, FileTransfer transfer)? onIncomingTransfer;
  Function(String sessionId, NearbyDevice sender, List<FileTransfer> files)?
      onIncomingTransferBatch;
  Function(String transferId, int bytesTransferred, int totalBytes, double speed)?
      onTransferProgress;
  Function(String transferId, String savedPath)? onTransferCompleted;
  Function(String transferId, String error)? onTransferFailed;
  Function(String transferId)? onTransferCancelled;
  Function(String transferId, bool paused)? onTransferPausedChanged;
  Function(Map<String, dynamic> event)? onPortalEvent;

  // Active outgoing session controls
  String? _activeOutgoingSessionId;
  NearbyDevice? _activeOutgoingTarget;
  final List<String> _activeOutgoingFileIds = [];
  bool _sessionCancelled = false;
  bool _batchPaused = false;
  final Set<String> _cancelledFileIds = {};
  final Set<String> _pausedFileIds = {};
  String? _currentUploadingFileId;
  CancelToken? _currentFileCancelToken;
  Completer<void>? _stateChangeSignal;

  NearbyDevice? get localDevice => _localDevice;
  HttpTransferServer get httpServer => _httpServer;
  HttpTransferClient get httpClient => _httpClient;
  DirectP2pService get directP2p => _directP2p;
  DirectHotspotInfo? get activeHotspotInfo => _activeHotspotInfo;
  bool get isWarmDiscovering => _isWarmDiscovering;

  NearbyService() {
    _deviceId = const Uuid().v4().substring(0, 8);
    _directP2p.initialize();
    _setupDiscoveryCallbacks();
    _setupDirectP2pCallbacks();
    _setupServerCallbacks();
  }

  void _setupDiscoveryCallbacks() {
    _discoveryService.onDeviceFound = (device) {
      if (device.id == _deviceId) return;
      _mergeDiscoveredDevice(device);
    };

    _discoveryService.onDeviceLost = (deviceId) {
      final existing = _knownDevices[deviceId];
      if (existing == null) return;
      if (existing.hasDirectCredentials &&
          DateTime.now().difference(existing.lastSeen).inSeconds < 30) {
        // Demote to Wi-Fi Direct so cross-Wi-Fi fallback stays available
        final demoted = existing.copyWith(
          ip: '',
          connectionType: 'wifi_direct',
        );
        _knownDevices[deviceId] = demoted;
        onDeviceFound?.call(demoted);
      } else {
        _knownDevices.remove(deviceId);
        onDeviceLost?.call(deviceId);
      }
    };

    _discoveryService.onAirGrabReceived = (session) {
      if (session.sender.id == _deviceId) return;
      _mergeDiscoveredDevice(session.sender);
      onAirGrabReceived?.call(session);
    };

    _discoveryService.onAirCancelReceived = (token) {
      onAirCancelReceived?.call(token);
    };

    _discoveryService.onAirClaimReceived = (token, claimer) {
      if (claimer.id == _deviceId) return;
      _mergeDiscoveredDevice(claimer);
      onAirClaimReceived?.call(token, claimer);
    };
  }

  void _setupDirectP2pCallbacks() {
    _directP2p.onNsdDeviceFound = (device) {
      if (device.id == _deviceId) return;
      _mergeDiscoveredDevice(device);
    };

    _directP2p.onNsdDeviceLost = (deviceId) async {
      final existing = _knownDevices[deviceId];
      if (existing == null) return;
      if (existing.hasLanIp) {
        final alive = await _httpClient.ping(
          existing.ip,
          existing.port,
          timeout: const Duration(milliseconds: 800),
        );
        if (alive != null) return;
      }
      if (!existing.hasDirectCredentials) {
        _knownDevices.remove(deviceId);
        onDeviceLost?.call(deviceId);
      }
    };

    _directP2p.onWifiDirectDeviceFound = (device) {
      if (device.id == _deviceId) return;
      _mergeDiscoveredDevice(device);
    };

    _directP2p.onAirWifiDirectSenderFound = (sender, airToken) {
      if (sender.id == _deviceId) return;
      onAirWifiDirectSenderFound?.call(sender, airToken);
    };

    _directP2p.onDirectHotspotReady = (hotspot) {
      _activeHotspotInfo = hotspot;
      onHotspotInfoChanged?.call(hotspot);
    };

    _directP2p.onDirectConnectionChanged = (connected, goIp) {
      debugPrint('[NearbyService] Direct connection changed: connected=$connected goIp=$goIp');
    };

    _directP2p.onWifiStateChanged = (enabled) {
      onWifiStateChanged?.call(enabled);
    };
  }

  String _hexPrefix12(String? id) {
    if (id == null || id.isEmpty) return '';
    final stripped = (id.startsWith('ble-') ? id.substring(4) : id)
        .replaceAll('-', '')
        .toLowerCase();
    final hexOnly = stripped.replaceAll(RegExp(r'[^0-9a-f]'), '');
    if (hexOnly.isEmpty) return '';
    final trimmed = hexOnly.length > 12 ? hexOnly.substring(0, 12) : hexOnly;
    return trimmed.padRight(12, '0');
  }

  void _mergeDiscoveredDevice(NearbyDevice incoming) {
    if (incoming.id.isEmpty || incoming.id == _deviceId) return;

    var resolvedIncoming = incoming;
    final prefix12 = _hexPrefix12(resolvedIncoming.id);

    if (resolvedIncoming.id.startsWith('ble-')) {
      final localPrefix12 = _hexPrefix12(_deviceId);
      if (prefix12.isNotEmpty && prefix12 == localPrefix12) {
        return;
      }
      if (prefix12.isNotEmpty) {
        for (final key in _knownDevices.keys) {
          if (!key.startsWith('ble-') && _hexPrefix12(key) == prefix12) {
            resolvedIncoming = resolvedIncoming.copyWith(id: key);
            break;
          }
        }
      }
    }

    NearbyDevice? removedBleFallback;
    if (!resolvedIncoming.id.startsWith('ble-') && prefix12.isNotEmpty) {
      final bleKey = 'ble-$prefix12';
      if (_knownDevices.containsKey(bleKey)) {
        removedBleFallback = _knownDevices.remove(bleKey);
        onDeviceLost?.call(bleKey);
      }
    }

    final existing = _knownDevices[resolvedIncoming.id] ?? removedBleFallback;
    late NearbyDevice merged;

    final incomingHasRealName = resolvedIncoming.name != 'Unknown' &&
        resolvedIncoming.name != 'SendSnap Device';

    if (existing == null) {
      merged = resolvedIncoming.copyWith(lastSeen: DateTime.now());
    } else if (resolvedIncoming.connectionType == 'lan' &&
        resolvedIncoming.hasLanIp) {
      // LAN / NSD / Sweep takes priority over Wi-Fi Direct while preserving P2P fallback info
      merged = resolvedIncoming.copyWith(
        name: incomingHasRealName || existing.name == 'Unknown'
            ? resolvedIncoming.name
            : existing.name,
        deviceType: resolvedIncoming.deviceType != 'unknown'
            ? resolvedIncoming.deviceType
            : existing.deviceType,
        connectionType: 'lan',
        p2pDeviceAddress:
            resolvedIncoming.p2pDeviceAddress ?? existing.p2pDeviceAddress,
        p2pSsid: resolvedIncoming.p2pSsid?.isNotEmpty == true
            ? resolvedIncoming.p2pSsid
            : existing.p2pSsid,
        p2pPassphrase: resolvedIncoming.p2pPassphrase?.isNotEmpty == true
            ? resolvedIncoming.p2pPassphrase
            : existing.p2pPassphrase,
        p2pGoIp: resolvedIncoming.p2pGoIp?.isNotEmpty == true
            ? resolvedIncoming.p2pGoIp
            : existing.p2pGoIp,
        lastSeen: DateTime.now(),
      );
    } else if (resolvedIncoming.isWifiDirect) {
      final recentLan = existing.connectionType == 'lan' &&
          existing.hasLanIp &&
          DateTime.now().difference(existing.lastSeen).inSeconds < 12;
      if (recentLan) {
        merged = existing.copyWith(
          name: incomingHasRealName ? resolvedIncoming.name : existing.name,
          p2pDeviceAddress:
              resolvedIncoming.p2pDeviceAddress ?? existing.p2pDeviceAddress,
          p2pSsid: resolvedIncoming.p2pSsid?.isNotEmpty == true
              ? resolvedIncoming.p2pSsid
              : existing.p2pSsid,
          p2pPassphrase: resolvedIncoming.p2pPassphrase?.isNotEmpty == true
              ? resolvedIncoming.p2pPassphrase
              : existing.p2pPassphrase,
          p2pGoIp: resolvedIncoming.p2pGoIp?.isNotEmpty == true
              ? resolvedIncoming.p2pGoIp
              : existing.p2pGoIp,
          lastSeen: DateTime.now(),
        );
      } else {
        merged = resolvedIncoming.copyWith(
          name: incomingHasRealName || existing.name == 'Unknown'
              ? resolvedIncoming.name
              : existing.name,
          deviceType: resolvedIncoming.deviceType != 'unknown'
              ? resolvedIncoming.deviceType
              : existing.deviceType,
          p2pDeviceAddress:
              resolvedIncoming.p2pDeviceAddress ?? existing.p2pDeviceAddress,
          p2pSsid: resolvedIncoming.p2pSsid?.isNotEmpty == true
              ? resolvedIncoming.p2pSsid
              : existing.p2pSsid,
          p2pPassphrase: resolvedIncoming.p2pPassphrase?.isNotEmpty == true
              ? resolvedIncoming.p2pPassphrase
              : existing.p2pPassphrase,
          p2pGoIp: resolvedIncoming.p2pGoIp?.isNotEmpty == true
              ? resolvedIncoming.p2pGoIp
              : existing.p2pGoIp,
          lastSeen: DateTime.now(),
        );
      }
    } else {
      merged = resolvedIncoming.copyWith(lastSeen: DateTime.now());
    }

    _knownDevices[merged.id] = merged;
    onDeviceFound?.call(merged);
  }

  void _setupServerCallbacks() {
    _httpServer.onRequestReceived = ({
      required String sessionId,
      required NearbyDevice sender,
      required List<FileTransfer> files,
    }) async {
      debugPrint(
        '[NearbyService] Incoming transfer request from ${sender.name} (${files.length} files)',
      );
      _knownDevices[sender.id] = sender;
      onConnectionInitiated?.call(sender.id, sender.name);

      if (onIncomingTransferBatch != null) {
        onIncomingTransferBatch!(sessionId, sender, files);
      } else {
        for (final file in files) {
          onIncomingTransfer?.call(sender, file);
        }
      }

      onConnectionResult?.call(sender.id, true);
      return true; // Auto-accept incoming transfer
    };

    _httpServer.onProgress = ({
      required String sessionId,
      required String fileId,
      required int bytesReceived,
      required int totalBytes,
      required double speed,
    }) {
      onTransferProgress?.call(fileId, bytesReceived, totalBytes, speed);
    };

    _httpServer.onFileCompleted = ({
      required String sessionId,
      required String fileId,
      required String savedPath,
    }) {
      onTransferCompleted?.call(fileId, savedPath);
    };

    _httpServer.onFileFailed = ({
      required String sessionId,
      required String fileId,
      required String error,
    }) {
      onTransferFailed?.call(fileId, error);
    };

    _httpServer.onFileCancelled = ({
      required String sessionId,
      required String fileId,
    }) {
      onTransferCancelled?.call(fileId);
    };

    _httpServer.onPortalEvent = (event) {
      onPortalEvent?.call(event);
    };

    _httpServer.onAirGrabReceived = (session) {
      if (session.sender.id == _deviceId) return;
      _mergeDiscoveredDevice(session.sender);
      onAirGrabReceived?.call(session);
    };

    _httpServer.onAirCancelReceived = (token) {
      onAirCancelReceived?.call(token);
    };

    _httpServer.onAirClaimReceived = (token, claimer) {
      if (claimer.id == _deviceId) return;
      _mergeDiscoveredDevice(claimer);
      onAirClaimReceived?.call(token, claimer);
    };

    _httpServer.onAirActiveRequested = () {
      return onAirActiveRequested?.call();
    };
  }

  Future<NearbyDevice> _ensureLocalDevice(String deviceName) async {
    final localIp = await NetworkInfoService.getLocalIpAddress() ?? '0.0.0.0';
    _deviceId ??= const Uuid().v4().substring(0, 8);

    _localDevice = NearbyDevice(
      id: _deviceId!,
      name: deviceName,
      ip: localIp,
      port: HttpTransferServer.defaultPort,
      deviceType: NetworkInfoService.getPlatformName(),
    );
    return _localDevice!;
  }

  void _ensureP2pCleanupTimer() {
    _p2pCleanupTimer?.cancel();
    _p2pCleanupTimer = Timer.periodic(const Duration(seconds: 8), (_) async {
      final now = DateTime.now();
      final entries = _knownDevices.entries.toList();
      for (final entry in entries) {
        if (!entry.value.isWifiDirect) continue;
        if (now.difference(entry.value.lastSeen).inSeconds <= 35) continue;

        if (entry.value.hasLanIp) {
          final alive = await _httpClient.ping(
            entry.value.ip,
            entry.value.port,
            timeout: const Duration(milliseconds: 900),
          );
          if (alive != null) {
            _knownDevices[entry.key] = entry.value.copyWith(lastSeen: DateTime.now());
            continue;
          }
        }

        _knownDevices.remove(entry.key);
        onDeviceLost?.call(entry.key);
      }
    });
  }

  /// Starts low-overhead background discovery on HomeScreen launch so receivers
  /// appear immediately before the user finishes picking files.
  Future<bool> startWarmDiscovery(String deviceName) async {
    if (_isAdvertising || _isActiveDiscovering) return true;
    try {
      final local = await _ensureLocalDevice(deviceName);
      _isWarmDiscovering = true;

      await _discoveryService.startDiscovery(
        localDevice: local,
        isReceiver: false,
        isPassive: true,
      );
      await _directP2p.startNsdDiscovery(localId: local.id);
      await _directP2p.startWifiDirectDiscovery(isPassive: true);
      _ensureP2pCleanupTimer();

      debugPrint('[NearbyService] Warm discovery active for ${local.name}');
      return true;
    } catch (e) {
      debugPrint('[NearbyService] startWarmDiscovery error: $e');
      return false;
    }
  }

  /// Immediately boosts discovery cadence while the user is picking files.
  Future<void> boostWarmDiscovery() async {
    if (_isAdvertising) return;
    try {
      NetworkInfoService.invalidateCache();
      if (_localDevice != null) {
        final ip = await NetworkInfoService.getLocalIpAddress() ?? '0.0.0.0';
        _localDevice = _localDevice!.copyWith(ip: ip);
        _discoveryService.updateLocalDevice(_localDevice!);
      }
      await _discoveryService.triggerBurst();
      await _directP2p.startWifiDirectDiscovery(isPassive: false);
    } catch (e) {
      debugPrint('[NearbyService] boostWarmDiscovery note: $e');
    }
  }

  /// Refreshes local IP and re-announces the receiver immediately after
  /// returning from Hotspot / Wi-Fi settings.
  Future<void> refreshAdvertisingNetwork(String deviceName) async {
    if (!_isAdvertising) return;
    try {
      NetworkInfoService.invalidateCache();
      final ip = await NetworkInfoService.getLocalIpAddress() ?? '0.0.0.0';
      final base = _localDevice ?? await _ensureLocalDevice(deviceName);
      _localDevice = base.copyWith(ip: ip);
      if (_discoveryService.isRunning) {
        _discoveryService.updateLocalDevice(_localDevice!);
        await _discoveryService.triggerBurst();
      } else {
        await _discoveryService.startDiscovery(
          localDevice: _localDevice!,
          isReceiver: true,
          isPassive: false,
        );
      }
    } catch (e) {
      debugPrint('[NearbyService] refreshAdvertisingNetwork note: $e');
    }
  }

  /// Pauses warm discovery when app enters background (only if idle).
  Future<void> pauseWarmDiscovery() async {
    if (!_isWarmDiscovering || _isAdvertising || _isActiveDiscovering) return;
    _isWarmDiscovering = false;
    _p2pCleanupTimer?.cancel();
    _p2pCleanupTimer = null;
    await _discoveryService.stopDiscovery();
    await _directP2p.stopNsdDiscovery();
    await _directP2p.stopWifiDirectDiscovery();
  }

  /// Promotes warm discovery in-place to active Send mode without clearing
  /// already-discovered devices or recreating sockets.
  Future<bool> promoteToActiveDiscovery(String deviceName) async {
    try {
      final local = await _ensureLocalDevice(deviceName);
      if (_isAdvertising) {
        await stopAll(disconnectDirect: false);
      }

      _isActiveDiscovering = true;
      _isWarmDiscovering = false;

      if (_discoveryService.isRunning) {
        _discoveryService.updateLocalDevice(local);
        _discoveryService.setPassiveMode(false);
      } else {
        await _discoveryService.startDiscovery(
          localDevice: local,
          isReceiver: false,
          isPassive: false,
        );
      }

      await _directP2p.startNsdDiscovery(localId: local.id);
      await _directP2p.startWifiDirectDiscovery(isPassive: false);
      _ensureP2pCleanupTimer();

      debugPrint('[NearbyService] Active discovery running for ${local.name}');
      return true;
    } catch (e) {
      debugPrint('[NearbyService] promoteToActiveDiscovery error: $e');
      return false;
    }
  }

  /// Start receiving mode (Embedded HTTP Server + LAN UDP/NSD + Android Direct Wi-Fi GO).
  Future<bool> startAdvertising(String deviceName) async {
    try {
      debugPrint('[NearbyService] Starting advertising as $deviceName...');
      await _stopDiscoveryOnly();
      _knownDevices.clear();

      final local = await _ensureLocalDevice(deviceName);

      // 1. Start embedded HTTP server on 0.0.0.0:53318
      final boundPort = await _httpServer.startServer(localDevice: local);
      if (boundPort == null) {
        debugPrint('[NearbyService] Failed to start HTTP server');
        return false;
      }

      _isAdvertising = true;
      _isActiveDiscovering = false;
      _isWarmDiscovering = false;
      _localDevice = local.copyWith(port: boundPort);

      // 2. Start LAN UDP broadcast / multicast announcements
      final discoveryOk = await _discoveryService.startDiscovery(
        localDevice: _localDevice!,
        isReceiver: true,
        isPassive: false,
      );

      // 3. Register Android NSD (_sendsnap._tcp.)
      await _directP2p.startNsdAdvertising(
        id: _localDevice!.id,
        name: _localDevice!.name,
        port: boundPort,
        deviceType: _localDevice!.deviceType,
      );

      // 4. Start Android Wi-Fi Direct Group Owner + DNS-SD service (works without router!)
      final directOk = await _directP2p.startWifiDirectAdvertising(
        id: _localDevice!.id,
        name: _localDevice!.name,
        port: boundPort,
      );

      debugPrint(
        '[NearbyService] Advertising active on ${_localDevice!.ip}:$boundPort (lan=$discoveryOk, direct=$directOk)',
      );
      return true;
    } catch (e) {
      debugPrint('[NearbyService] Advertising error: $e');
      return false;
    }
  }

  /// Start sending mode (Listen for receiving devices on Wi-Fi & Direct Wi-Fi).
  Future<bool> startDiscovery(String deviceName) async {
    return promoteToActiveDiscovery(deviceName);
  }

  Future<void> _stopDiscoveryOnly() async {
    _isActiveDiscovering = false;
    _isWarmDiscovering = false;
    _p2pCleanupTimer?.cancel();
    _p2pCleanupTimer = null;
    await _discoveryService.stopDiscovery();
    await _directP2p.stopNsdDiscovery();
    await _directP2p.stopWifiDirectDiscovery();
  }

  Future<void> stopAll({bool disconnectDirect = true}) async {
    try {
      _isAdvertising = false;
      await _stopDiscoveryOnly();
      await _httpServer.stopServer();
      await _directP2p.stopNsdAdvertising();
      await _directP2p.stopWifiDirectAdvertising();
      if (disconnectDirect) {
        await _directP2p.disconnectDirect();
      }
      _activeHotspotInfo = null;
      onHotspotInfoChanged?.call(null);
      _knownDevices.clear();
      debugPrint('[NearbyService] Stopped all services');
    } catch (e) {
      debugPrint('[NearbyService] stopAll error: $e');
    }
  }

  NearbyDevice? getDevice(String endpointId) {
    final directMatch = _knownDevices[endpointId];
    if (directMatch != null) return directMatch;

    final prefix = _hexPrefix12(endpointId);
    if (prefix.isEmpty) return null;

    for (final device in _knownDevices.values) {
      if (_hexPrefix12(device.id) == prefix) {
        return device;
      }
    }
    return null;
  }

  void addManualDevice(NearbyDevice device) {
    _knownDevices[device.id] = device;
    _discoveryService.registerManualDevice(device);
  }

  /// Request connection/handshake with a discovered target device.
  /// Automatically establishes a Direct Wi-Fi link if LAN IP is unavailable/unreachable.
  Future<bool> requestConnection(String deviceName, String endpointId) async {
    final target = getDevice(endpointId);
    if (target == null) {
      debugPrint('[NearbyService] Unknown endpointId: $endpointId');
      return false;
    }
    final resolvedId = target.id;

    try {
      onConnectionInitiated?.call(resolvedId, target.name);

      // 1. Try direct LAN ping first when a LAN IP is known
      if (target.hasLanIp && !target.isWifiDirect) {
        final pingDevice = await _httpClient.ping(target.ip, target.port);
        if (pingDevice != null) {
          final updated = pingDevice.copyWith(
            connectionType: 'lan',
            p2pDeviceAddress: target.p2pDeviceAddress,
            p2pSsid: target.p2pSsid,
            p2pPassphrase: target.p2pPassphrase,
            p2pGoIp: target.p2pGoIp,
            lastSeen: DateTime.now(),
          );
          _knownDevices[resolvedId] = updated;
          onDeviceFound?.call(updated);
          onConnectionResult?.call(resolvedId, true);
          return true;
        }
      }

      // 2. Automatic cross-Wi-Fi Direct connect on Android
      if (Platform.isAndroid &&
          (target.hasDirectCredentials || target.p2pDeviceAddress != null)) {
        final connectRes = await _directP2p.connectToPeer(
          ssid: target.p2pSsid,
          passphrase: target.p2pPassphrase,
          deviceAddress: target.p2pDeviceAddress,
          goIp: target.p2pGoIp,
          port: target.port,
        );
        if (connectRes.success && connectRes.goIp != null) {
          NetworkInfoService.invalidateCache();
          final pingDevice =
              await _httpClient.pingWithRetry(connectRes.goIp!, target.port);
          if (pingDevice != null) {
            final updated = target.copyWith(
              name: pingDevice.name,
              ip: connectRes.goIp!,
              port: target.port,
              deviceType: pingDevice.deviceType != 'unknown'
                  ? pingDevice.deviceType
                  : target.deviceType,
              connectionType: target.connectionType,
              lastSeen: DateTime.now(),
            );
            _knownDevices[resolvedId] = updated;
            onDeviceFound?.call(updated);
            onConnectionResult?.call(resolvedId, true);
            return true;
          }
          await _directP2p.disconnectDirect();
        }
      }

      if (Platform.isAndroid && _isActiveDiscovering) {
        unawaited(_directP2p.startWifiDirectDiscovery(isPassive: false));
      }
      onConnectionResult?.call(resolvedId, false);
      return false;
    } catch (e) {
      debugPrint('[NearbyService] requestConnection error: $e');
      if (Platform.isAndroid && _isActiveDiscovering) {
        unawaited(_directP2p.startWifiDirectDiscovery(isPassive: false));
      }
      onConnectionResult?.call(resolvedId, false);
      return false;
    }
  }

  /// Parses an enriched or legacy QR code and connects via LAN or Direct Wi-Fi auto-join.
  Future<NearbyDevice?> connectFromQrData(String rawQr) async {
    final parsed = DirectP2pService.parseQrPayload(rawQr);
    if (parsed == null) return null;

    // 1. Fast LAN ping first if QR contains a router IP
    if (parsed.hasUsableLanIp) {
      final lanDevice = await _httpClient.ping(
        parsed.lanIp!,
        parsed.port,
        timeout: const Duration(milliseconds: 900),
      );
      if (lanDevice != null) {
        final enriched = lanDevice.copyWith(
          connectionType: 'lan',
          p2pSsid: parsed.ssid,
          p2pPassphrase: parsed.passphrase,
          p2pGoIp: parsed.p2pIp,
          lastSeen: DateTime.now(),
        );
        addManualDevice(enriched);
        return enriched;
      }
    }

    // 2. Auto-join Direct Wi-Fi / Hotspot on Android if credentials are embedded
    if (Platform.isAndroid && parsed.hasDirectCredentials) {
      final res = await _directP2p.connectToPeer(
        ssid: parsed.ssid,
        passphrase: parsed.passphrase,
        goIp: parsed.p2pIp,
        port: parsed.port,
      );
      if (res.success) {
        final targetIp = res.goIp ?? parsed.p2pIp ?? '192.168.49.1';
        NetworkInfoService.invalidateCache();
        final directDev = await _httpClient.pingWithRetry(targetIp, parsed.port);
        if (directDev != null) {
          final enriched = directDev.copyWith(
            ip: targetIp,
            port: parsed.port,
            connectionType: 'wifi_direct',
            p2pSsid: parsed.ssid,
            p2pPassphrase: parsed.passphrase,
            p2pGoIp: targetIp,
            lastSeen: DateTime.now(),
          );
          addManualDevice(enriched);
          return enriched;
        }
        await _directP2p.disconnectDirect();
      }
    }

    // 3. Fallback direct ping to p2pIp if device already manually joined receiver's hotspot
    if (parsed.p2pIp != null &&
        parsed.p2pIp!.isNotEmpty &&
        parsed.p2pIp != parsed.lanIp) {
      final directPing = await _httpClient.ping(
        parsed.p2pIp!,
        parsed.port,
        timeout: const Duration(milliseconds: 900),
      );
      if (directPing != null) {
        final enriched = directPing.copyWith(
          connectionType: 'wifi_direct',
          p2pSsid: parsed.ssid,
          p2pPassphrase: parsed.passphrase,
          p2pGoIp: parsed.p2pIp,
          lastSeen: DateTime.now(),
        );
        addManualDevice(enriched);
        return enriched;
      }
    }

    return null;
  }

  Future<void> acceptConnection(String endpointId) async {
    // Handled automatically via HTTP protocol
  }

  Future<void> rejectConnection(String endpointId) async {
    // Handled automatically
  }

  /// Uploads a single file to the target device.
  Future<bool> sendFileStream({
    required NearbyDevice target,
    required FileTransfer transfer,
    required File file,
  }) async {
    return sendFilesStream(
      target: target,
      transfers: [transfer],
      files: [file],
    );
  }

  void _signalStateChange() {
    final completer = _stateChangeSignal;
    if (completer != null && !completer.isCompleted) {
      completer.complete();
    }
    _stateChangeSignal = null;
  }

  Future<void> _waitForStateChange() {
    final completer = _stateChangeSignal ??= Completer<void>();
    return completer.future;
  }

  Future<void> cancelActiveBatch() async {
    _sessionCancelled = true;
    _batchPaused = false;
    _pausedFileIds.clear();
    _currentFileCancelToken?.cancel('Batch cancelled by user');
    _signalStateChange();

    final target = _activeOutgoingTarget;
    final sessionId = _activeOutgoingSessionId;
    if (target != null && sessionId != null) {
      await _httpClient.cancelTransfer(target: target, sessionId: sessionId);
    }
  }

  Future<void> cancelFileTransfer(String transferId) async {
    _cancelledFileIds.add(transferId);
    _pausedFileIds.remove(transferId);
    if (_currentUploadingFileId == transferId) {
      _currentFileCancelToken?.cancel('File cancelled by user');
    }
    _signalStateChange();
    onTransferCancelled?.call(transferId);

    final target = _activeOutgoingTarget;
    final sessionId = _activeOutgoingSessionId;
    if (target != null && sessionId != null) {
      await _httpClient.cancelTransfer(
        target: target,
        sessionId: sessionId,
        fileId: transferId,
      );
    }
  }

  void setBatchPaused(bool paused) {
    _batchPaused = paused;
    if (!paused) {
      _pausedFileIds.clear();
    }
    _signalStateChange();
  }

  void setFilePaused(String transferId, bool paused) {
    if (paused) {
      _pausedFileIds.add(transferId);
    } else {
      if (_batchPaused) {
        _batchPaused = false;
        for (final id in _activeOutgoingFileIds) {
          if (id != transferId && !_cancelledFileIds.contains(id)) {
            _pausedFileIds.add(id);
          }
        }
      }
      _pausedFileIds.remove(transferId);
    }
    onTransferPausedChanged?.call(transferId, paused);
    _signalStateChange();
  }

  /// Uploads multiple files sequentially to the target device in a single session.
  Future<bool> sendFilesStream({
    required NearbyDevice target,
    required List<FileTransfer> transfers,
    required List<File> files,
  }) async {
    if (_localDevice == null) {
      await _ensureLocalDevice('Sender');
    }

    final sessionId = 'sess_${DateTime.now().millisecondsSinceEpoch}';
    _activeOutgoingSessionId = sessionId;
    _activeOutgoingTarget = target;
    _activeOutgoingFileIds
      ..clear()
      ..addAll(transfers.map((t) => t.id));
    _sessionCancelled = false;
    _batchPaused = false;
    _cancelledFileIds.clear();
    _pausedFileIds.clear();
    _currentUploadingFileId = null;
    _currentFileCancelToken = null;

    bool allOk = true;
    try {
      // 1. Prepare batch transfer
      final prepared = await _httpClient.prepareTransfer(
        target: target,
        sender: _localDevice!,
        sessionId: sessionId,
        files: transfers,
      );

      if (_sessionCancelled) {
        if (prepared) {
          unawaited(_httpClient.cancelTransfer(target: target, sessionId: sessionId));
        }
        for (final t in transfers) {
          onTransferCancelled?.call(t.id);
        }
        return false;
      }

      if (!prepared) {
        debugPrint('[NearbyService] Target declined or unreachable');
        for (final t in transfers) {
          onTransferFailed?.call(t.id, 'Target device declined or unreachable');
        }
        return false;
      }

      // 2. Stream remaining non-paused, non-cancelled files
      final remainingIndices = List<int>.generate(files.length, (i) => i);
      while (remainingIndices.isNotEmpty) {
        remainingIndices.removeWhere((idx) {
          final id = transfers[idx].id;
          if (_cancelledFileIds.contains(id)) {
            _activeOutgoingFileIds.remove(id);
            return true;
          }
          return false;
        });

        if (_sessionCancelled) {
          for (final idx in remainingIndices) {
            onTransferCancelled?.call(transfers[idx].id);
          }
          allOk = false;
          break;
        }

        if (remainingIndices.isEmpty) break;

        int? nextPosition;
        if (!_batchPaused) {
          for (int pos = 0; pos < remainingIndices.length; pos++) {
            final t = transfers[remainingIndices[pos]];
            if (!_pausedFileIds.contains(t.id)) {
              nextPosition = pos;
              break;
            }
          }
        }

        if (nextPosition == null) {
          await _waitForStateChange();
          continue;
        }

        final fileIdx = remainingIndices.removeAt(nextPosition);
        final f = files[fileIdx];
        final t = transfers[fileIdx];

        if (_sessionCancelled || _cancelledFileIds.contains(t.id)) {
          onTransferCancelled?.call(t.id);
          _activeOutgoingFileIds.remove(t.id);
          allOk = false;
          continue;
        }

        final cancelToken = CancelToken();
        _currentUploadingFileId = t.id;
        _currentFileCancelToken = cancelToken;

        onTransferProgress?.call(t.id, 0, t.fileSize, 0.0);

        final ok = await _httpClient.uploadFile(
          target: target,
          sessionId: sessionId,
          fileTransfer: t,
          file: f,
          cancelToken: cancelToken,
          isPaused: () => _batchPaused || _pausedFileIds.contains(t.id),
          waitWhilePaused: _waitForStateChange,
          isCancelled: () => _sessionCancelled || _cancelledFileIds.contains(t.id),
          onProgress: (sentBytes, totalBytes, speed) {
            onTransferProgress?.call(t.id, sentBytes, totalBytes, speed);
          },
        );

        _currentUploadingFileId = null;
        _currentFileCancelToken = null;
        _activeOutgoingFileIds.remove(t.id);

        if (ok) {
          onTransferCompleted?.call(t.id, f.path);
        } else if (_sessionCancelled) {
          onTransferCancelled?.call(t.id);
          for (final idx in remainingIndices) {
            onTransferCancelled?.call(transfers[idx].id);
          }
          allOk = false;
          break;
        } else if (_cancelledFileIds.contains(t.id)) {
          onTransferCancelled?.call(t.id);
          allOk = false;
        } else {
          onTransferFailed?.call(t.id, 'Connection lost during transfer');
          for (final idx in remainingIndices) {
            onTransferFailed?.call(
              transfers[idx].id,
              'Transfer cancelled after connection error',
            );
          }
          allOk = false;
          break;
        }
      }
    } finally {
      _activeOutgoingSessionId = null;
      _activeOutgoingTarget = null;
      _activeOutgoingFileIds.clear();
      _sessionCancelled = false;
      _batchPaused = false;
      _cancelledFileIds.clear();
      _pausedFileIds.clear();
      _currentUploadingFileId = null;
      _currentFileCancelToken = null;
      _signalStateChange();
    }

    return allOk;
  }

  void disconnect(String endpointId) {
    onDisconnected?.call(endpointId);
  }

  Future<NearbyDevice> ensureAirDeviceReady(
    String deviceName, {
    bool requireHttpServer = false,
  }) async {
    var local = await _ensureLocalDevice(deviceName);
    if (requireHttpServer && !_httpServer.isRunning) {
      final boundPort = await _httpServer.startServer(localDevice: local);
      if (boundPort != null) {
        local = local.copyWith(port: boundPort);
        _localDevice = local;
      }
    } else if (_httpServer.isRunning && _httpServer.port != null) {
      local = local.copyWith(port: _httpServer.port);
      _localDevice = local;
    }

    if (!_discoveryService.isRunning) {
      await _discoveryService.startDiscovery(
        localDevice: local,
        isReceiver: _isAdvertising,
        isPassive: false,
      );
    } else {
      _discoveryService.updateLocalDevice(local);
    }
    return local;
  }

  Future<void> broadcastAirGrab(AirGrabSession session) async {
    await _discoveryService.broadcastAirGrab(session);
    for (final peer in _knownDevices.values) {
      if (peer.hasLanIp && peer.id != _deviceId) {
        unawaited(_httpClient.postAirGrab(peer, session));
      }
    }
  }

  Future<void> pushAirGrabToDevice(
    AirGrabSession session,
    NearbyDevice target,
  ) async {
    if (!target.hasLanIp || target.id == _deviceId) return;
    _discoveryService.sendAirGrabDirect(target, session);
    await _httpClient.postAirGrab(target, session);
  }

  Future<void> broadcastAirCancel(String token) async {
    await _discoveryService.broadcastAirCancel(token);
    for (final peer in _knownDevices.values) {
      if (peer.hasLanIp && peer.id != _deviceId) {
        unawaited(_httpClient.postAirCancel(peer, token));
      }
    }
  }

  Future<void> sendAirClaim(AirGrabSession session) async {
    _knownDevices[session.sender.id] = session.sender;
    final local = _localDevice ?? await _ensureLocalDevice('Receiver');
    await _discoveryService.sendAirClaim(session);
    await _httpClient.postAirClaim(session, local);
  }

  Future<bool> startAirHotspot(AirGrabSession session) async {
    if (!Platform.isAndroid) return false;
    return await _directP2p.startWifiDirectAdvertising(
      id: session.sender.id,
      name: session.sender.name,
      port: session.sender.port,
      airToken: session.token,
    );
  }

  Future<void> stopAirHotspot({bool resumeDiscovery = false}) async {
    if (!Platform.isAndroid) return;
    await _directP2p.stopWifiDirectAdvertising();
    if (resumeDiscovery) {
      await _directP2p.startWifiDirectDiscovery(isPassive: false);
    }
  }

  Future<bool> startAirDirectDiscovery() async {
    if (!Platform.isAndroid) return false;
    await _directP2p.stopWifiDirectAdvertising();
    return await _directP2p.startWifiDirectDiscovery(isPassive: false);
  }

  Future<AirGrabSession?> connectToAirSenderHotspot(NearbyDevice sender) async {
    if (!Platform.isAndroid) return null;
    await _directP2p.stopWifiDirectAdvertising();
    final res = await _directP2p.connectToPeer(
      ssid: sender.p2pSsid,
      passphrase: sender.p2pPassphrase,
      deviceAddress: sender.p2pDeviceAddress,
      goIp: sender.p2pGoIp,
    );
    if (!res.success) return null;

    final targetIp = (res.goIp != null && res.goIp!.isNotEmpty)
        ? res.goIp!
        : (sender.p2pGoIp ?? '192.168.49.1');
    NetworkInfoService.invalidateCache();

    for (int attempt = 0; attempt < 5; attempt++) {
      final session = await _httpClient.fetchActiveAirGrab(targetIp, sender.port);
      if (session != null) {
        _knownDevices[sender.id] = session.sender;
        return session;
      }
      if (attempt < 4) {
        await Future.delayed(const Duration(milliseconds: 400));
      }
    }
    return null;
  }
}
