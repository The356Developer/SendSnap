import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sendsnap/models/air_session.dart';
import 'package:sendsnap/models/device.dart';
import 'package:sendsnap/services/air_gesture_classifier.dart';
import 'package:sendsnap/services/http_transfer_client.dart';
import 'package:sendsnap/services/http_transfer_server.dart';

List<HandLandmark> _buildSyntheticHand({required bool open}) {
  final landmarks = List<HandLandmark>.generate(
    21,
    (_) => const HandLandmark(0.5, 0.65, 0.0),
  );

  // Wrist and middle MCP define palmSize = 0.20
  landmarks[0] = const HandLandmark(0.50, 0.80, 0.0);
  landmarks[9] = const HandLandmark(0.50, 0.60, 0.0);

  if (open) {
    // Extended fingers (tips far above PIPs and wrist)
    landmarks[6] = const HandLandmark(0.42, 0.50, 0.0);
    landmarks[8] = const HandLandmark(0.42, 0.35, 0.0);

    landmarks[10] = const HandLandmark(0.50, 0.48, 0.0);
    landmarks[12] = const HandLandmark(0.50, 0.32, 0.0);

    landmarks[14] = const HandLandmark(0.58, 0.50, 0.0);
    landmarks[16] = const HandLandmark(0.58, 0.36, 0.0);

    landmarks[18] = const HandLandmark(0.66, 0.54, 0.0);
    landmarks[20] = const HandLandmark(0.66, 0.42, 0.0);
  } else {
    // Curled fist (tips tucked close to wrist/palm)
    landmarks[6] = const HandLandmark(0.42, 0.58, 0.0);
    landmarks[8] = const HandLandmark(0.43, 0.72, 0.0);

    landmarks[10] = const HandLandmark(0.50, 0.57, 0.0);
    landmarks[12] = const HandLandmark(0.50, 0.72, 0.0);

    landmarks[14] = const HandLandmark(0.58, 0.58, 0.0);
    landmarks[16] = const HandLandmark(0.57, 0.72, 0.0);

    landmarks[18] = const HandLandmark(0.65, 0.60, 0.0);
    landmarks[20] = const HandLandmark(0.63, 0.73, 0.0);
  }

  return landmarks;
}

void main() {
  group('AirGestureClassifier', () {
    test('detects open palm and closed fist with high/low openness', () {
      final classifier = AirGestureClassifier(confirmFrames: 3, cooldownMs: 1200);
      final openHand = _buildSyntheticHand(open: true);
      final fistHand = _buildSyntheticHand(open: false);

      late AirGestureFrame frame;
      for (int i = 0; i < 3; i++) {
        frame = classifier.classify(
          detected: true,
          landmarks: openHand,
          timestampMs: 100 + i * 40,
        );
      }
      expect(frame.detected, isTrue);
      expect(frame.posture, HandPosture.open);
      expect(frame.openness, greaterThan(0.7));
      expect(frame.triggeredAction, isNull);

      for (int i = 0; i < 3; i++) {
        frame = classifier.classify(
          detected: true,
          landmarks: fistHand,
          timestampMs: 300 + i * 40,
        );
      }
      expect(frame.posture, HandPosture.fist);
      expect(frame.openness, lessThan(0.25));
    });

    test('rejects single noisy frame without triggering transition', () {
      final classifier = AirGestureClassifier(confirmFrames: 3, cooldownMs: 1200);
      final openHand = _buildSyntheticHand(open: true);
      final fistHand = _buildSyntheticHand(open: false);

      for (int i = 0; i < 3; i++) {
        classifier.classify(
          detected: true,
          landmarks: openHand,
          timestampMs: i * 40,
        );
      }
      expect(classifier.confirmedPosture, HandPosture.open);

      // Single noisy fist frame should not trigger grab
      final noisy = classifier.classify(
        detected: true,
        landmarks: fistHand,
        timestampMs: 200,
      );
      expect(noisy.triggeredAction, isNull);
      expect(classifier.confirmedPosture, HandPosture.open);

      // Next open frame resets pending fist counter
      final recovered = classifier.classify(
        detected: true,
        landmarks: openHand,
        timestampMs: 240,
      );
      expect(recovered.triggeredAction, isNull);
      expect(classifier.confirmedPosture, HandPosture.open);
    });

    test('triggers grab on open -> fist and release on fist -> open', () {
      final classifier = AirGestureClassifier(confirmFrames: 3, cooldownMs: 1200);
      final openHand = _buildSyntheticHand(open: true);
      final fistHand = _buildSyntheticHand(open: false);

      // Confirm open
      for (int i = 0; i < 3; i++) {
        classifier.classify(
          detected: true,
          landmarks: openHand,
          timestampMs: 1000 + i * 40,
        );
      }

      // Transition to fist -> grab on 3rd frame
      AirGestureFrame? grabFrame;
      for (int i = 0; i < 3; i++) {
        grabFrame = classifier.classify(
          detected: true,
          landmarks: fistHand,
          timestampMs: 1200 + i * 40,
        );
      }
      expect(grabFrame?.triggeredAction, AirGestureAction.grab);

      // Wait past cooldown (1200ms) and open hand -> release
      AirGestureFrame? releaseFrame;
      for (int i = 0; i < 3; i++) {
        releaseFrame = classifier.classify(
          detected: true,
          landmarks: openHand,
          timestampMs: 2600 + i * 40,
        );
      }
      expect(releaseFrame?.triggeredAction, AirGestureAction.release);
    });

    test('cooldown suppresses duplicate triggers within 1200ms', () {
      final classifier = AirGestureClassifier(confirmFrames: 3, cooldownMs: 1200);
      final openHand = _buildSyntheticHand(open: true);
      final fistHand = _buildSyntheticHand(open: false);

      for (int i = 0; i < 3; i++) {
        classifier.classify(
          detected: true,
          landmarks: openHand,
          timestampMs: 1000 + i * 40,
        );
      }

      // Grab at t = 1280
      AirGestureFrame? grabFrame;
      for (int i = 0; i < 3; i++) {
        grabFrame = classifier.classify(
          detected: true,
          landmarks: fistHand,
          timestampMs: 1200 + i * 40,
        );
      }
      expect(grabFrame?.triggeredAction, AirGestureAction.grab);

      // Open within cooldown at t = 1600 -> suppressed
      AirGestureFrame? suppressedRelease;
      for (int i = 0; i < 3; i++) {
        suppressedRelease = classifier.classify(
          detected: true,
          landmarks: openHand,
          timestampMs: 1520 + i * 40,
        );
      }
      expect(suppressedRelease?.triggeredAction, isNull);
    });
  });

  group('AirGrabSession', () {
    test('serializes to/from JSON and tracks expiry accurately', () {
      final sender = NearbyDevice(
        id: 'dev_01',
        name: 'Pixel 9',
        ip: '192.168.1.50',
        port: 53318,
        deviceType: 'android',
      );
      final expiresAt = DateTime.now().add(const Duration(seconds: 20));
      final session = AirGrabSession(
        token: 'tok_abc123',
        sender: sender,
        fileCount: 3,
        previewName: 'photo.jpg +2',
        totalBytes: 4096000,
        expiresAt: expiresAt,
      );

      expect(session.isExpired, isFalse);

      final json = session.toJson();
      final restored = AirGrabSession.fromJson(json);

      expect(restored.token, 'tok_abc123');
      expect(restored.sender.id, 'dev_01');
      expect(restored.sender.name, 'Pixel 9');
      expect(restored.sender.ip, '192.168.1.50');
      expect(restored.fileCount, 3);
      expect(restored.previewName, 'photo.jpg +2');
      expect(restored.totalBytes, 4096000);
      expect(
        restored.expiresAt.millisecondsSinceEpoch,
        expiresAt.millisecondsSinceEpoch,
      );

      final expired = session.copyWith(
        expiresAt: DateTime.now().subtract(const Duration(seconds: 1)),
      );
      expect(expired.isExpired, isTrue);
      expect(expired.remainingDuration, Duration.zero);
    });
  });

  group('HTTP Air Handshake', () {
    test('delivers Air Grab and Air Claim over TCP HTTP endpoints', () async {
      HttpOverrides.global = null;

      final senderServer = HttpTransferServer();
      final receiverServer = HttpTransferServer();
      final client = HttpTransferClient();

      addTearDown(() async {
        await senderServer.stopServer();
        await receiverServer.stopServer();
      });

      final senderStub = NearbyDevice(
        id: 'sender-1',
        name: 'Phone A',
        ip: '127.0.0.1',
        port: 0,
        deviceType: 'android',
      );
      final receiverStub = NearbyDevice(
        id: 'receiver-2',
        name: 'Phone B',
        ip: '127.0.0.1',
        port: 0,
        deviceType: 'android',
      );

      final senderPort =
          await senderServer.startServer(localDevice: senderStub, port: 0);
      final receiverPort =
          await receiverServer.startServer(localDevice: receiverStub, port: 0);

      expect(senderPort, isNotNull);
      expect(receiverPort, isNotNull);

      final senderDevice = senderStub.copyWith(port: senderPort!);
      final receiverDevice = receiverStub.copyWith(port: receiverPort!);

      final grabCompleter = Completer<AirGrabSession>();
      receiverServer.onAirGrabReceived = (session) {
        if (!grabCompleter.isCompleted) grabCompleter.complete(session);
      };

      final claimCompleter = Completer<(String, NearbyDevice)>();
      senderServer.onAirClaimReceived = (token, claimer) {
        if (!claimCompleter.isCompleted) {
          claimCompleter.complete((token, claimer));
        }
      };

      final outgoingSession = AirGrabSession(
        token: 'tok_tcp_99',
        sender: senderDevice,
        fileCount: 2,
        previewName: 'clip.mp4 +1',
        totalBytes: 2048000,
        expiresAt: DateTime.now().add(const Duration(seconds: 30)),
      );

      final grabSent = await client.postAirGrab(receiverDevice, outgoingSession);
      expect(grabSent, isTrue);

      final receivedSession =
          await grabCompleter.future.timeout(const Duration(seconds: 3));
      expect(receivedSession.token, 'tok_tcp_99');
      expect(receivedSession.sender.id, 'sender-1');
      expect(receivedSession.sender.port, senderPort);

      final claimSent =
          await client.postAirClaim(receivedSession, receiverDevice);
      expect(claimSent, isTrue);

      final (claimedToken, claimer) =
          await claimCompleter.future.timeout(const Duration(seconds: 3));
      expect(claimedToken, 'tok_tcp_99');
      expect(claimer.id, 'receiver-2');
      expect(claimer.port, receiverPort);
    });

    test('fetches active Air Grab over GET /api/v1/air/active', () async {
      HttpOverrides.global = null;

      final senderServer = HttpTransferServer();
      final client = HttpTransferClient();

      addTearDown(() async {
        await senderServer.stopServer();
      });

      final senderStub = NearbyDevice(
        id: 'sender-active',
        name: 'Phone S',
        ip: '127.0.0.1',
        port: 0,
        deviceType: 'android',
      );
      final senderPort =
          await senderServer.startServer(localDevice: senderStub, port: 0);
      expect(senderPort, isNotNull);

      AirGrabSession? staged;
      senderServer.onAirActiveRequested = () => staged;

      // No active session yet -> returns null (204 No Content)
      final emptyResult = await client.fetchActiveAirGrab('127.0.0.1', senderPort!);
      expect(emptyResult, isNull);

      // Active staged session -> returns normalized session
      staged = AirGrabSession(
        token: 'tok_direct_77',
        sender: senderStub.copyWith(ip: '0.0.0.0', port: senderPort),
        fileCount: 1,
        previewName: 'deck.pdf',
        totalBytes: 512000,
        expiresAt: DateTime.now().add(const Duration(seconds: 30)),
      );

      final fetched = await client.fetchActiveAirGrab('127.0.0.1', senderPort);
      expect(fetched, isNotNull);
      expect(fetched!.token, 'tok_direct_77');
      expect(fetched.previewName, 'deck.pdf');
      expect(fetched.sender.ip, '127.0.0.1');
      expect(fetched.sender.port, senderPort);
    });
  });
}
