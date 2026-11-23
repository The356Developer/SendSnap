import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sendsnap/models/device.dart';
import 'package:sendsnap/services/direct_p2p_service.dart';
import 'package:sendsnap/services/discovery_service.dart';
import 'package:sendsnap/services/http_transfer_client.dart';
import 'package:sendsnap/services/http_transfer_server.dart';
import 'package:sendsnap/services/nearby_service.dart';
import 'package:sendsnap/services/network_info_service.dart';

void main() {
  HttpOverrides.global = null;

  group('NetworkInfoService.isValidLanInterface', () {
    test('accepts valid Wi-Fi, Ethernet, and Hotspot/P2P interfaces', () {
      expect(NetworkInfoService.isValidLanInterface('wlan0', '192.168.1.25'), isTrue);
      expect(NetworkInfoService.isValidLanInterface('p2p-wlan0-0', '192.168.49.1'), isTrue);
      expect(NetworkInfoService.isValidLanInterface('swlan0', '192.168.43.1'), isTrue);
      expect(NetworkInfoService.isValidLanInterface('Ethernet', '10.0.0.42'), isTrue);
      expect(NetworkInfoService.isValidLanInterface('Wi-Fi', '172.16.5.12'), isTrue);
    });

    test('rejects cellular, VPN, virtual adapters, loopback, and link-local', () {
      expect(NetworkInfoService.isValidLanInterface('rmnet_data0', '10.120.4.5'), isFalse);
      expect(NetworkInfoService.isValidLanInterface('ccmni0', '100.80.1.2'), isFalse);
      expect(NetworkInfoService.isValidLanInterface('tun0', '10.8.0.2'), isFalse);
      expect(NetworkInfoService.isValidLanInterface('vEthernet (WSL)', '172.24.16.1'), isFalse);
      expect(NetworkInfoService.isValidLanInterface('VirtualBox Host-Only Network', '192.168.56.1'), isFalse);
      expect(NetworkInfoService.isValidLanInterface('lo', '127.0.0.1'), isFalse);
      expect(NetworkInfoService.isValidLanInterface('wlan0', '127.0.0.1'), isFalse);
      expect(NetworkInfoService.isValidLanInterface('wlan0', '169.254.1.2'), isFalse);
    });
  });

  group('NearbyDevice JSON serialization & backward compatibility', () {
    test('deserializes legacy v2.2.x JSON without connectionType or p2p fields', () {
      final legacyJson = <String, dynamic>{
        'id': 'abc12345',
        'name': 'Pixel 8',
        'ip': '192.168.1.40',
        'port': 53318,
        'deviceType': 'android',
        'serviceId': 'com.the356company.sendsnap',
      };

      final device = NearbyDevice.fromJson(legacyJson);
      expect(device.id, 'abc12345');
      expect(device.name, 'Pixel 8');
      expect(device.ip, '192.168.1.40');
      expect(device.connectionType, 'lan');
      expect(device.isWifiDirect, isFalse);
      expect(device.hasLanIp, isTrue);
      expect(device.hasDirectCredentials, isFalse);
    });

    test('round-trips Direct Wi-Fi device fields cleanly', () {
      final device = NearbyDevice(
        id: 'p2p001',
        name: 'Galaxy S24',
        ip: '',
        port: 53318,
        deviceType: 'android',
        connectionType: 'wifi_direct',
        p2pDeviceAddress: '02:00:00:00:00:01',
        p2pSsid: 'DIRECT-S5-SnapA1B2',
        p2pPassphrase: 'SecretPass12',
        p2pGoIp: '192.168.49.1',
      );

      final decoded = NearbyDevice.fromJson(device.toJson());
      expect(decoded.id, 'p2p001');
      expect(decoded.connectionType, 'wifi_direct');
      expect(decoded.isWifiDirect, isTrue);
      expect(decoded.hasDirectCredentials, isTrue);
      expect(decoded.hasLanIp, isFalse);
      expect(decoded.p2pSsid, 'DIRECT-S5-SnapA1B2');
      expect(decoded.p2pPassphrase, 'SecretPass12');
      expect(decoded.p2pGoIp, '192.168.49.1');
    });
  });

  group('DirectP2pService QR payload builder & parser', () {
    test('parses legacy sendsnap://ip:port QR string', () {
      final parsed = DirectP2pService.parseQrPayload('sendsnap://192.168.1.5:53318');
      expect(parsed, isNotNull);
      expect(parsed!.lanIp, '192.168.1.5');
      expect(parsed.port, 53318);
      expect(parsed.hasUsableLanIp, isTrue);
      expect(parsed.hasDirectCredentials, isFalse);
    });

    test('round-trips enriched LAN + Direct Wi-Fi QR payload', () {
      const hotspot = DirectHotspotInfo(
        ssid: 'DIRECT-S5-SnapZ9K4',
        passphrase: 'PassWord9876',
        goIp: '192.168.49.1',
        port: 53318,
      );
      final qr = DirectP2pService.buildQrPayload(
        lanIp: '192.168.1.88',
        port: 53318,
        hotspot: hotspot,
        deviceId: 'dev1122',
        deviceName: 'My Phone',
      );

      final parsed = DirectP2pService.parseQrPayload(qr);
      expect(parsed, isNotNull);
      expect(parsed!.lanIp, '192.168.1.88');
      expect(parsed.port, 53318);
      expect(parsed.ssid, 'DIRECT-S5-SnapZ9K4');
      expect(parsed.passphrase, 'PassWord9876');
      expect(parsed.p2pIp, '192.168.49.1');
      expect(parsed.deviceId, 'dev1122');
      expect(parsed.deviceName, 'My Phone');
      expect(parsed.hasDirectCredentials, isTrue);
      expect(parsed.hasUsableLanIp, isTrue);
    });

    test('round-trips Direct-only (no router) QR payload with p2pOnly=1', () {
      const hotspot = DirectHotspotInfo(
        ssid: 'DIRECT-S5-SnapQ1W2',
        passphrase: 'OfflineKey99',
        goIp: '192.168.49.1',
        port: 53318,
      );
      final qr = DirectP2pService.buildQrPayload(
        lanIp: null,
        port: 53318,
        hotspot: hotspot,
      );

      final parsed = DirectP2pService.parseQrPayload(qr);
      expect(parsed, isNotNull);
      expect(parsed!.lanIp, isNull);
      expect(parsed.hasUsableLanIp, isFalse);
      expect(parsed.hasDirectCredentials, isTrue);
      expect(parsed.ssid, 'DIRECT-S5-SnapQ1W2');
      expect(parsed.passphrase, 'OfflineKey99');
      expect(parsed.p2pIp, '192.168.49.1');
    });
  });

  group('DiscoveryService role filtering', () {
    test('sender/warm discovery accepts receivers and legacy packets, rejects senders', () {
      expect(
        DiscoveryService.shouldAcceptPacket(localIsReceiver: false, remoteRole: 'receiver'),
        isTrue,
      );
      expect(
        DiscoveryService.shouldAcceptPacket(localIsReceiver: false, remoteRole: null),
        isTrue,
      );
      expect(
        DiscoveryService.shouldAcceptPacket(localIsReceiver: false, remoteRole: 'sender'),
        isFalse,
      );
    });
  });

  group('HttpTransferClient.fastProbe', () {
    test('detects live server with deviceType and fails fast on closed port', () async {
      final server = HttpTransferServer();
      final client = HttpTransferClient();

      final localDevice = NearbyDevice(
        id: 'probe-rx-1',
        name: 'Probe Receiver',
        ip: '127.0.0.1',
        port: 0,
        deviceType: 'android',
      );
      final boundPort = await server.startServer(localDevice: localDevice, port: 0);
      expect(boundPort, isNotNull);

      try {
        final found = await client.fastProbe('127.0.0.1', boundPort!);
        expect(found, isNotNull);
        expect(found!.id, 'probe-rx-1');
        expect(found.name, 'Probe Receiver');
        expect(found.deviceType, 'android');

        // Grab a guaranteed closed ephemeral port
        final tempSocket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
        final unusedPort = tempSocket.port;
        await tempSocket.close();

        final sw = Stopwatch()..start();
        final missed = await client.fastProbe(
          '127.0.0.1',
          unusedPort,
          connectTimeout: const Duration(milliseconds: 350),
        );
        sw.stop();

        expect(missed, isNull);
        expect(sw.elapsedMilliseconds, lessThan(1500));
      } finally {
        await server.stopServer();
      }
    });
  });

  group('Cross-network Direct Wi-Fi & BLE-UUID lookup', () {
    test('NearbyService.getDevice resolves ble-<hex12> to merged UUID and vice versa', () {
      final service = NearbyService();

      // Case 1: Full UUID registered, queried via ble-<hex12> alias
      final uuidDevice = NearbyDevice(
        id: 'a1b2c3d4-e5f6-7890-1234-567890abcdef',
        name: 'Receiver Phone',
        ip: '192.168.1.50',
        port: 53318,
        deviceType: 'android',
      );
      service.addManualDevice(uuidDevice);

      final resolvedFromBle = service.getDevice('ble-a1b2c3d4e5f6');
      expect(resolvedFromBle, isNotNull);
      expect(resolvedFromBle!.id, uuidDevice.id);
      expect(resolvedFromBle.name, 'Receiver Phone');

      // Case 2: ble-<hex12> registered, queried via full UUID alias
      final bleService = NearbyService();
      final bleDevice = NearbyDevice(
        id: 'ble-ffeeddccbbaa',
        name: 'Offline Phone',
        ip: '',
        port: 53318,
        deviceType: 'android',
        connectionType: 'wifi_direct',
        p2pSsid: 'DIRECT-S5-SnapTest',
        p2pPassphrase: 'PassWord1',
      );
      bleService.addManualDevice(bleDevice);

      final resolvedFromUuid = bleService.getDevice('ffeeddcc-bbaa-1122-3344-556677889900');
      expect(resolvedFromUuid, isNotNull);
      expect(resolvedFromUuid!.id, bleDevice.id);
      expect(resolvedFromUuid.p2pSsid, 'DIRECT-S5-SnapTest');
    });

    test('DirectP2pService.connectToPeer accepts port and returns clean error off-Android', () async {
      final p2p = DirectP2pService();
      final res = await p2p.connectToPeer(
        ssid: 'DIRECT-S5-Snap1234',
        passphrase: 'Password1',
        goIp: '192.168.49.1',
        port: 53319,
      );
      if (!Platform.isAndroid) {
        expect(res.success, isFalse);
        expect(res.error, isNotNull);
      }
    });
  });
}
