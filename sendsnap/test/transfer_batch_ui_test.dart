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

  @override
  Future<bool> sendFilesStream({
    required NearbyDevice target,
    required List<FileTransfer> transfers,
    required List<File> files,
  }) async {
    lastTarget = target;
    lastTransfers = List.from(transfers);
    lastFiles = List.from(files);
    return true;
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
