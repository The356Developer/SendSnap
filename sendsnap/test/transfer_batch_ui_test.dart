import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:sendsnap/models/device.dart';
import 'package:sendsnap/models/transfer.dart';
import 'package:sendsnap/providers/transfer_provider.dart';
import 'package:sendsnap/screens/transfer_screen.dart';
import 'package:sendsnap/services/local_storage_service.dart';
import 'package:sendsnap/services/nearby_service.dart';
import 'package:sendsnap/widgets/media_viewer_modal.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeNearbyService extends NearbyService {
  List<FileTransfer> lastTransfers = const [];
  List<File> lastFiles = const [];
  NearbyDevice? lastTarget;
  Completer<bool>? sendCompleter;
  int cancelActiveBatchCalls = 0;
  final List<String> cancelledFileIds = [];
  final List<bool> batchPausedCalls = [];
  final List<(String, bool)> filePausedCalls = [];

  @override
  Future<bool> sendFilesStream({
    required NearbyDevice target,
    required List<FileTransfer> transfers,
    required List<File> files,
  }) async {
    lastTarget = target;
    lastTransfers = List.from(transfers);
    lastFiles = List.from(files);
    if (sendCompleter != null) {
      return await sendCompleter!.future;
    }
    return true;
  }

  @override
  Future<void> cancelActiveBatch() async {
    cancelActiveBatchCalls++;
  }

  @override
  Future<void> cancelFileTransfer(String transferId) async {
    cancelledFileIds.add(transferId);
  }

  @override
  void setBatchPaused(bool paused) {
    batchPausedCalls.add(paused);
  }

  @override
  void setFilePaused(String transferId, bool paused) {
    filePausedCalls.add((transferId, paused));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({'sendsnap_has_rated_app': true});
  });

  group('TransferProvider batch & direction tracking', () {
    test(
      'handleIncomingBatch fires onTransferStarted once, preserves order, tracks batchProgress, fires onTransferCompleted once, and closeSession clears',
      () {
        final provider = TransferProvider();
        int startedCount = 0;
        int completedCount = 0;
        provider.onTransferStarted = () => startedCount++;
        provider.onTransferCompleted = () => completedCount++;

        final sender = NearbyDevice(
          id: 'sender-1',
          name: 'Pixel 8',
          ip: '192.168.1.50',
          port: 53318,
        );

        final incomingFiles = List.generate(
          5,
          (i) => FileTransfer(
            id: 'in-$i',
            fileName: 'photo_${i + 1}.jpg',
            fileSize: 1000,
          ),
        );

        provider.handleIncomingBatch(
          sender,
          incomingFiles,
          sessionId: 'sess-1',
        );

        expect(startedCount, 1);
        expect(completedCount, 0);
        expect(provider.sessionIsIncoming, isTrue);
        expect(provider.peerName, 'Pixel 8');
        expect(
          provider.currentBatchTransfers.map((t) => t.id).toList(),
          ['in-0', 'in-1', 'in-2', 'in-3', 'in-4'],
        );
        expect(provider.hasActiveBatch, isTrue);
        expect(provider.isBatchComplete, isFalse);
        expect(provider.batchProgress, 0.0);

        for (int i = 0; i < 4; i++) {
          provider.updateTransferProgress(
            transferId: 'in-$i',
            bytesTransferred: 500,
            totalBytes: 1000,
            speed: 2048.0,
          );
          provider.markTransferCompleted(
            transferId: 'in-$i',
            savedPath: '/tmp/photo_${i + 1}.jpg',
          );
          expect(provider.isBatchComplete, isFalse);
          expect(completedCount, 0);
        }

        expect(provider.completedBatchCount, 4);
        expect(provider.batchProgress, closeTo(0.8, 0.001));

        provider.markTransferCompleted(
          transferId: 'in-4',
          savedPath: '/tmp/photo_5.jpg',
        );

        expect(provider.isBatchComplete, isTrue);
        expect(provider.hasActiveBatch, isFalse);
        expect(provider.completedBatchCount, 5);
        expect(provider.batchProgress, 1.0);
        expect(completedCount, 1);
        expect(provider.currentBatchTransfers.first.localPath, '/tmp/photo_1.jpg');

        provider.closeSession();
        expect(provider.currentBatchTransfers, isEmpty);
        expect(provider.activeTransfer, isNull);
        expect(provider.peerName, isNull);
      },
    );

    test(
      'outgoing sendFiles keeps isIncoming == false, savedPath == null, and localPath == filePath',
      () async {
        final tempDir = Directory.systemTemp.createTempSync('sendsnap_batch_test_');
        addTearDown(() {
          if (tempDir.existsSync()) {
            tempDir.deleteSync(recursive: true);
          }
        });

        final fileA = File('${tempDir.path}${Platform.pathSeparator}a.txt')
          ..writeAsStringSync('alpha');
        final fileB = File('${tempDir.path}${Platform.pathSeparator}b.txt')
          ..writeAsStringSync('beta!!');

        final provider = TransferProvider();
        final fakeService = _FakeNearbyService();
        final target = NearbyDevice(
          id: 'recv-1',
          name: 'Windows PC',
          ip: '192.168.1.99',
          port: 53318,
        );

        final ok = await provider.sendFiles(target, [fileA, fileB], fakeService);
        expect(ok, isTrue);
        expect(provider.sessionIsIncoming, isFalse);
        expect(provider.peerName, 'Windows PC');
        expect(provider.currentBatchTransfers.length, 2);

        for (final t in fakeService.lastTransfers) {
          provider.markTransferCompleted(
            transferId: t.id,
            savedPath: t.filePath!,
          );
        }

        expect(provider.isBatchComplete, isTrue);
        final batch = provider.currentBatchTransfers;
        expect(batch[0].isIncoming, isFalse);
        expect(batch[0].savedPath, isNull);
        expect(batch[0].filePath, fileA.path);
        expect(batch[0].localPath, fileA.path);

        expect(batch[1].isIncoming, isFalse);
        expect(batch[1].savedPath, isNull);
        expect(batch[1].filePath, fileB.path);
        expect(batch[1].localPath, fileB.path);
      },
    );

    test(
      'cancelFile, cancelAll, togglePauseFile, and togglePauseAll update state and delegate to NearbyService',
      () async {
        final tempDir = Directory.systemTemp.createTempSync('sendsnap_ctrl_test_');
        addTearDown(() {
          if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
        });

        final file1 = File('${tempDir.path}${Platform.pathSeparator}f1.txt')
          ..writeAsStringSync('1111');
        final file2 = File('${tempDir.path}${Platform.pathSeparator}f2.txt')
          ..writeAsStringSync('2222');
        final file3 = File('${tempDir.path}${Platform.pathSeparator}f3.txt')
          ..writeAsStringSync('3333');

        final provider = TransferProvider();
        final completer = Completer<bool>();
        final fakeService = _FakeNearbyService()..sendCompleter = completer;
        final target = NearbyDevice(
          id: 'recv-ctrl',
          name: 'Phone',
          ip: '192.168.1.77',
          port: 53318,
        );

        final sendFuture = provider.sendFiles(
          target,
          [file1, file2, file3],
          fakeService,
        );
        while (provider.currentBatchTransfers.length < 3) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }

        final ids = provider.currentBatchTransfers.map((t) => t.id).toList();
        expect(ids.length, 3);
        expect(provider.isBatchPaused, isFalse);
        expect(provider.cancelledBatchCount, 0);

        // Toggle per-file pause on file 2
        provider.togglePauseFile(ids[1]);
        expect(provider.currentBatchTransfers[1].status, TransferStatus.paused);
        expect(provider.isBatchPaused, isFalse);
        expect(fakeService.filePausedCalls, [(ids[1], true)]);

        // Resume file 2
        provider.togglePauseFile(ids[1]);
        expect(provider.currentBatchTransfers[1].status, TransferStatus.pending);
        expect(fakeService.filePausedCalls, [(ids[1], true), (ids[1], false)]);

        // Cancel specific file (file 2)
        await provider.cancelFile(ids[1]);
        expect(provider.currentBatchTransfers[1].status, TransferStatus.cancelled);
        expect(provider.cancelledBatchCount, 1);
        expect(provider.hasActiveBatch, isTrue);
        expect(fakeService.cancelledFileIds, [ids[1]]);

        // Pause all remaining active files
        provider.togglePauseAll();
        expect(provider.isBatchPaused, isTrue);
        expect(provider.currentBatchTransfers[0].status, TransferStatus.paused);
        expect(provider.currentBatchTransfers[1].status, TransferStatus.cancelled);
        expect(provider.currentBatchTransfers[2].status, TransferStatus.paused);
        expect(fakeService.batchPausedCalls, [true]);

        // Resume all remaining active files
        provider.togglePauseAll();
        expect(provider.isBatchPaused, isFalse);
        expect(provider.currentBatchTransfers[0].status, TransferStatus.pending);
        expect(provider.currentBatchTransfers[2].status, TransferStatus.pending);
        expect(fakeService.batchPausedCalls, [true, false]);

        // Cancel all remaining
        await provider.cancelAll();
        expect(provider.cancelledBatchCount, 3);
        expect(provider.isBatchComplete, isTrue);
        expect(provider.hasActiveBatch, isFalse);
        expect(fakeService.cancelActiveBatchCalls, 1);

        completer.complete(false);
        await sendFuture;
      },
    );
  });

  group('TransferScreen responsive multi-file UI', () {
    Future<TransferProvider> buildCompletedBatchProvider({
      required bool incoming,
      int count = 4,
    }) async {
      final provider = TransferProvider();
      if (incoming) {
        final sender = NearbyDevice(
          id: 'peer-1',
          name: 'Pixel 8',
          ip: '192.168.1.40',
          port: 53318,
        );
        final files = List.generate(
          count,
          (i) => FileTransfer(
            id: 'f-$i',
            fileName: 'document_${i + 1}.pdf',
            fileSize: 1024 * (i + 1),
          ),
        );
        provider.handleIncomingBatch(sender, files, sessionId: 's1');
        for (int i = 0; i < count; i++) {
          provider.markTransferCompleted(
            transferId: 'f-$i',
            savedPath: '/downloads/document_${i + 1}.pdf',
          );
        }
      } else {
        final fake = _FakeNearbyService();
        final tempDir = Directory.systemTemp.createTempSync('sendsnap_ui_test_');
        final ioFiles = List.generate(count, (i) {
          final f = File(
            '${tempDir.path}${Platform.pathSeparator}report_${i + 1}.txt',
          )..writeAsStringSync('Report content $i');
          return f;
        });
        final target = NearbyDevice(
          id: 'peer-2',
          name: 'Desktop PC',
          ip: '192.168.1.41',
          port: 53318,
        );
        await provider.sendFiles(target, ioFiles, fake);
        for (final t in fake.lastTransfers) {
          provider.markTransferCompleted(
            transferId: t.id,
            savedPath: t.filePath!,
          );
        }
        tempDir.deleteSync(recursive: true);
      }
      return provider;
    }

    testWidgets(
      'Desktop 1000x680 renders 4 files, zero overflow, and CLOSE ALL & MAIN MENU returns to /home in one tap',
      (tester) async {
        tester.view.physicalSize = const Size(1000, 680);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final provider = (await tester.runAsync(
          () => buildCompletedBatchProvider(incoming: false, count: 4),
        ))!;
        bool returnedHome = false;

        await tester.pumpWidget(
          ChangeNotifierProvider<TransferProvider>.value(
            value: provider,
            child: MaterialApp(
              initialRoute: '/home',
              routes: {
                '/home': (ctx) => Scaffold(
                      body: Center(
                        child: ElevatedButton(
                          onPressed: () =>
                              Navigator.of(ctx).pushNamed('/transfer'),
                          child: const Text('HOME_ROUTE_SENTINEL'),
                        ),
                      ),
                    ),
                '/transfer': (_) => TransferScreen(
                      onReturnHome: () => returnedHome = true,
                    ),
              },
            ),
          ),
        );

        await tester.tap(find.text('HOME_ROUTE_SENTINEL'));
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);
        expect(find.text('Files (4)'), findsOneWidget);
        expect(find.text('report_1.txt'), findsOneWidget);
        expect(find.text('report_2.txt'), findsOneWidget);
        expect(find.text('report_3.txt'), findsOneWidget);
        expect(find.text('report_4.txt'), findsOneWidget);
        expect(find.text('CLOSE ALL & MAIN MENU'), findsOneWidget);

        await tester.tap(find.text('CLOSE ALL & MAIN MENU'));
        await tester.pumpAndSettle();

        expect(returnedHome, isTrue);
        expect(provider.currentBatchTransfers, isEmpty);
        expect(find.text('HOME_ROUTE_SENTINEL'), findsOneWidget);
        expect(find.text('CLOSE ALL & MAIN MENU'), findsNothing);
      },
    );

    testWidgets(
      'Desktop minimum window 720x520 renders 4 files without RenderFlex overflow',
      (tester) async {
        tester.view.physicalSize = const Size(720, 520);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final provider = await buildCompletedBatchProvider(
          incoming: true,
          count: 4,
        );

        await tester.pumpWidget(
          ChangeNotifierProvider<TransferProvider>.value(
            value: provider,
            child: MaterialApp(
              home: TransferScreen(onReturnHome: () {}),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);
        expect(find.text('Files (4)'), findsOneWidget);
        expect(find.text('document_1.pdf'), findsOneWidget);
        expect(find.text('document_4.pdf'), findsOneWidget);
        expect(find.text('CLOSE ALL & MAIN MENU'), findsOneWidget);
      },
    );

    testWidgets(
      'Mobile 390x844 renders 4 files cleanly without overflow',
      (tester) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final provider = await buildCompletedBatchProvider(
          incoming: true,
          count: 4,
        );

        await tester.pumpWidget(
          ChangeNotifierProvider<TransferProvider>.value(
            value: provider,
            child: MaterialApp(
              home: TransferScreen(onReturnHome: () {}),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);
        expect(find.text('Files (4)'), findsOneWidget);
        expect(find.text('document_1.pdf'), findsOneWidget);
        expect(find.text('document_2.pdf'), findsOneWidget);
        expect(find.text('document_3.pdf'), findsOneWidget);
        expect(find.text('document_4.pdf'), findsOneWidget);
        expect(find.text('CLOSE ALL & MAIN MENU'), findsOneWidget);
      },
    );

    Future<TransferProvider> buildActiveOutgoingProvider(
      _FakeNearbyService fake,
    ) async {
      final provider = TransferProvider();
      final tempDir = Directory.systemTemp.createTempSync('sendsnap_active_ui_');
      final ioFiles = List.generate(3, (i) {
        return File(
          '${tempDir.path}${Platform.pathSeparator}video_${i + 1}.mp4',
        )..writeAsStringSync('Video payload $i');
      });
      final target = NearbyDevice(
        id: 'peer-active',
        name: 'Galaxy S24',
        ip: '192.168.1.60',
        port: 53318,
      );
      unawaited(provider.sendFiles(target, ioFiles, fake));
      while (provider.currentBatchTransfers.length < 3) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      tempDir.deleteSync(recursive: true);
      return provider;
    }

    testWidgets(
      'Active outgoing batch shows PAUSE, CANCEL ALL, per-file pause/cancel buttons cleanly at Mobile 390x844 and Desktop 1000x680',
      (tester) async {
        for (final size in [const Size(390, 844), const Size(1000, 680)]) {
          tester.view.physicalSize = size;
          tester.view.devicePixelRatio = 1.0;

          final completer = Completer<bool>();
          final fake = _FakeNearbyService()..sendCompleter = completer;
          final provider = (await tester.runAsync(
            () => buildActiveOutgoingProvider(fake),
          ))!;

          await tester.pumpWidget(
            ChangeNotifierProvider<TransferProvider>.value(
              value: provider,
              child: MaterialApp(
                home: TransferScreen(onReturnHome: () {}),
              ),
            ),
          );
          await tester.pump();

          expect(tester.takeException(), isNull);
          expect(find.text('PAUSE'), findsOneWidget);
          expect(find.text('CANCEL ALL'), findsOneWidget);
          expect(find.text('MINIMIZE'), findsOneWidget);
          expect(find.byTooltip('Pause file'), findsNWidgets(3));
          expect(find.byTooltip('Cancel file'), findsNWidgets(3));

          // Tap Pause All -> switches to RESUME
          await tester.tap(find.text('PAUSE'));
          await tester.pump();
          expect(tester.takeException(), isNull);
          expect(find.text('RESUME'), findsOneWidget);
          expect(find.text('Transfer Paused'), findsWidgets);

          // Tap Cancel file on first entry
          await tester.tap(find.byTooltip('Cancel file').first);
          await tester.pump();
          expect(tester.takeException(), isNull);
          expect(provider.cancelledBatchCount, 1);

          // Tap CANCEL ALL
          await tester.tap(find.text('CANCEL ALL'));
          await tester.pump();
          expect(tester.takeException(), isNull);
          expect(provider.isBatchComplete, isTrue);
          expect(find.text('Transfer Cancelled'), findsOneWidget);

          completer.complete(false);
        }
        addTearDown(tester.view.reset);
      },
    );
  });

  group('MediaViewerModal multi-item gallery browsing', () {
    testWidgets(
      'displays 1 / 3 counter and switches to 2 / 3 when tapping next arrow',
      (tester) async {
        tester.view.physicalSize = const Size(1000, 680);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final items = List.generate(
          3,
          (i) => LocalItem(
            path: '/tmp/note_${i + 1}.txt',
            name: 'note_${i + 1}.txt',
            size: 512 * (i + 1),
            modified: DateTime(2026, 1, 1),
            isDirectory: false,
            extension: '.txt',
          ),
        );

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: MediaViewerModal(
                item: items.first,
                items: items,
                initialIndex: 0,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);
        expect(find.text('1 / 3'), findsOneWidget);
        expect(find.text('note_1.txt'), findsWidgets);

        await tester.tap(find.byIcon(Icons.chevron_right_rounded));
        await tester.pumpAndSettle();

        expect(find.text('2 / 3'), findsOneWidget);
        expect(find.text('note_2.txt'), findsWidgets);
      },
    );
  });
}
