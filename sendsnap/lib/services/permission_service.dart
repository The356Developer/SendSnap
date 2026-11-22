import 'dart:io';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';

/// Manages runtime permissions for SendSnap.
class PermissionService {
  /// Request essential permissions (Storage / Media & Nearby Wi-Fi for Direct Discovery).
  Future<bool> requestAllPermissions() async {
    final results = <Permission, PermissionStatus>{};

    if (Platform.isAndroid) {
      final androidVersion = await _getAndroidVersion();

      // Storage / Media permissions for picking files to share
      if (androidVersion >= 33) {
        results[Permission.photos] = await Permission.photos.request();
        results[Permission.videos] = await Permission.videos.request();
        results[Permission.audio] = await Permission.audio.request();
      } else if (androidVersion >= 30) {
        results[Permission.storage] = await Permission.storage.request();
      } else {
        results[Permission.storage] = await Permission.storage.request();
      }

      // Request Nearby Wi-Fi / Location permission (non-blocking: LAN still works if declined)
      await requestNearbyWifiPermission();
    }

    for (final entry in results.entries) {
      debugPrint('[SendSnap] Permission ${entry.key}: ${entry.value}');
    }

    return true;
  }

  /// Checks whether the required permission for Wi-Fi Direct / Nearby Wi-Fi discovery is granted.
  Future<bool> hasNearbyWifiPermission() async {
    if (!Platform.isAndroid) return true;
    final androidVersion = await _getAndroidVersion();
    if (androidVersion >= 33) {
      return await Permission.nearbyWifiDevices.isGranted;
    }
    return await Permission.locationWhenInUse.isGranted;
  }

  /// Requests Nearby Wi-Fi permission (API 33+: NEARBY_WIFI_DEVICES, API <=32: Location),
  /// plus non-blocking Bluetooth LE scan/advertise permissions on Android 12+.
  Future<bool> requestNearbyWifiPermission() async {
    if (!Platform.isAndroid) return true;
    var wifiGranted = false;
    try {
      final androidVersion = await _getAndroidVersion();
      if (androidVersion >= 33) {
        if (await Permission.nearbyWifiDevices.isGranted) {
          wifiGranted = true;
        } else {
          final status = await Permission.nearbyWifiDevices.request();
          debugPrint('[SendSnap] Permission nearbyWifiDevices: $status');
          wifiGranted = status.isGranted;
        }
      } else {
        if (await Permission.locationWhenInUse.isGranted) {
          wifiGranted = true;
        } else {
          final status = await Permission.locationWhenInUse.request();
          debugPrint('[SendSnap] Permission locationWhenInUse: $status');
          wifiGranted = status.isGranted;
        }
      }

      if (androidVersion >= 31) {
        try {
          if (!await Permission.bluetoothScan.isGranted) {
            final scanStatus = await Permission.bluetoothScan.request();
            debugPrint('[SendSnap] Permission bluetoothScan: $scanStatus');
          }
          if (!await Permission.bluetoothAdvertise.isGranted) {
            final advStatus = await Permission.bluetoothAdvertise.request();
            debugPrint('[SendSnap] Permission bluetoothAdvertise: $advStatus');
          }
        } catch (e) {
          debugPrint('[SendSnap] BLE permission request note: $e');
        }
      }

      return wifiGranted;
    } catch (e) {
      debugPrint('[SendSnap] requestNearbyWifiPermission error: $e');
      return false;
    }
  }

  /// Check if we have storage read permission.
  Future<bool> hasStoragePermission() async {
    if (Platform.isAndroid) {
      final androidVersion = await _getAndroidVersion();
      if (androidVersion >= 30) {
        if (await Permission.manageExternalStorage.isGranted) return true;
      }
      if (androidVersion >= 33) {
        final photos = await Permission.photos.isGranted;
        final videos = await Permission.videos.isGranted;
        return photos || videos;
      } else {
        return await Permission.storage.isGranted;
      }
    }
    return true;
  }

  /// Check whether MANAGE_EXTERNAL_STORAGE (All Files Access) is granted on Android 11+.
  Future<bool> hasManageExternalStoragePermission() async {
    if (Platform.isAndroid) {
      final androidVersion = await _getAndroidVersion();
      if (androidVersion >= 30) {
        return await Permission.manageExternalStorage.isGranted;
      }
      return await Permission.storage.isGranted;
    }
    return true;
  }

  /// Request all files access (MANAGE_EXTERNAL_STORAGE) if needed for browsing internal storage
  Future<bool> requestStorageManagementIfNeeded() async {
    if (Platform.isAndroid) {
      final androidVersion = await _getAndroidVersion();
      if (androidVersion >= 30) {
        if (!await Permission.manageExternalStorage.isGranted) {
          final status = await Permission.manageExternalStorage.request();
          return status.isGranted;
        }
        return true;
      }
    }
    return true;
  }

  /// Check if network transfer / Wi-Fi Direct permissions are ready.
  Future<bool> hasNearbyConnectionsPermissions() async {
    return await hasNearbyWifiPermission();
  }

  /// Location check (not strictly required for local Wi-Fi, returns true).
  Future<bool> ensureLocationEnabled() async {
    return true;
  }

  /// Requests camera permission for QR scanning and Air Gestures on Android.
  Future<bool> requestCameraPermission() async {
    if (!Platform.isAndroid) return true;
    try {
      if (await Permission.camera.isGranted) return true;
      final status = await Permission.camera.request();
      debugPrint('[SendSnap] Permission camera: $status');
      return status.isGranted;
    } catch (e) {
      debugPrint('[SendSnap] requestCameraPermission error: $e');
      return false;
    }
  }

  /// Open app settings so user can manually grant permissions.
  Future<void> openSettings() async {
    await openAppSettings();
  }

  Future<int> _getAndroidVersion() async {
    try {
      if (Platform.isAndroid) {
        final androidInfo = await DeviceInfoPlugin().androidInfo;
        return androidInfo.version.sdkInt;
      }
      return 0;
    } catch (e) {
      debugPrint('[SendSnap] Error detecting Android version: $e');
      return 29;
    }
  }
}
