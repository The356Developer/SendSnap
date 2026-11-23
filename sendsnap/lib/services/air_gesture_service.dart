import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'air_gesture_classifier.dart';
import 'windows_air_gesture_backend.dart';

class AirGestureService {
  static const MethodChannel _methodChannel =
      MethodChannel('com.the356company.sendsnap/air_gesture');
  static const EventChannel _eventChannel =
      EventChannel('com.the356company.sendsnap/air_gesture_events');

  final AirGestureClassifier _classifier;
  final StreamController<AirGestureFrame> _frameController =
      StreamController<AirGestureFrame>.broadcast();

  StreamSubscription<dynamic>? _nativeSubscription;
  WindowsAirGestureBackend? _windowsBackend;
  bool _isRunning = false;

  AirGestureService({AirGestureClassifier? classifier})
      : _classifier = classifier ??
            AirGestureClassifier(confirmFrames: 2, cooldownMs: 900);

  Stream<AirGestureFrame> get frames => _frameController.stream;
  bool get isRunning => _isRunning;
  bool get _usesDesktopBackend => Platform.isWindows || Platform.isLinux;

  Future<bool> isSupported() async {
    if (Platform.isAndroid) {
      try {
        final supported = await _methodChannel.invokeMethod<bool>('isSupported');
        return supported ?? false;
      } catch (e) {
        debugPrint('[AirGestureService] isSupported error: $e');
        return false;
      }
    }
    if (_usesDesktopBackend) {
      try {
        final backend = _windowsBackend ??= WindowsAirGestureBackend();
        return await backend.isSupported();
      } catch (e) {
        debugPrint('[AirGestureService] Desktop isSupported error: $e');
        return false;
      }
    }
    return false;
  }

  Future<bool> start() async {
    if (!Platform.isAndroid && !_usesDesktopBackend) return false;
    await stop();
    _classifier.reset();

    if (_usesDesktopBackend) {
      try {
        final backend = _windowsBackend ??= WindowsAirGestureBackend();
        final started = await backend.start(
          onFrame: ({
            required bool detected,
            required List<HandLandmark> landmarks,
            required int timestampMs,
          }) {
            _emitClassifiedFrame(
              detected: detected,
              landmarks: landmarks,
              timestampMs: timestampMs,
            );
          },
          onError: _emitStreamError,
        );
        _isRunning = started;
        return _isRunning;
      } catch (e) {
        debugPrint('[AirGestureService] Desktop start error: $e');
        _isRunning = false;
        return false;
      }
    }

    try {
      _nativeSubscription = _eventChannel.receiveBroadcastStream().listen(
        (dynamic event) {
          if (event is! Map) return;
          final detected = event['detected'] as bool? ?? false;
          final timestampMs = (event['timestampMs'] as num?)?.toInt() ??
              DateTime.now().millisecondsSinceEpoch;
          final rawLandmarks = event['landmarks'] as List<dynamic>? ?? const [];
          final landmarks = rawLandmarks
              .whereType<Map<dynamic, dynamic>>()
              .map(HandLandmark.fromMap)
              .toList(growable: false);

          _emitClassifiedFrame(
            detected: detected,
            landmarks: landmarks,
            timestampMs: timestampMs,
          );
        },
        onError: _emitStreamError,
      );

      final started = await _methodChannel.invokeMethod<bool>('start');
      _isRunning = started ?? false;
      if (!_isRunning) {
        await _nativeSubscription?.cancel();
        _nativeSubscription = null;
      }
      return _isRunning;
    } catch (e) {
      debugPrint('[AirGestureService] start error: $e');
      await _nativeSubscription?.cancel();
      _nativeSubscription = null;
      _isRunning = false;
      return false;
    }
  }

  void _emitClassifiedFrame({
    required bool detected,
    required List<HandLandmark> landmarks,
    required int timestampMs,
  }) {
    final frame = _classifier.classify(
      detected: detected,
      landmarks: landmarks,
      timestampMs: timestampMs,
    );
    if (!_frameController.isClosed) {
      _frameController.add(frame);
    }
  }

  void _emitStreamError(Object error) {
    debugPrint('[AirGestureService] Stream error: $error');
    if (!_frameController.isClosed) {
      _frameController.addError(error);
    }
  }

  Future<void> stop() async {
    _isRunning = false;
    try {
      await _nativeSubscription?.cancel();
    } catch (_) {}
    _nativeSubscription = null;

    if (Platform.isAndroid) {
      try {
        await _methodChannel.invokeMethod<bool>('stop');
      } catch (_) {}
    } else if (_usesDesktopBackend) {
      try {
        await _windowsBackend?.stop();
      } catch (_) {}
    }
    _classifier.reset();
  }

  Future<void> dispose() async {
    await stop();
    if (_usesDesktopBackend) {
      try {
        await _windowsBackend?.dispose();
      } catch (_) {}
      _windowsBackend = null;
    }
    await _frameController.close();
  }
}
