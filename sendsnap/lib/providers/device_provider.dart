import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'dart:io';
import 'dart:math';
import 'dart:async';
import '../models/device.dart';
import '../services/nearby_service.dart';
import '../services/direct_p2p_service.dart';
import '../services/permission_service.dart';
import '../services/network_info_service.dart';

class DeviceProvider with ChangeNotifier {
  final NearbyService _nearbyService = NearbyService();
  final PermissionService _permissionService = PermissionService();

  String _displayName = 'User';
  bool _displayNameLoaded = false;
  Future<void>? _loadDisplayNameFuture;

  String? _localIp;
  bool _isAdvertising = false;
  bool _isDiscovering = false;
  bool _isWarmDiscovering = false;
  bool _pendingActiveDiscoveryAfterWifi = false;
  String? _lastError;
  bool _lastErrorIsWifiOff = false;

  DirectP2pStatus _directStatus = const DirectP2pStatus();
  DirectHotspotInfo? _activeHotspotInfo;

  final Map<String, NearbyDevice> _foundDevices = {};
  NearbyDevice? _connectedDevice;

  String get displayName => _displayName;
  String? get localIp => _localIp;
  bool get isAdvertising => _isAdvertising;
  bool get getIsDiscovering => _isDiscovering;
  bool get isDiscovering => _isDiscovering;
  bool get isWarmDiscovering => _isWarmDiscovering;
  List<NearbyDevice> get nearbyDevices => _foundDevices.values.toList();
  NearbyDevice? get connectedDevice => _connectedDevice;
  String? get lastError => _lastError;
  bool get lastErrorIsWifiOff => _lastErrorIsWifiOff;

  DirectP2pStatus get directStatus => _directStatus;
  DirectHotspotInfo? get activeHotspotInfo => _activeHotspotInfo;
  bool get isWifiDirectSupported => _directStatus.supported;
  bool get isWifiEnabled => _directStatus.wifiEnabled;
  bool get hasLanIp =>
      _localIp != null && _localIp!.isNotEmpty && _localIp != '0.0.0.0';
  bool get hasDirectWifiReady => Platform.isAndroid && _directStatus.wifiEnabled;
  bool get hasAnyNetworkReady => hasLanIp || hasDirectWifiReady;
  int get warmDiscoveredCount => _foundDevices.length;

  Function(Map<String, dynamic> event)? onPortalEvent;

  NearbyService get nearbyService => _nearbyService;

  DeviceProvider() {
    _loadDisplayNameFuture = _loadDisplayName();
    _refreshLocalIp();
    _setupNearbyCallbacks();
  }

  Future<void> _refreshLocalIp({bool forceRefresh = false}) async {
    _localIp = await NetworkInfoService.getLocalIpAddress(
      forceRefresh: forceRefresh,
    );
    notifyListeners();
  }

  Future<void> refreshNetworkStatus({bool forceRefresh = false}) async {
    if (forceRefresh) {
      NetworkInfoService.invalidateCache();
    }
    _localIp = await NetworkInfoService.getLocalIpAddress(
      forceRefresh: forceRefresh,
    );
    _directStatus = await _nearbyService.directP2p.getDirectStatus();
    if (hasAnyNetworkReady && _lastError != null) {
      _lastError = null;
      _lastErrorIsWifiOff = false;
    }
    notifyListeners();
  }

  void _setupNearbyCallbacks() {
    _nearbyService.onDeviceFound = (device) {
      _foundDevices[device.id] = device;
      notifyListeners();
    };

    _nearbyService.onDeviceLost = (id) {
      _foundDevices.remove(id);
      notifyListeners();
    };

    _nearbyService.onHotspotInfoChanged = (hotspot) {
      _activeHotspotInfo = hotspot;
      notifyListeners();
    };

    _nearbyService.onConnectionInitiated = (id, deviceName) async {
      debugPrint('[DeviceProvider] Handshake initiated with $deviceName ($id)');
    };

    _nearbyService.onConnectionResult = (id, success) {
      debugPrint('[DeviceProvider] Connection result: $id -> $success');
      if (success) {
        _connectedDevice = _foundDevices[id] ??
            NearbyDevice(
              id: id,
              name: 'Device',
              ip: '',
              port: 53318,
            );
      } else {
        _connectedDevice = null;
      }
      notifyListeners();
    };

    _nearbyService.onDisconnected = (id) {
      if (_connectedDevice?.id == id) {
        _connectedDevice = null;
      }
      notifyListeners();
    };

    _nearbyService.onPortalEvent = (event) {
      onPortalEvent?.call(event);
    };

    _nearbyService.onWifiStateChanged = (enabled) async {
      await refreshNetworkStatus(forceRefresh: true);
      if (enabled) {
        _lastError = null;
        _lastErrorIsWifiOff = false;
        notifyListeners();
        if (_pendingActiveDiscoveryAfterWifi) {
          _pendingActiveDiscoveryAfterWifi = false;
          await startActiveDiscovery();
        } else if (!_isAdvertising && !_isDiscovering) {
          await initWarmDiscovery();
        }
      }
    };
  }

  Future<void> _loadDisplayName() async {
    if (_displayNameLoaded) return;
    final prefs = await SharedPreferences.getInstance();
    String? saved = prefs.getString('display_name');
    if (saved != null && saved.isNotEmpty) {
      _displayName = saved;
    } else {
      try {
        if (Platform.isAndroid) {
          final info = await DeviceInfoPlugin().androidInfo;
          _displayName = '${info.brand} ${info.model}';
        } else if (Platform.isIOS) {
          final info = await DeviceInfoPlugin().iosInfo;
          _displayName = info.name;
        } else if (Platform.isWindows) {
          final info = await DeviceInfoPlugin().windowsInfo;
          _displayName = info.computerName;
        } else {
          _displayName = 'Device ${Random().nextInt(999)}';
        }
      } catch (_) {
        _displayName = 'User ${Random().nextInt(999)}';
      }
      await prefs.setString('display_name', _displayName);
    }
    _displayNameLoaded = true;
    notifyListeners();
  }

  Future<void> updateDisplayName(String name) async {
    _displayName = name.trim();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('display_name', _displayName);
    notifyListeners();
  }

  /// Pre-warms LAN + Android NSD + Direct Wi-Fi discovery in the background
  /// right after HomeScreen launches so receivers appear with zero delay.
  Future<void> initWarmDiscovery() async {
    await _loadDisplayNameFuture;
    await refreshNetworkStatus();
    if (_isAdvertising || _isDiscovering) return;
    if (!hasAnyNetworkReady) return;

    _isWarmDiscovering = true;
    await _nearbyService.startWarmDiscovery(_displayName);
    notifyListeners();
  }

  /// Speeds up discovery while the user is choosing files to send.
  Future<void> boostWarmDiscovery() async {
    if (_isAdvertising) return;
    await _loadDisplayNameFuture;
    await refreshNetworkStatus(forceRefresh: true);
    if (!hasAnyNetworkReady) return;

    if (!_isWarmDiscovering && !_isDiscovering) {
      _isWarmDiscovering = true;
      await _nearbyService.startWarmDiscovery(_displayName);
      notifyListeners();
    }
    await _nearbyService.boostWarmDiscovery();
  }

  /// Handles foreground/background transitions to save battery while keeping
  /// warm discovery responsive when returning to the app.
  Future<void> onAppLifecycleChanged(AppLifecycleState state) async {
    if (state == AppLifecycleState.paused) {
      if (!_isAdvertising && !_isDiscovering) {
        _isWarmDiscovering = false;
        await _nearbyService.pauseWarmDiscovery();
        notifyListeners();
      }
    } else if (state == AppLifecycleState.resumed) {
      await refreshNetworkStatus(forceRefresh: true);
      if (_pendingActiveDiscoveryAfterWifi && hasAnyNetworkReady) {
        _pendingActiveDiscoveryAfterWifi = false;
        _lastError = null;
        _lastErrorIsWifiOff = false;
        await startActiveDiscovery();
      } else if (!_isAdvertising && !_isDiscovering) {
        await initWarmDiscovery();
      }
    }
  }

  Future<bool> openWifiSettings() async {
    return await _nearbyService.directP2p.openWifiPanel();
  }

  Future<bool> _ensureNetworkReady() async {
    _lastError = null;
    _lastErrorIsWifiOff = false;
    if (Platform.isAndroid) {
      await _permissionService.requestNearbyWifiPermission();
    }
    await refreshNetworkStatus(forceRefresh: true);

    if (!hasAnyNetworkReady) {
      _lastErrorIsWifiOff = Platform.isAndroid;
      _lastError = Platform.isAndroid
          ? 'Turn on Wi-Fi in the popup to start detecting nearby devices.'
          : 'No Wi-Fi or hotspot connection found. Please connect both devices to the same Wi-Fi network or enable a Personal Hotspot.';
      debugPrint('[DeviceProvider] No LAN IP or active Wi-Fi radio found');
      return false;
    }
    return true;
  }

  Future<void> toggleAdvertising() async {
    if (_isAdvertising) {
      _isAdvertising = false;
      _activeHotspotInfo = null;
      notifyListeners();
      await _nearbyService.stopAll(disconnectDirect: true);
      unawaited(initWarmDiscovery());
    } else {
      await _loadDisplayNameFuture;
      _pendingActiveDiscoveryAfterWifi = false;
      _lastError = null;
      _lastErrorIsWifiOff = false;

      if (Platform.isAndroid) {
        // Android 8+ LocalOnlyHotspot works directly even when the master Wi-Fi toggle is OFF
        await _permissionService.requestNearbyWifiPermission();
        await refreshNetworkStatus(forceRefresh: true);
      } else {
        if (!await _ensureNetworkReady()) {
          notifyListeners();
          return;
        }
      }

      _isAdvertising = true;
      _isDiscovering = false;
      _isWarmDiscovering = false;
      _foundDevices.clear();
      notifyListeners();

      try {
        await _nearbyService.stopAll(disconnectDirect: false);
        bool success = await _nearbyService.startAdvertising(_displayName);
        if (!success) {
          _isAdvertising = false;
          _activeHotspotInfo = null;
          _lastErrorIsWifiOff = Platform.isAndroid && !isWifiEnabled;
          _lastError = Platform.isAndroid && !isWifiEnabled
              ? 'Could not start offline hotspot automatically. Tap to turn on Wi-Fi.'
              : 'Failed to start receiver service. Please check Wi-Fi and network permissions.';
          notifyListeners();
        }
      } catch (e) {
        debugPrint('[DeviceProvider] Advertising error: $e');
        _isAdvertising = false;
        _activeHotspotInfo = null;
        _lastError = 'Receiver failed: $e';
        notifyListeners();
      }
    }
  }

  /// Activates full Send-mode discovery, preserving devices already discovered
  /// during background warm-up.
  Future<void> startActiveDiscovery() async {
    await _loadDisplayNameFuture;
    if (_isDiscovering) {
      await _nearbyService.boostWarmDiscovery();
      return;
    }

    _lastError = null;
    _lastErrorIsWifiOff = false;

    if (Platform.isAndroid) {
      await _permissionService.requestNearbyWifiPermission();
      await refreshNetworkStatus(forceRefresh: true);
      if (!hasAnyNetworkReady) {
        _pendingActiveDiscoveryAfterWifi = true;
        await openWifiSettings();
        await Future.delayed(const Duration(milliseconds: 500));
        await refreshNetworkStatus(forceRefresh: true);
        if (!hasAnyNetworkReady) {
          _lastErrorIsWifiOff = true;
          _lastError = 'Turn on Wi-Fi in the popup to start detecting nearby devices automatically.';
          notifyListeners();
          return;
        }
        _pendingActiveDiscoveryAfterWifi = false;
      }
    } else if (!await _ensureNetworkReady()) {
      notifyListeners();
      return;
    }

    await _permissionService.requestAllPermissions();

    if (_isAdvertising) {
      await _nearbyService.stopAll(disconnectDirect: false);
      _foundDevices.clear();
    }

    _pendingActiveDiscoveryAfterWifi = false;
    _isDiscovering = true;
    _isAdvertising = false;
    _isWarmDiscovering = false;
    _lastError = null;
    _lastErrorIsWifiOff = false;
    notifyListeners();

    try {
      bool success = await _nearbyService.promoteToActiveDiscovery(_displayName);
      if (!success) {
        _isDiscovering = false;
        _lastError = 'Failed to start discovery. Please try again.';
        notifyListeners();
      }
    } catch (e) {
      debugPrint('[DeviceProvider] Discovery error: $e');
      _isDiscovering = false;
      _lastError = 'Discovery failed: $e';
      notifyListeners();
    }
  }

  Future<void> toggleDiscovery() async {
    if (_isDiscovering) {
      _pendingActiveDiscoveryAfterWifi = false;
      _isDiscovering = false;
      _activeHotspotInfo = null;
      notifyListeners();
      await _nearbyService.stopAll(disconnectDirect: true);
      unawaited(initWarmDiscovery());
    } else {
      await startActiveDiscovery();
    }
  }

  /// Manually connect to a device by IP address (useful if UDP broadcast is isolated by a router).
  Future<bool> connectByIp(String ip, {int port = 53318}) async {
    final dev = await connectAndGetDevice(ip, port: port);
    return dev != null;
  }

  /// Pings a remote device by IP and adds it to discovered devices.
  Future<NearbyDevice?> connectAndGetDevice(String ip, {int port = 53318}) async {
    final remoteDevice = await _nearbyService.httpClient.ping(ip, port);
    if (remoteDevice != null) {
      _foundDevices[remoteDevice.id] = remoteDevice;
      _nearbyService.addManualDevice(remoteDevice);
      notifyListeners();
      return remoteDevice;
    }
    return null;
  }

  /// Connects using an enriched or legacy SendSnap QR code (auto-joining Direct Wi-Fi if needed).
  Future<NearbyDevice?> connectFromQr(String rawQr) async {
    final dev = await _nearbyService.connectFromQrData(rawQr);
    if (dev != null) {
      _foundDevices[dev.id] = dev;
      notifyListeners();
    }
    return dev;
  }

  Future<void> stopAll({bool resumeWarm = true}) async {
    await _nearbyService.stopAll(disconnectDirect: true);
    _pendingActiveDiscoveryAfterWifi = false;
    _isAdvertising = false;
    _isDiscovering = false;
    _isWarmDiscovering = false;
    _activeHotspotInfo = null;
    _foundDevices.clear();
    _lastError = null;
    _lastErrorIsWifiOff = false;
    notifyListeners();
    if (resumeWarm) {
      unawaited(initWarmDiscovery());
    }
  }

  void clearError() {
    _lastError = null;
    _lastErrorIsWifiOff = false;
    notifyListeners();
  }

  Future<bool> requestConnectionAndWait(String endpointId) async {
    try {
      final success =
          await _nearbyService.requestConnection(_displayName, endpointId);
      return success;
    } catch (e) {
      debugPrint('[DeviceProvider] requestConnectionAndWait error: $e');
      return false;
    }
  }
}
