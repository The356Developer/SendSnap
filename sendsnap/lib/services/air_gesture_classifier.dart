import 'dart:math' as math;
import 'dart:ui';

class HandLandmark {
  final double x;
  final double y;
  final double z;

  const HandLandmark(this.x, this.y, this.z);

  factory HandLandmark.fromMap(Map<dynamic, dynamic> map) {
    return HandLandmark(
      (map['x'] as num?)?.toDouble() ?? 0.0,
      (map['y'] as num?)?.toDouble() ?? 0.0,
      (map['z'] as num?)?.toDouble() ?? 0.0,
    );
  }
}

enum HandPosture {
  none,
  open,
  fist,
  transition,
}

enum AirGestureAction {
  grab,
  release,
}

class AirGestureFrame {
  final bool detected;
  final HandPosture posture;
  final double openness;
  final Offset handCenter;
  final List<HandLandmark> landmarks;
  final AirGestureAction? triggeredAction;
  final int timestampMs;

  const AirGestureFrame({
    required this.detected,
    required this.posture,
    required this.openness,
    required this.handCenter,
    required this.landmarks,
    this.triggeredAction,
    required this.timestampMs,
  });
}

class AirGestureClassifier {
  final int confirmFrames;
  final int cooldownMs;

  HandPosture _confirmedPosture = HandPosture.none;
  HandPosture? _pendingPosture;
  int _pendingCount = 0;
  int? _lastActionMs;
  int? _lastUndetectedStartMs;

  AirGestureClassifier({
    this.confirmFrames = 3,
    this.cooldownMs = 1200,
  });

  HandPosture get confirmedPosture => _confirmedPosture;

  void reset() {
    _confirmedPosture = HandPosture.none;
    _pendingPosture = null;
    _pendingCount = 0;
    _lastActionMs = null;
    _lastUndetectedStartMs = null;
  }

  AirGestureFrame classify({
    required bool detected,
    required List<HandLandmark> landmarks,
    required int timestampMs,
  }) {
    if (!detected || landmarks.length < 21) {
      _pendingPosture = null;
      _pendingCount = 0;
      _lastUndetectedStartMs ??= timestampMs;
      if (timestampMs - _lastUndetectedStartMs! > 500) {
        _confirmedPosture = HandPosture.none;
      }
      return AirGestureFrame(
        detected: false,
        posture: _confirmedPosture,
        openness: 0.0,
        handCenter: const Offset(0.5, 0.5),
        landmarks: const [],
        timestampMs: timestampMs,
      );
    }

    _lastUndetectedStartMs = null;

    final wrist = landmarks[0];
    final middleMcp = landmarks[9];
    final palmSize = _dist2D(wrist, middleMcp);
    final handCenter = Offset(
      ((wrist.x + middleMcp.x) / 2.0).clamp(0.0, 1.0),
      ((wrist.y + middleMcp.y) / 2.0).clamp(0.0, 1.0),
    );

    if (palmSize < 0.001) {
      return AirGestureFrame(
        detected: true,
        posture: _confirmedPosture == HandPosture.none
            ? HandPosture.transition
            : _confirmedPosture,
        openness: 0.0,
        handCenter: handCenter,
        landmarks: landmarks,
        timestampMs: timestampMs,
      );
    }

    const fingerJoints = <(int tip, int pip)>[
      (8, 6),   // Index
      (12, 10), // Middle
      (16, 14), // Ring
      (20, 18), // Pinky
    ];

    int extendedCount = 0;
    int curledCount = 0;
    double opennessSum = 0.0;

    for (final (tipIdx, pipIdx) in fingerJoints) {
      final dTip = _dist2D(landmarks[tipIdx], wrist);
      final dPip = _dist2D(landmarks[pipIdx], wrist);
      final ratio = dTip / palmSize;

      if (dTip > dPip * 1.12 && ratio > 1.45) {
        extendedCount++;
      }
      if (dTip < dPip * 1.05 || ratio < 1.15) {
        curledCount++;
      }

      opennessSum += ((ratio - 0.95) / 0.95).clamp(0.0, 1.0);
    }

    final openness = (opennessSum / 4.0).clamp(0.0, 1.0);

    final HandPosture rawPosture;
    if (extendedCount >= 1 && curledCount <= 2) {
      rawPosture = HandPosture.open;
    } else if (curledCount >= 3 && extendedCount == 0) {
      rawPosture = HandPosture.fist;
    } else {
      rawPosture = HandPosture.transition;
    }

    AirGestureAction? triggeredAction;

    if (rawPosture == HandPosture.open || rawPosture == HandPosture.fist) {
      if (_pendingPosture == rawPosture) {
        _pendingCount++;
      } else {
        _pendingPosture = rawPosture;
        _pendingCount = 1;
      }

      if (_pendingCount >= confirmFrames && _confirmedPosture != rawPosture) {
        final previousPosture = _confirmedPosture;
        _confirmedPosture = rawPosture;

        final cooldownElapsed = _lastActionMs == null ||
            (timestampMs - _lastActionMs!) >= cooldownMs;

        if (cooldownElapsed) {
          if (previousPosture == HandPosture.open &&
              rawPosture == HandPosture.fist) {
            triggeredAction = AirGestureAction.grab;
            _lastActionMs = timestampMs;
          } else if (previousPosture == HandPosture.fist &&
              rawPosture == HandPosture.open) {
            triggeredAction = AirGestureAction.release;
            _lastActionMs = timestampMs;
          }
        }
      }
    } else {
      _pendingPosture = null;
      _pendingCount = 0;
    }

    return AirGestureFrame(
      detected: true,
      posture: _confirmedPosture == HandPosture.none
          ? rawPosture
          : _confirmedPosture,
      openness: openness,
      handCenter: handCenter,
      landmarks: landmarks,
      triggeredAction: triggeredAction,
      timestampMs: timestampMs,
    );
  }

  static double _dist2D(HandLandmark a, HandLandmark b) {
    final dx = a.x - b.x;
    final dy = a.y - b.y;
    return math.sqrt(dx * dx + dy * dy);
  }
}
