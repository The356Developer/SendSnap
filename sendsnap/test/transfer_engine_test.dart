import 'dart:async';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sendsnap/models/device.dart';
import 'package:sendsnap/models/transfer.dart';
import 'package:sendsnap/services/http_transfer_server.dart';
import 'package:sendsnap/services/http_transfer_client.dart';
import 'package:sendsnap/services/network_info_service.dart';

void main() {
  HttpOverrides.global = null;

  test('End-to-End HTTP Transfer Engine Test', () async {
    final server = HttpTransferServer();
    final client = HttpTransferClient();

    final localDevice = NearbyDevice(
      id: 'test-receiver-id',
      name: 'Receiver Phone',
      ip: '127.0.0.1',
      port: 0,
      deviceType: NetworkInfoService.getPlatformName(),
    );

    // 1. Start Server on ephemeral port
    final boundPort = await server.startServer(localDevice: localDevice, port: 0);
    expect(boundPort, isNotNull);
    expect(boundPort! > 0, isTrue);

    final receiverDevice = localDevice.copyWith(port: boundPort);

    // 2. Client ping
    final pingResult = await client.ping('127.0.0.1', boundPort);
    expect(pingResult, isNotNull);
    expect(pingResult!.name, 'Receiver Phone');

    // 3. Create dummy file to send
    final tempDir = Directory.systemTemp.createTempSync('sendsnap_test_');
    final dummyFile = File('${tempDir.path}/hello.txt');
    final fileContent = 'Hello, SendSnap High Speed Architecture!' * 100;
    await dummyFile.writeAsString(fileContent);

    final fileTransfer = FileTransfer(
      id: 'transfer-1',
      fileName: 'hello.txt',
      fileSize: await dummyFile.length(),
    );

    bool requestReceived = false;
    server.onRequestReceived = ({required sessionId, required sender, required files}) async {
      requestReceived = true;
      expect(files.first.fileName, 'hello.txt');
      return true;
    };

    int lastProgress = 0;
    double lastSpeed = 0.0;
    server.onProgress = ({required sessionId, required fileId, required bytesReceived, required totalBytes, required speed}) {
      lastProgress = bytesReceived;
      lastSpeed = speed;
    };

    String? completedSavedPath;
    server.onFileCompleted = ({required sessionId, required fileId, required savedPath}) {
      completedSavedPath = savedPath;
    };

    // 4. Client prepares transfer
    final senderDevice = NearbyDevice(
      id: 'test-sender-id',
      name: 'Sender Laptop',
      ip: '127.0.0.1',
      port: 53319,
    );

    final prepared = await client.prepareTransfer(
      target: receiverDevice,
      sender: senderDevice,
      sessionId: 'sess-001',
      files: [fileTransfer],
    );
    expect(prepared, isTrue);
    expect(requestReceived, isTrue);

    // 5. Client uploads file stream
    final uploadSuccess = await client.uploadFile(
      target: receiverDevice,
      sessionId: 'sess-001',
      fileTransfer: fileTransfer,
      file: dummyFile,
      onProgress: (sent, total, speed) {},
    );

    expect(uploadSuccess, isTrue);
    expect(lastProgress, dummyFile.lengthSync());
    expect(lastSpeed >= 0.0, isTrue);
    expect(completedSavedPath, isNotNull);

    // 6. Verify file content on disk
    final receivedFile = File(completedSavedPath!);
    expect(await receivedFile.exists(), isTrue);
    expect(await receivedFile.readAsString(), fileContent);

    // Clean up
    await server.stopServer();
    try {
      await receivedFile.delete();
      await dummyFile.delete();
      await tempDir.delete();
    } catch (_) {}
  });

  test('Per-file cancel via /api/v1/cancel cancels only target file in session', () async {
    final server = HttpTransferServer();
    final client = HttpTransferClient();

    final localDevice = NearbyDevice(
      id: 'rx-cancel-1',
      name: 'Receiver',
      ip: '127.0.0.1',
      port: 0,
      deviceType: NetworkInfoService.getPlatformName(),
    );

    final boundPort = await server.startServer(localDevice: localDevice, port: 0);
    expect(boundPort, isNotNull);
    final receiverDevice = localDevice.copyWith(port: boundPort!);

    final tempDir = Directory.systemTemp.createTempSync('sendsnap_cancel_test_');
    final file1 = File('${tempDir.path}/one.bin')
      ..writeAsBytesSync(List<int>.generate(256 * 1024, (i) => i % 251));
    final file2 = File('${tempDir.path}/two.txt')
      ..writeAsStringSync('Second file should still complete cleanly!');

    final transfer1 = FileTransfer(
      id: 'file-1',
      fileName: 'one.bin',
      fileSize: file1.lengthSync(),
    );
    final transfer2 = FileTransfer(
      id: 'file-2',
      fileName: 'two.txt',
      fileSize: file2.lengthSync(),
    );

    final cancelledIds = <String>[];
    final failedIds = <String>[];
    String? file2SavedPath;

    server.onRequestReceived = ({required sessionId, required sender, required files}) async => true;
    server.onFileCancelled = ({required sessionId, required fileId}) {
      cancelledIds.add(fileId);
    };
    server.onFileFailed = ({required sessionId, required fileId, required error}) {
      failedIds.add(fileId);
    };
    server.onFileCompleted = ({required sessionId, required fileId, required savedPath}) {
      if (fileId == 'file-2') {
        file2SavedPath = savedPath;
      }
    };

    try {
      final senderDevice = NearbyDevice(
        id: 'tx-cancel-1',
        name: 'Sender',
        ip: '127.0.0.1',
        port: 53319,
      );

      final prepared = await client.prepareTransfer(
        target: receiverDevice,
        sender: senderDevice,
        sessionId: 'sess-cancel-1',
        files: [transfer1, transfer2],
      );
      expect(prepared, isTrue);

      // Pause file-1 after start so we can deterministically cancel it mid-session
      final pauseGate = Completer<void>();
      final cancelToken = CancelToken();
      final upload1Future = client.uploadFile(
        target: receiverDevice,
        sessionId: 'sess-cancel-1',
        fileTransfer: transfer1,
        file: file1,
        cancelToken: cancelToken,
        isPaused: () => !pauseGate.isCompleted,
        waitWhilePaused: () => pauseGate.future,
        isCancelled: () => cancelToken.isCancelled,
        onProgress: (_, _, _) {},
      );

      await Future.delayed(const Duration(milliseconds: 60));
      cancelToken.cancel('User cancelled file-1');
      await client.cancelTransfer(
        target: receiverDevice,
        sessionId: 'sess-cancel-1',
        fileId: 'file-1',
      );
      if (!pauseGate.isCompleted) pauseGate.complete();

      final upload1Ok = await upload1Future;
      expect(upload1Ok, isFalse);
      expect(cancelledIds, contains('file-1'));
      expect(failedIds, isEmpty);

      // Remaining file in the same session still uploads and completes
      final upload2Ok = await client.uploadFile(
        target: receiverDevice,
        sessionId: 'sess-cancel-1',
        fileTransfer: transfer2,
        file: file2,
        onProgress: (_, _, _) {},
      );
      expect(upload2Ok, isTrue);
      expect(file2SavedPath, isNotNull);
      expect(
        File(file2SavedPath!).readAsStringSync(),
        'Second file should still complete cleanly!',
      );
    } finally {
      await server.stopServer();
      try {
        if (file2SavedPath != null && File(file2SavedPath!).existsSync()) {
          await File(file2SavedPath!).delete();
        }
        if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
      } catch (_) {}
    }
  });

  test('Pause and resume upload preserves full byte-for-byte integrity', () async {
    final server = HttpTransferServer();
    final client = HttpTransferClient();

    final localDevice = NearbyDevice(
      id: 'rx-pause-1',
      name: 'Receiver',
      ip: '127.0.0.1',
      port: 0,
      deviceType: NetworkInfoService.getPlatformName(),
    );

    final boundPort = await server.startServer(localDevice: localDevice, port: 0);
    expect(boundPort, isNotNull);
    final receiverDevice = localDevice.copyWith(port: boundPort!);

    final tempDir = Directory.systemTemp.createTempSync('sendsnap_pause_test_');
    final sourceBytes = List<int>.generate(256 * 1024, (i) => (i * 7) % 256);
    final sourceFile = File('${tempDir.path}/payload.bin')
      ..writeAsBytesSync(sourceBytes);

    final transfer = FileTransfer(
      id: 'pause-file-1',
      fileName: 'payload.bin',
      fileSize: sourceBytes.length,
    );

    String? completedSavedPath;
    server.onRequestReceived = ({required sessionId, required sender, required files}) async => true;
    server.onFileCompleted = ({required sessionId, required fileId, required savedPath}) {
      completedSavedPath = savedPath;
    };

    try {
      final senderDevice = NearbyDevice(
        id: 'tx-pause-1',
        name: 'Sender',
        ip: '127.0.0.1',
        port: 53319,
      );

      final prepared = await client.prepareTransfer(
        target: receiverDevice,
        sender: senderDevice,
        sessionId: 'sess-pause-1',
        files: [transfer],
      );
      expect(prepared, isTrue);

      bool paused = true;
      var resumeGate = Completer<void>();

      final uploadFuture = client.uploadFile(
        target: receiverDevice,
        sessionId: 'sess-pause-1',
        fileTransfer: transfer,
        file: sourceFile,
        isPaused: () => paused,
        waitWhilePaused: () => resumeGate.future,
        onProgress: (_, _, _) {},
      );

      await Future.delayed(const Duration(milliseconds: 120));
      expect(completedSavedPath, isNull);

      paused = false;
      resumeGate.complete();

      final ok = await uploadFuture;
      expect(ok, isTrue);
      expect(completedSavedPath, isNotNull);
      expect(File(completedSavedPath!).readAsBytesSync(), orderedEquals(sourceBytes));
    } finally {
      await server.stopServer();
      try {
        if (completedSavedPath != null && File(completedSavedPath!).existsSync()) {
          await File(completedSavedPath!).delete();
        }
        if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
      } catch (_) {}
    }
  });
}
