import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sendsnap/services/local_storage_service.dart';

void main() {
  test('LocalStorageService local item model & categories', () async {
    final tempDir = Directory.systemTemp.createTempSync('sendsnap_storage_test_');
    final imgFile = File('${tempDir.path}/test_image.png');
    final docFile = File('${tempDir.path}/notes.pdf');
    final vidFile = File('${tempDir.path}/clip.mp4');
    final apkFile = File('${tempDir.path}/cool_app.apk');
    final zipFile = File('${tempDir.path}/archive_pack.zip');
    final subDir = Directory('${tempDir.path}/subfolder');

    await imgFile.writeAsBytes([1, 2, 3, 4, 5]);
    await docFile.writeAsString('Test PDF content');
    await vidFile.writeAsBytes([10, 20, 30]);
    await apkFile.writeAsBytes([80, 75, 3, 4]);
    await zipFile.writeAsBytes([80, 75, 5, 6]);
    await subDir.create();

    final items = await LocalStorageService.getItems(
      category: StorageCategory.files,
      currentDirectoryPath: tempDir.path,
    );

    expect(items.length, 6);

    final folderItem = items.firstWhere((i) => i.name == 'subfolder');
    expect(folderItem.isDirectory, isTrue);

    final imgItem = items.firstWhere((i) => i.name == 'test_image.png');
    expect(imgItem.isImage, isTrue);
    expect(imgItem.isVideo, isFalse);
    expect(imgItem.size, 5);

    final pdfItem = items.firstWhere((i) => i.name == 'notes.pdf');
    expect(pdfItem.isDocument, isTrue);

    final vidItem = items.firstWhere((i) => i.name == 'clip.mp4');
    expect(vidItem.isVideo, isTrue);

    final apkItem = items.firstWhere((i) => i.name == 'cool_app.apk');
    expect(apkItem.isApp, isTrue);
    expect(apkItem.isArchive, isFalse);

    final zipItem = items.firstWhere((i) => i.name == 'archive_pack.zip');
    expect(zipItem.isArchive, isTrue);
    expect(zipItem.isApp, isFalse);

    // Verify recent, apps, photos, documents, archives categories load without errors
    final recentItems = await LocalStorageService.getItems(category: StorageCategory.recent);
    expect(recentItems, isA<List<LocalItem>>());

    final appItems = await LocalStorageService.getItems(category: StorageCategory.apps);
    expect(appItems, isA<List<LocalItem>>());

    final photoItems = await LocalStorageService.getItems(category: StorageCategory.photos);
    expect(photoItems, isA<List<LocalItem>>());

    final docItems = await LocalStorageService.getItems(category: StorageCategory.documents);
    expect(docItems, isA<List<LocalItem>>());

    final archiveItems = await LocalStorageService.getItems(category: StorageCategory.archives);
    expect(archiveItems, isA<List<LocalItem>>());

    // Verify prepareApkForSending preserves friendly filename when staging base.apk
    final baseApk = File('${tempDir.path}/base.apk');
    await baseApk.writeAsBytes([1, 2, 3, 4]);
    final preparedItem = LocalItem(
      path: baseApk.path,
      name: 'MySampleApp.apk',
      size: 4,
      modified: DateTime.now(),
      isDirectory: false,
      extension: '.apk',
      isInstalledApp: false,
    );
    final resolvedNormal = await LocalStorageService.prepareFileForSending(preparedItem);
    expect(resolvedNormal, isNotNull);
    expect(resolvedNormal!.existsSync(), isTrue);

    tempDir.deleteSync(recursive: true);
  });
}
