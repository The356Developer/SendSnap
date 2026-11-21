import 'dart:async';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import '../models/device.dart';
import '../models/transfer.dart';

class HttpTransferClient {
  final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 10),
    receiveTimeout: const Duration(minutes: 60), // Allow long transfers
    sendTimeout: const Duration(minutes: 60),
  ));

  final Dio _pingDio = Dio(BaseOptions(
    connectTimeout: const Duration(milliseconds: 1200),
    receiveTimeout: const Duration(milliseconds: 1200),
    sendTimeout: const Duration(milliseconds: 1200),
  ));

  /// Fast raw TCP reachability probe before doing HTTP `/api/v1/info`.
  /// Fails within [connectTimeout] (~350ms) when a port is closed or unreachable.
  Future<NearbyDevice?> fastProbe(
    String ip,
    int port, {
    Duration connectTimeout = const Duration(milliseconds: 350),
  }) async {
    Socket? socket;
    try {
      socket = await Socket.connect(ip, port, timeout: connectTimeout);
      socket.destroy();
      socket = null;
      return await ping(ip, port);
    } catch (_) {
      socket?.destroy();
      return null;
    }
  }

  /// Tests connectivity to a target device IP and port.
  Future<NearbyDevice?> ping(String ip, int port, {Duration? timeout}) async {
    try {
      final effectiveTimeout = timeout ?? const Duration(milliseconds: 1200);
      final response = await _pingDio
          .get(
            'http://$ip:$port/api/v1/info',
            options: Options(
              responseType: ResponseType.json,
              receiveTimeout: effectiveTimeout,
              sendTimeout: effectiveTimeout,
            ),
          )
          .timeout(effectiveTimeout + const Duration(milliseconds: 300));
      if (response.statusCode == 200 && response.data is Map) {
        final data = response.data as Map<String, dynamic>;
        return NearbyDevice(
          id: data['id'] as String? ?? 'remote-$ip',
          name: data['name'] as String? ?? 'Device ($ip)',
          ip: ip,
          port: (data['port'] as num?)?.toInt() ?? port,
          deviceType: data['deviceType'] as String? ?? 'unknown',
          serviceId: data['serviceId'] as String? ?? 'com.the356company.sendsnap',
          lastSeen: DateTime.now(),
        );
      }
    } catch (e) {
      debugPrint('[HttpClient] Ping to $ip:$port failed: $e');
    }
    return null;
  }

  /// Repeatedly probes an IP after establishing a fresh Direct Wi-Fi / hotspot route.
  Future<NearbyDevice?> pingWithRetry(
    String ip,
    int port, {
    int maxAttempts = 8,
    Duration retryDelay = const Duration(milliseconds: 450),
  }) async {
    for (int attempt = 0; attempt < maxAttempts; attempt++) {
      final device = await ping(ip, port, timeout: const Duration(milliseconds: 1200));
      if (device != null) return device;
      if (attempt < maxAttempts - 1) {
        await Future.delayed(retryDelay);
      }
    }
    return null;
  }

  /// Initiates a transfer session with the target device.
  Future<bool> prepareTransfer({
    required NearbyDevice target,
    required NearbyDevice sender,
    required String sessionId,
    required List<FileTransfer> files,
  }) async {
    try {
      final payload = {
        'sessionId': sessionId,
        'sender': sender.toJson(),
        'files': files.map((f) => {
          'id': f.id,
          'name': f.fileName,
          'size': f.fileSize,
        }).toList(),
      };

      final response = await _dio.post(
        'http://${target.ip}:${target.port}/api/v1/prepare',
        data: payload,
        options: Options(contentType: Headers.jsonContentType),
      );

      if (response.statusCode == 200) {
        final data = response.data as Map<String, dynamic>?;
        return data?['status'] == 'accepted';
      }
      return false;
    } catch (e) {
      debugPrint('[HttpClient] prepareTransfer error: $e');
      return false;
    }
  }

  /// Streams a file to the target device with real-time speed and progress monitoring.
  Future<bool> uploadFile({
    required NearbyDevice target,
    required String sessionId,
    required FileTransfer fileTransfer,
    required File file,
    required Function(int sentBytes, int totalBytes, double speed) onProgress,
    CancelToken? cancelToken,
  }) async {
    final fileLength = await file.length();
    final stopwatch = Stopwatch()..start();
    DateTime lastUpdate = DateTime.now();

    try {
      final response = await _dio.post(
        'http://${target.ip}:${target.port}/api/v1/upload',
        queryParameters: {
          'sessionId': sessionId,
          'fileId': fileTransfer.id,
        },
        data: file.openRead(),
        options: Options(
          headers: {
            HttpHeaders.contentLengthHeader: fileLength,
            'X-File-Name': Uri.encodeComponent(fileTransfer.fileName),
          },
        ),
        cancelToken: cancelToken,
        onSendProgress: (sent, total) {
          final now = DateTime.now();
          if (now.difference(lastUpdate).inMilliseconds >= 100 || sent == total) {
            lastUpdate = now;
            final elapsedSeconds = stopwatch.elapsedMilliseconds / 1000.0;
            final speed = elapsedSeconds > 0 ? (sent / elapsedSeconds) : 0.0;
            onProgress(sent, fileLength, speed);
          }
        },
      );

      return response.statusCode == 200;
    } catch (e) {
      debugPrint('[HttpClient] uploadFile error for ${fileTransfer.fileName}: $e');
      return false;
    }
  }

  /// Cancels an active session on the target device.
  Future<void> cancelTransfer({
    required NearbyDevice target,
    required String sessionId,
  }) async {
    try {
      await _dio.post(
        'http://${target.ip}:${target.port}/api/v1/cancel',
        queryParameters: {'sessionId': sessionId},
      );
    } catch (_) {}
  }
}
