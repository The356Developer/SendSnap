import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'air_gesture_classifier.dart';

class AirGestureService {
  static const MethodChannel _methodChannel =
      MethodChannel('com.the356company.sendsnap/air_gesture');
  static const EventChannel _eventChannel =
      EventChannel('com.the356company.sendsnap/air_gesture_events');

  final AirGestureClassifier _classifier;
  final StreamController<AirGestureFrame> _frameController =
      StreamController<AirGestureFrame>.broadcast();

  StreamSubscription<dynamic>? _nativeSubscription;
  bool _isRunning = false;

  AirGestureService({AirGestureClassifier? classifier})
      : _classifier = classifier ??
            AirGestureClassifier(confirmFrames: 2, cooldownMs: 900);

  Stream<AirGestureFrame> get frames => _frameController.stream;
  bool get isRunning => _isRunning;

  Future<bool> isSupported() async {
    if (!Platform.isAndroid) return false;
    try {
      final supported = await _methodChannel.invokeMethod<bool>('isSupported');
      return supported ?? false;
    } catch (e) {
      debugPrint('[AirGestureService] isSupported error: $e');
      return false;
    }
  }

  Future<bool> start() async {
    if (!Platform.isAndroid) return false;
    await stop();
    _classifier.reset();

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

          final frame = _classifier.classify(
            detected: detected,
            landmarks: landmarks,
            timestampMs: timestampMs,
          );
          if (!_frameController.isClosed) {
            _frameController.add(frame);
          }
        },
        onError: (Object error) {
          debugPrint('[AirGestureService] Stream error: $error');
          if (!_frameController.isClosed) {
            _frameController.addError(error);
          }
        },
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
    }
    _classifier.reset();
  }

  Future<void> dispose() async {
    await stop();
    await _frameController.close();
  }
}
