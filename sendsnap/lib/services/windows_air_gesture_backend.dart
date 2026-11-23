import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:hand_detection/hand_detection.dart' as hd;
import 'package:opencv_dart/opencv_dart.dart' as cv;

import 'air_gesture_classifier.dart';

typedef RawHandFrameCallback = void Function({
  required bool detected,
  required List<HandLandmark> landmarks,
  required int timestampMs,
});

/// Windows webcam + MediaPipe/LiteRT hand landmark backend for Air Gestures.
///
/// Captures mirrored low-resolution frames from the default webcam via OpenCV
/// (`VideoCaptureAsync`), runs on-device 21-point hand landmark detection on
/// `hand_detection`'s background isolate, and emits normalized `0.0..1.0`
/// coordinates compatible with [AirGestureClassifier].
class WindowsAirGestureBackend {
  static const int _targetIntervalMs = 80;
  static const int _maxConsecutiveFailures = 30;

  hd.HandDetector? _detector;
  cv.VideoCapture? _capture;
  Future<void>? _loopFuture;
  Future<bool>? _probeFuture;

  bool? _cachedSupported;
  bool _isStarting = false;
  bool _isRunning = false;
  bool _isDisposed = false;
  int _sessionToken = 0;

  bool get isRunning => _isRunning;

  Future<bool> isSupported() async {
    if (_isDisposed) return false;
    if (_isRunning || _isStarting || _cachedSupported == true) {
      return true;
    }
    if (_probeFuture != null) {
      return await _probeFuture!;
    }

    final future = _probeCameraAvailability();
    _probeFuture = future;
    try {
      return await future;
    } finally {
      if (identical(_probeFuture, future)) {
        _probeFuture = null;
      }
    }
  }

  Future<bool> _probeCameraAvailability() async {
    cv.VideoCapture? cap;
    try {
      cap = await _openCapture();
      final supported = cap != null && cap.isOpened;
      if (supported) {
        _cachedSupported = true;
      }
      return supported;
    } catch (e) {
      debugPrint('[WindowsAirGestureBackend] isSupported error: $e');
      return false;
    } finally {
      _disposeCapture(cap);
    }
  }

  Future<bool> start({
    required RawHandFrameCallback onFrame,
    void Function(Object error)? onError,
  }) async {
    if (_isDisposed) return false;

    if (_probeFuture != null) {
      try {
        await _probeFuture;
      } catch (_) {}
    }

    await stop();
    if (_isDisposed) return false;

    final token = ++_sessionToken;
    _isStarting = true;
    cv.VideoCapture? openedCapture;

    try {
      final detector = _detector ??= await hd.HandDetector.create(
        mode: hd.HandMode.boxesAndLandmarks,
        maxDetections: 1,
        detectorConf: 0.5,
        minLandmarkScore: 0.5,
        enableTracking: true,
      );
      if (_isDisposed) {
        _detector = null;
        try {
          await detector.dispose();
        } catch (_) {}
        return false;
      }
      if (token != _sessionToken) return false;

      await detector.resetTracking();
      if (_isDisposed || token != _sessionToken) return false;

      openedCapture = await _openCapture();
      if (openedCapture == null || !openedCapture.isOpened) {
        _disposeCapture(openedCapture);
        return false;
      }
      if (token != _sessionToken) {
        _disposeCapture(openedCapture);
        return false;
      }

      openedCapture.set(cv.CAP_PROP_FRAME_WIDTH, 320);
      openedCapture.set(cv.CAP_PROP_FRAME_HEIGHT, 240);

      _cachedSupported = true;
      _capture = openedCapture;
      _isRunning = true;

      _loopFuture = _captureLoop(
        token: token,
        cap: openedCapture,
        detector: detector,
        onFrame: onFrame,
        onError: onError,
      );
      return true;
    } catch (e) {
      debugPrint('[WindowsAirGestureBackend] start error: $e');
      _disposeCapture(openedCapture);
      if (identical(_capture, openedCapture)) {
        _capture = null;
      }
      _isRunning = false;
      onError?.call(e);
      return false;
    } finally {
      _isStarting = false;
    }
  }

  Future<void> _captureLoop({
    required int token,
    required cv.VideoCapture cap,
    required hd.HandDetector detector,
    required RawHandFrameCallback onFrame,
    void Function(Object error)? onError,
  }) async {
    int consecutiveFailures = 0;

    while (_isRunning && token == _sessionToken) {
      final frameStartMs = DateTime.now().millisecondsSinceEpoch;
      cv.Mat? frame;
      cv.Mat? mirrored;

      try {
        final (ok, readMat) = await cap.readAsync();
        frame = readMat;

        if (!_isRunning || token != _sessionToken) break;

        if (!ok || readMat.isEmpty) {
          consecutiveFailures++;
          if (consecutiveFailures >= _maxConsecutiveFailures) {
            _isRunning = false;
            onError?.call(StateError('Webcam stopped delivering frames.'));
            break;
          }
          await Future<void>.delayed(
            const Duration(milliseconds: _targetIntervalMs),
          );
          continue;
        }

        consecutiveFailures = 0;

        // Mirror horizontally to match front-facing selfie camera orientation.
        mirrored = await cv.flipAsync(readMat, 1);
        readMat.dispose();
        frame = null;

        if (!_isRunning || token != _sessionToken) break;

        final hands = await detector.detectFromMat(mirrored);
        if (!_isRunning || token != _sessionToken) break;

        final hand = hands.firstOrNull;
        final landmarks = _extractNormalizedLandmarks(
          hand,
          fallbackWidth: mirrored.cols,
          fallbackHeight: mirrored.rows,
        );

        onFrame(
          detected: landmarks.length >= 21,
          landmarks: landmarks,
          timestampMs: DateTime.now().millisecondsSinceEpoch,
        );
      } catch (e) {
        if (!_isRunning || token != _sessionToken) break;
        debugPrint('[WindowsAirGestureBackend] Capture loop error: $e');
        consecutiveFailures++;
        if (consecutiveFailures >= _maxConsecutiveFailures) {
          _isRunning = false;
          onError?.call(e);
          break;
        }
      } finally {
        frame?.dispose();
        mirrored?.dispose();
      }

      if (!_isRunning || token != _sessionToken) break;

      final elapsedMs = DateTime.now().millisecondsSinceEpoch - frameStartMs;
      final remainingMs = _targetIntervalMs - elapsedMs;
      if (remainingMs > 0) {
        await Future<void>.delayed(Duration(milliseconds: remainingMs));
      }
    }
  }

  List<HandLandmark> _extractNormalizedLandmarks(
    hd.Hand? hand, {
    required int fallbackWidth,
    required int fallbackHeight,
  }) {
    if (hand == null || hand.landmarks.length < 21) {
      return const [];
    }

    final width = (hand.imageWidth > 0 ? hand.imageWidth : fallbackWidth)
        .toDouble();
    final height = (hand.imageHeight > 0 ? hand.imageHeight : fallbackHeight)
        .toDouble();
    if (width <= 0 || height <= 0) {
      return const [];
    }

    // Map by HandLandmarkType index order (0..20) to match MediaPipe topology.
    final byType = <hd.HandLandmarkType, hd.HandLandmark>{
      for (final lm in hand.landmarks) lm.type: lm,
    };

    final normalized = <HandLandmark>[];
    for (final type in hd.HandLandmarkType.values) {
      final lm = byType[type];
      if (lm == null) {
        return const [];
      }
      normalized.add(
        HandLandmark(
          (lm.x / width).clamp(0.0, 1.0),
          (lm.y / height).clamp(0.0, 1.0),
          lm.z / width,
        ),
      );
    }
    return normalized;
  }

  Future<cv.VideoCapture?> _openCapture() async {
    final dshow = await cv.VideoCaptureAsync.fromDeviceAsync(
      0,
      apiPreference: cv.CAP_DSHOW,
    );
    if (dshow.isOpened) {
      return dshow;
    }
    _disposeCapture(dshow);

    final fallback = await cv.VideoCaptureAsync.fromDeviceAsync(0);
    if (fallback.isOpened) {
      return fallback;
    }
    _disposeCapture(fallback);
    return null;
  }

  void _disposeCapture(cv.VideoCapture? cap) {
    if (cap == null) return;
    try {
      if (cap.isOpened) {
        cap.release();
      }
    } catch (_) {}
    try {
      cap.dispose();
    } catch (_) {}
  }

  Future<void> stop() async {
    _sessionToken++;
    _isRunning = false;

    final loop = _loopFuture;
    _loopFuture = null;
    if (loop != null) {
      try {
        await loop;
      } catch (_) {}
    }

    final cap = _capture;
    _capture = null;
    _disposeCapture(cap);
  }

  Future<void> dispose() async {
    _isDisposed = true;
    await stop();
    final detector = _detector;
    _detector = null;
    if (detector != null) {
      try {
        await detector.dispose();
      } catch (_) {}
    }
  }
}
