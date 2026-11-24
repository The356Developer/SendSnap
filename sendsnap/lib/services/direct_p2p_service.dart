import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import '../models/device.dart';

class DirectHotspotInfo {
  final String ssid;
  final String passphrase;
  final String goIp;
  final int port;

  const DirectHotspotInfo({
    required this.ssid,
    required this.passphrase,
    required this.goIp,
    this.port = 53318,
  });

  bool get isValid => ssid.isNotEmpty && passphrase.isNotEmpty && goIp.isNotEmpty;

  factory DirectHotspotInfo.fromMap(Map<dynamic, dynamic> map) {
    return DirectHotspotInfo(
      ssid: (map['ssid'] as String?) ?? '',
      passphrase: (map['passphrase'] as String?) ?? '',
      goIp: (map['goIp'] as String?) ?? '',
      port: (map['port'] as num?)?.toInt() ?? 53318,
    );
  }
}

class DirectP2pStatus {
  final bool supported;
  final bool wifiEnabled;
  final bool hasPermission;
  final bool locationEnabled;
  final bool isGroupActive;
  final String ssid;
  final String passphrase;
  final String goIp;

  const DirectP2pStatus({
    this.supported = false,
    this.wifiEnabled = false,
    this.hasPermission = false,
    this.locationEnabled = true,
    this.isGroupActive = false,
    this.ssid = '',
    this.passphrase = '',
    this.goIp = '',
  });

  bool get canUseDirectWifi => supported && wifiEnabled && hasPermission && locationEnabled;

  factory DirectP2pStatus.fromMap(Map<dynamic, dynamic> map) {
    return DirectP2pStatus(
      supported: (map['supported'] as bool?) ?? false,
      wifiEnabled: (map['wifiEnabled'] as bool?) ?? false,
      hasPermission: (map['hasPermission'] as bool?) ?? false,
      locationEnabled: (map['locationEnabled'] as bool?) ?? true,
      isGroupActive: (map['isGroupActive'] as bool?) ?? false,
      ssid: (map['ssid'] as String?) ?? '',
      passphrase: (map['passphrase'] as String?) ?? '',
      goIp: (map['goIp'] as String?) ?? '',
    );
  }
}

class DirectConnectResult {
  final bool success;
  final String? goIp;
  final String? error;

  const DirectConnectResult({
    required this.success,
    this.goIp,
    this.error,
  });
}

class ParsedQrPayload {
  final String? lanIp;
  final List<String> altLanIps;
  final int port;
  final String? ssid;
  final String? passphrase;
  final String? p2pIp;
  final String? deviceId;
  final String? deviceName;

  const ParsedQrPayload({
    this.lanIp,
    this.altLanIps = const [],
    this.port = 53318,
    this.ssid,
    this.passphrase,
    this.p2pIp,
    this.deviceId,
    this.deviceName,
  });

  bool get hasDirectCredentials =>
      ssid != null && ssid!.isNotEmpty && passphrase != null && passphrase!.isNotEmpty;

  bool get hasUsableLanIp =>
      lanIp != null && lanIp!.isNotEmpty && lanIp != '0.0.0.0';

  List<String> get allLanIps {
    final result = <String>[];
    if (hasUsableLanIp) {
      result.add(lanIp!);
    }
    for (final ip in altLanIps) {
      final trimmed = ip.trim();
      if (trimmed.isNotEmpty &&
          trimmed != '0.0.0.0' &&
          !result.contains(trimmed)) {
        result.add(trimmed);
      }
    }
    return result;
  }
}

/// Bridge to native Android (`WifiP2pManager` + DNS-SD + `NsdManager` + BLE) and
/// Windows (`WiFiDirectAdvertisementPublisher` + WinRT BLE + WLAN Direct) P2P transports.
class DirectP2pService {
  static const MethodChannel _channel =
      MethodChannel('com.the356company.sendsnap/direct_p2p');

  static bool get _supportsDirectWifiChannel =>
      Platform.isAndroid || Platform.isWindows;

  Function(NearbyDevice device)? onNsdDeviceFound;
  Function(String deviceId)? onNsdDeviceLost;
  Function(NearbyDevice device)? onWifiDirectDeviceFound;
  Function(NearbyDevice sender, String airToken)? onAirWifiDirectSenderFound;
  Function(DirectHotspotInfo? hotspot)? onDirectHotspotReady;
  Function(bool connected, String? goIp)? onDirectConnectionChanged;
  Function(bool enabled)? onWifiStateChanged;

  bool _handlerRegistered = false;

  void initialize() {
    if (!_supportsDirectWifiChannel || _handlerRegistered) return;
    try {
      _channel.setMethodCallHandler(_handleNativeCall);
      _handlerRegistered = true;
    } catch (_) {
      // Safe no-op in headless unit tests where ServicesBinding is not initialized.
    }
  }

  Future<dynamic> _handleNativeCall(MethodCall call) async {
    try {
      switch (call.method) {
        case 'onNsdDeviceFound':
          final args = call.arguments as Map<dynamic, dynamic>?;
          if (args != null) {
            final device = NearbyDevice(
              id: (args['id'] as String?) ?? '',
              name: (args['name'] as String?) ?? 'SendSnap Device',
              ip: (args['ip'] as String?) ?? '',
              port: (args['port'] as num?)?.toInt() ?? 53318,
              deviceType: (args['deviceType'] as String?) ?? 'unknown',
              connectionType: 'lan',
              lastSeen: DateTime.now(),
            );
            if (device.id.isNotEmpty && device.hasLanIp) {
              onNsdDeviceFound?.call(device);
            }
          }
          break;
        case 'onNsdDeviceLost':
          final id = call.arguments as String?;
          if (id != null && id.isNotEmpty) {
            onNsdDeviceLost?.call(id);
          }
          break;
        case 'onWifiDirectDeviceFound':
          final args = call.arguments as Map<dynamic, dynamic>?;
          if (args != null) {
            final device = NearbyDevice(
              id: (args['id'] as String?) ?? '',
              name: (args['name'] as String?) ?? 'SendSnap Device',
              ip: '',
              port: (args['port'] as num?)?.toInt() ?? 53318,
              deviceType: (args['deviceType'] as String?) ?? 'android',
              connectionType: 'wifi_direct',
              p2pDeviceAddress: args['p2pDeviceAddress'] as String?,
              p2pSsid: args['p2pSsid'] as String?,
              p2pPassphrase: args['p2pPassphrase'] as String?,
              p2pGoIp: (args['p2pGoIp'] as String?) ?? '192.168.49.1',
              lastSeen: DateTime.now(),
            );
            final airToken = (args['airToken'] as String?) ?? '';
            if (device.id.isNotEmpty) {
              if (airToken.isNotEmpty) {
                onAirWifiDirectSenderFound?.call(device, airToken);
              } else {
                onWifiDirectDeviceFound?.call(device);
              }
            }
          }
          break;
        case 'onDirectHotspotReady':
          final args = call.arguments as Map<dynamic, dynamic>?;
          if (args == null || args.isEmpty) {
            onDirectHotspotReady?.call(null);
          } else {
            final info = DirectHotspotInfo.fromMap(args);
            onDirectHotspotReady?.call(info.isValid ? info : null);
          }
          break;
        case 'onDirectConnectionChanged':
          final args = call.arguments as Map<dynamic, dynamic>?;
          if (args != null) {
            final connected = (args['connected'] as bool?) ?? false;
            final goIp = args['goIp'] as String?;
            onDirectConnectionChanged?.call(connected, goIp);
          }
          break;
        case 'onWifiStateChanged':
          final enabled = (call.arguments as bool?) ?? false;
          onWifiStateChanged?.call(enabled);
          break;
      }
    } catch (e) {
      debugPrint('[DirectP2pService] Native callback error (${call.method}): $e');
    }
  }

  Future<DirectP2pStatus> getDirectStatus() async {
    if (!_supportsDirectWifiChannel) {
      return const DirectP2pStatus();
    }
    try {
      final result = await _channel.invokeMapMethod<dynamic, dynamic>('getDirectStatus');
      if (result != null) {
        return DirectP2pStatus.fromMap(result);
      }
    } on MissingPluginException {
      return const DirectP2pStatus();
    } catch (e) {
      debugPrint('[DirectP2pService] getDirectStatus error: $e');
    }
    return const DirectP2pStatus();
  }

  Future<bool> ensureLanWifiRouting({bool enable = true}) async {
    if (!Platform.isAndroid) return false;
    try {
      return (await _channel.invokeMethod<bool>('ensureLanWifiRouting', {
            'enable': enable,
          })) ??
          false;
    } catch (_) {
      return false;
    }
  }

  Future<bool> _launchWindowsSettings(String primaryUri) async {
    for (final raw in [primaryUri, 'ms-settings:network-status']) {
      try {
        if (await launchUrl(
          Uri.parse(raw),
          mode: LaunchMode.externalApplication,
        )) {
          return true;
        }
      } catch (e) {
        debugPrint('[DirectP2pService] Windows settings ($raw) error: $e');
      }
    }
    return false;
  }

  Future<bool> openWifiPanel() async {
    if (Platform.isWindows) {
      return _launchWindowsSettings('ms-settings:network-wifi');
    }
    if (!Platform.isAndroid) return false;
    try {
      return (await _channel.invokeMethod<bool>('openWifiPanel')) ?? false;
    } catch (e) {
      debugPrint('[DirectP2pService] openWifiPanel error: $e');
      return false;
    }
  }

  Future<bool> openHotspotSettings() async {
    if (Platform.isWindows) {
      return _launchWindowsSettings('ms-settings:network-mobilehotspot');
    }
    if (!Platform.isAndroid) return false;
    try {
      return (await _channel.invokeMethod<bool>('openHotspotSettings')) ?? false;
    } catch (e) {
      debugPrint('[DirectP2pService] openHotspotSettings error: $e');
      return false;
    }
  }

  Future<bool> startNsdAdvertising({
    required String id,
    required String name,
    required int port,
    required String deviceType,
  }) async {
    if (!Platform.isAndroid) return false;
    try {
      return (await _channel.invokeMethod<bool>('startNsdAdvertising', {
            'id': id,
            'name': name,
            'port': port,
            'deviceType': deviceType,
          })) ??
          false;
    } catch (e) {
      debugPrint('[DirectP2pService] startNsdAdvertising error: $e');
      return false;
    }
  }

  Future<void> stopNsdAdvertising() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('stopNsdAdvertising');
    } catch (_) {}
  }

  Future<bool> startNsdDiscovery({required String localId}) async {
    if (!Platform.isAndroid) return false;
    try {
      return (await _channel.invokeMethod<bool>('startNsdDiscovery', {
            'localId': localId,
          })) ??
          false;
    } catch (e) {
      debugPrint('[DirectP2pService] startNsdDiscovery error: $e');
      return false;
    }
  }

  Future<void> stopNsdDiscovery() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('stopNsdDiscovery');
    } catch (_) {}
  }

  Future<bool> startWifiDirectAdvertising({
    required String id,
    required String name,
    required int port,
    String? airToken,
  }) async {
    if (!_supportsDirectWifiChannel) return false;
    try {
      final result = await _channel.invokeMapMethod<dynamic, dynamic>(
        'startWifiDirectAdvertising',
        {
          'id': id,
          'name': name,
          'port': port,
          if (airToken != null && airToken.isNotEmpty) 'airToken': airToken,
        },
      );
      return (result?['success'] as bool?) ?? false;
    } on MissingPluginException {
      return false;
    } catch (e) {
      debugPrint('[DirectP2pService] startWifiDirectAdvertising error: $e');
      return false;
    }
  }

  Future<void> stopWifiDirectAdvertising() async {
    if (!_supportsDirectWifiChannel) return;
    try {
      await _channel.invokeMethod('stopWifiDirectAdvertising');
    } catch (_) {}
  }

  Future<bool> startWifiDirectDiscovery({bool isPassive = false}) async {
    if (!_supportsDirectWifiChannel) return false;
    try {
      return (await _channel.invokeMethod<bool>('startWifiDirectDiscovery', {
            'isPassive': isPassive,
          })) ??
          false;
    } on MissingPluginException {
      return false;
    } catch (e) {
      debugPrint('[DirectP2pService] startWifiDirectDiscovery error: $e');
      return false;
    }
  }

  Future<void> setWifiDirectDiscoveryPace({required bool isPassive}) async {
    if (!_supportsDirectWifiChannel) return;
    try {
      await _channel.invokeMethod('setWifiDirectDiscoveryPace', {
        'isPassive': isPassive,
      });
    } catch (_) {}
  }

  Future<void> stopWifiDirectDiscovery() async {
    if (!_supportsDirectWifiChannel) return;
    try {
      await _channel.invokeMethod('stopWifiDirectDiscovery');
    } catch (_) {}
  }

  Future<DirectConnectResult> connectToPeer({
    String? ssid,
    String? passphrase,
    String? deviceAddress,
    String? goIp,
    int port = 53318,
  }) async {
    if (!_supportsDirectWifiChannel) {
      return const DirectConnectResult(
        success: false,
        error: 'Direct Wi-Fi pairing is only supported on Android and Windows',
      );
    }
    try {
      final res = await _channel.invokeMapMethod<dynamic, dynamic>(
        'connectWifiDirectPeer',
        {
          'ssid': ?ssid,
          'passphrase': ?passphrase,
          'deviceAddress': ?deviceAddress,
          'goIp': ?goIp,
          'port': port,
        },
      );
      final ok = (res?['success'] as bool?) ?? false;
      final ip = (res?['goIp'] as String?);
      final error = (res?['error'] as String?);
      return DirectConnectResult(
        success: ok,
        goIp: (ip != null && ip.isNotEmpty) ? ip : null,
        error: (error != null && error.isNotEmpty) ? error : null,
      );
    } on MissingPluginException {
      return const DirectConnectResult(
        success: false,
        error: 'Direct Wi-Fi native channel unavailable in this environment',
      );
    } catch (e) {
      return DirectConnectResult(success: false, error: e.toString());
    }
  }

  Future<void> disconnectDirect() async {
    if (!_supportsDirectWifiChannel) return;
    try {
      await _channel.invokeMethod('disconnectWifiDirect');
    } catch (_) {}
  }

  /// Builds a unified QR payload containing LAN IP(s) (if connected to router) and
  /// Direct Wi-Fi credentials (when hosting a Direct Wi-Fi group / hotspot).
  static String buildQrPayload({
    String? lanIp,
    List<String>? altLanIps,
    required int port,
    DirectHotspotInfo? hotspot,
    String? deviceId,
    String? deviceName,
  }) {
    final hasHotspot = hotspot != null && hotspot.isValid;
    final candidateIps = <String>[];
    if (lanIp != null &&
        lanIp.isNotEmpty &&
        lanIp != '0.0.0.0' &&
        (!hasHotspot || lanIp != hotspot.goIp)) {
      candidateIps.add(lanIp);
    }
    if (altLanIps != null) {
      for (final rawIp in altLanIps) {
        final ip = rawIp.trim();
        if (ip.isNotEmpty &&
            ip != '0.0.0.0' &&
            (!hasHotspot || ip != hotspot.goIp) &&
            !candidateIps.contains(ip)) {
          candidateIps.add(ip);
        }
      }
    }

    final validLan = candidateIps.isNotEmpty ? candidateIps.first : null;
    final extraIps =
        candidateIps.length > 1 ? candidateIps.sublist(1) : const <String>[];
    final host = validLan ?? (hasHotspot ? hotspot.goIp : '0.0.0.0');

    final params = <String, String>{};
    if (extraIps.isNotEmpty) {
      params['alts'] = extraIps.join(',');
    }
    if (hasHotspot) {
      params['ssid'] = hotspot.ssid;
      params['pass'] = hotspot.passphrase;
      params['p2pIp'] = hotspot.goIp;
      if (validLan == null) {
        params['p2pOnly'] = '1';
      }
    }
    if (deviceId != null && deviceId.isNotEmpty) {
      params['id'] = deviceId;
    }
    if (deviceName != null && deviceName.isNotEmpty) {
      params['name'] = deviceName;
    }

    return Uri(
      scheme: 'sendsnap',
      host: host,
      port: port,
      queryParameters: params.isEmpty ? null : params,
    ).toString();
  }

  /// Parses enriched `sendsnap://...` URIs as well as legacy `sendsnap://ip:port`,
  /// `http://ip:port`, and bare `ip:port` strings.
  static ParsedQrPayload? parseQrPayload(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return null;

    if (trimmed.startsWith('sendsnap://') || trimmed.startsWith('http://')) {
      final uri = Uri.tryParse(trimmed);
      if (uri != null && uri.host.isNotEmpty) {
        final qp = uri.queryParameters;
        final isP2pOnly = qp['p2pOnly'] == '1';
        final rawHost = uri.host;
        final lanIp = (isP2pOnly || rawHost == '0.0.0.0') ? null : rawHost;
        final altsRaw = qp['alts'];
        final altLanIps = (altsRaw != null && altsRaw.isNotEmpty)
            ? altsRaw
                .split(',')
                .map((s) => s.trim())
                .where((s) => s.isNotEmpty && s != '0.0.0.0')
                .toList()
            : const <String>[];
        final port = uri.hasPort && uri.port > 0 ? uri.port : 53318;
        final ssid = qp['ssid'];
        final pass = qp['pass'];
        final p2pIp = qp['p2pIp'] ?? ((ssid != null && ssid.isNotEmpty) ? rawHost : null);
        return ParsedQrPayload(
          lanIp: lanIp,
          altLanIps: altLanIps,
          port: port,
          ssid: (ssid != null && ssid.isNotEmpty) ? ssid : null,
          passphrase: (pass != null && pass.isNotEmpty) ? pass : null,
          p2pIp: (p2pIp != null && p2pIp.isNotEmpty) ? p2pIp : null,
          deviceId: qp['id']?.isNotEmpty == true ? qp['id'] : null,
          deviceName: qp['name']?.isNotEmpty == true ? qp['name'] : null,
        );
      }
    }

    // Legacy / manual host[:port] fallback
    String host = trimmed;
    int port = 53318;
    if (host.contains(':')) {
      final parts = host.split(':');
      host = parts[0].trim();
      port = int.tryParse(parts[1].split('/')[0]) ?? port;
    }
    if (host.isEmpty) return null;
    return ParsedQrPayload(
      lanIp: host == '0.0.0.0' ? null : host,
      port: port,
    );
  }
}
