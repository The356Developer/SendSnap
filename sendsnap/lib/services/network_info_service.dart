import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class NetworkInfoService {
  static const _channel = MethodChannel('com.the356company.sendsnap/file_utils');

  static List<NetworkInterface>? _cachedInterfaces;
  static DateTime? _cacheTimestamp;
  static const Duration _cacheTtl = Duration(seconds: 3);

  static final RegExp _excludedTokenRegex = RegExp(
    r'(^|[^a-z0-9])(lo|lo0|tun|utun|tap|ppp|wg|ipsec|dummy)([0-9]*($|[^a-z0-9]))',
  );

  /// Clears cached interface list (call after network switch or P2P link setup).
  static void invalidateCache() {
    _cachedInterfaces = null;
    _cacheTimestamp = null;
  }

  /// Acquires Android Wi-Fi multicast lock to ensure incoming UDP broadcast packets are received.
  static Future<void> acquireMulticastLock() async {
    if (Platform.isAndroid) {
      try {
        await _channel.invokeMethod('acquireMulticastLock');
      } catch (e) {
        debugPrint('[NetworkInfo] acquireMulticastLock error: $e');
      }
    }
  }

  /// Releases Android Wi-Fi multicast lock.
  static Future<void> releaseMulticastLock() async {
    if (Platform.isAndroid) {
      try {
        await _channel.invokeMethod('releaseMulticastLock');
      } catch (e) {
        debugPrint('[NetworkInfo] releaseMulticastLock error: $e');
      }
    }
  }

  /// Pure helper classifying whether an interface name + IPv4 address is a usable
  /// local LAN / Hotspot / P2P interface (filtering cellular, VPN, and virtual adapters).
  static bool isValidLanInterface(String interfaceName, String ip) {
    if (ip.isEmpty ||
        ip == '0.0.0.0' ||
        ip.startsWith('127.') ||
        ip.startsWith('169.254.')) {
      return false;
    }

    final name = interfaceName.toLowerCase();

    // Cellular / IMS / ePDG interfaces
    if (name.contains('rmnet') ||
        name.contains('ccmni') ||
        name.contains('pdp') ||
        name.contains('wwan') ||
        name.contains('clat') ||
        name.contains('radio') ||
        name.contains('cellular') ||
        name.contains('mobile') ||
        name.contains('epdg') ||
        name.contains('ims') ||
        name.contains('qmi') ||
        name.contains('vsnet') ||
        name.contains('dummy')) {
      return false;
    }

    // VPN / tunnel / loopback interfaces
    if (name.contains('loopback') ||
        name.contains('wireguard') ||
        name.contains('tailscale') ||
        name.contains('zerotier') ||
        name.contains('openvpn') ||
        _excludedTokenRegex.hasMatch(name)) {
      return false;
    }

    // Desktop virtualized / container adapters
    if (name.contains('vethernet') ||
        name.contains('wsl') ||
        name.contains('hyper-v') ||
        name.contains('virtualbox') ||
        name.contains('vbox') ||
        name.contains('vmware') ||
        name.contains('vmnet') ||
        name.contains('docker') ||
        name.startsWith('br-') ||
        name.startsWith('virbr') ||
        name.contains('teredo') ||
        name.contains('isatap')) {
      return false;
    }

    // Exclude cellular CG-NAT range (100.64.0.0/10) unless clearly a local LAN interface
    if (_isCarrierGradeNat(ip) && !_isPrimaryWifiOrLanName(name)) {
      return false;
    }

    // On Android, only accept recognized Wi-Fi / LAN / Hotspot / P2P interfaces so
    // cellular private 10.x.x.x adapters never falsely report Wi-Fi Connected.
    if (!_isPrimaryWifiOrLanName(name) && !_isHotspotOrP2pName(name)) {
      if (Platform.isAndroid) return false;
      return _isPrivateRfc1918(ip);
    }

    return true;
  }

  static bool _isPrimaryWifiOrLanName(String lowerName) {
    return lowerName.startsWith('wlan') ||
        lowerName.startsWith('eth') ||
        lowerName.startsWith('en') ||
        lowerName.startsWith('wl') ||
        lowerName.contains('wi-fi') ||
        lowerName.contains('wifi') ||
        lowerName.contains('ethernet') ||
        lowerName.contains('wlan');
  }

  static bool _isHotspotOrP2pName(String lowerName) {
    return lowerName.startsWith('p2p') ||
        lowerName.startsWith('swlan') ||
        lowerName.startsWith('ap') ||
        lowerName.contains('softap') ||
        lowerName.contains('hotspot') ||
        lowerName.contains('local area connection*') ||
        lowerName.startsWith('rndis');
  }

  static bool _isPrivateRfc1918(String ip) {
    if (ip.startsWith('192.168.') || ip.startsWith('10.')) return true;
    final parts = ip.split('.');
    if (parts.length == 4 && parts[0] == '172') {
      final second = int.tryParse(parts[1]) ?? -1;
      return second >= 16 && second <= 31;
    }
    return false;
  }

  static bool _isCarrierGradeNat(String ip) {
    final parts = ip.split('.');
    if (parts.length == 4 && parts[0] == '100') {
      final second = int.tryParse(parts[1]) ?? -1;
      return second >= 64 && second <= 127;
    }
    return false;
  }

  /// Returns filtered LAN / Wi-Fi / Hotspot interfaces (cached briefly to avoid duplicate OS queries).
  static Future<List<NetworkInterface>> getLanInterfaces({
    bool forceRefresh = false,
  }) async {
    final now = DateTime.now();
    if (!forceRefresh &&
        _cachedInterfaces != null &&
        _cacheTimestamp != null &&
        now.difference(_cacheTimestamp!) < _cacheTtl) {
      return _cachedInterfaces!;
    }

    final primary = <NetworkInterface>[];
    final hotspot = <NetworkInterface>[];
    final other = <NetworkInterface>[];

    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );

      for (final iface in interfaces) {
        final hasValidIp = iface.addresses.any(
          (addr) => isValidLanInterface(iface.name, addr.address),
        );
        if (!hasValidIp) continue;

        final lower = iface.name.toLowerCase();
        if (_isHotspotOrP2pName(lower)) {
          hotspot.add(iface);
        } else if (_isPrimaryWifiOrLanName(lower)) {
          primary.add(iface);
        } else {
          other.add(iface);
        }
      }
    } catch (e) {
      debugPrint('[NetworkInfo] getLanInterfaces error: $e');
    }

    final ordered = [...primary, ...hotspot, ...other];
    _cachedInterfaces = ordered;
    _cacheTimestamp = now;
    return ordered;
  }

  /// Returns the best local IPv4 address for P2P sharing.
  static Future<String?> getLocalIpAddress({bool forceRefresh = false}) async {
    final ips = await getLocalIpAddresses(forceRefresh: forceRefresh);
    if (ips.isEmpty) return null;
    return ips.first;
  }

  /// Returns all available local IPv4 addresses, prioritizing Wi-Fi/LAN, then Hotspot/P2P, then other RFC1918.
  static Future<List<String>> getLocalIpAddresses({
    bool forceRefresh = false,
  }) async {
    final orderedIps = <String>[];
    final interfaces = await getLanInterfaces(forceRefresh: forceRefresh);

    for (final iface in interfaces) {
      for (final addr in iface.addresses) {
        final ip = addr.address;
        if (isValidLanInterface(iface.name, ip) && !orderedIps.contains(ip)) {
          orderedIps.add(ip);
        }
      }
    }

    return orderedIps;
  }

  /// Calculates potential broadcast and multicast addresses for subnet and global broadcast.
  static Future<List<String>> getBroadcastAddresses() async {
    final addresses = <String>{
      '255.255.255.255',
      '224.0.0.1',
      '224.0.0.167',
    };
    final localIps = await getLocalIpAddresses();

    for (final ip in localIps) {
      final parts = ip.split('.');
      if (parts.length == 4) {
        addresses.add('${parts[0]}.${parts[1]}.${parts[2]}.255');
      }
    }

    return addresses.toList();
  }

  /// Returns the current operating system platform identifier.
  static String getPlatformName() {
    if (Platform.isAndroid) return 'android';
    if (Platform.isIOS) return 'ios';
    if (Platform.isWindows) return 'windows';
    if (Platform.isMacOS) return 'macos';
    if (Platform.isLinux) return 'linux';
    return 'unknown';
  }
}
