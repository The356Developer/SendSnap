import 'dart:io';
import 'dart:isolate';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart' as path_provider;
import 'file_handler.dart';

enum StorageCategory {
  recent,
  apps,
  files,
  downloads,
  photos,
  videos,
  audio,
  documents,
  archives,
  received,
}

class LocalItem {
  final String path;
  final String name;
  final int size;
  final DateTime modified;
  final bool isDirectory;
  final String extension;
  final String? packageName;
  final bool isInstalledApp;

  LocalItem({
    required this.path,
    required this.name,
    required this.size,
    required this.modified,
    required this.isDirectory,
    required this.extension,
    this.packageName,
    this.isInstalledApp = false,
  });

  String get formattedSize => isDirectory ? '' : FileHandler.formatFileSize(size);

  bool get isImage => const ['.jpg', '.jpeg', '.png', '.gif', '.webp', '.heic', '.bmp', '.svg']
      .contains(extension.toLowerCase());

  bool get isVideo => const ['.mp4', '.mkv', '.mov', '.avi', '.3gp', '.webm', '.flv']
      .contains(extension.toLowerCase());

  bool get isAudio => const ['.mp3', '.m4a', '.wav', '.flac', '.aac', '.ogg', '.opus', '.wma']
      .contains(extension.toLowerCase());

  bool get isApp =>
      isInstalledApp ||
      const ['.apk', '.xapk', '.apkm', '.aab'].contains(extension.toLowerCase());

  bool get isArchive => const [
        '.zip', '.rar', '.7z', '.tar', '.gz', '.bz2', '.xz',
        '.iso', '.exe', '.msi', '.dmg', '.deb', '.rpm', '.bin'
      ].contains(extension.toLowerCase());

  bool get isDocument => const [
        '.pdf', '.doc', '.docx', '.xls', '.xlsx', '.ppt', '.pptx', '.txt',
        '.csv', '.rtf', '.md', '.json', '.xml', '.yaml', '.yml', '.html',
        '.epub', '.mobi', '.odt', '.ods', '.odp', '.dwg', '.dxf', '.stl',
        '.obj', '.step', '.stp', '.sldprt', '.sldasm', '.blend', '.psd', '.ai',
        '.py', '.dart', '.js', '.ts', '.java', '.kt', '.cpp', '.c', '.sql',
        '.zip', '.rar', '.7z', '.tar', '.gz', '.apk'
      ].contains(extension.toLowerCase());
}

class LocalStorageService {
  static const List<String> _imageExts = [
    '.jpg', '.jpeg', '.png', '.gif', '.webp', '.heic', '.bmp', '.svg'
  ];
  static const List<String> _videoExts = [
    '.mp4', '.mkv', '.mov', '.avi', '.3gp', '.webm', '.flv'
  ];
  static const List<String> _audioExts = [
    '.mp3', '.m4a', '.wav', '.flac', '.aac', '.ogg', '.opus', '.wma'
  ];
  static const List<String> _docExts = [
    '.pdf', '.doc', '.docx', '.xls', '.xlsx', '.ppt', '.pptx', '.txt',
    '.csv', '.rtf', '.md', '.json', '.xml', '.yaml', '.yml', '.html',
    '.epub', '.mobi', '.odt', '.ods', '.odp', '.dwg', '.dxf', '.stl',
    '.obj', '.step', '.stp', '.sldprt', '.sldasm', '.blend', '.psd', '.ai',
    '.py', '.dart', '.js', '.ts', '.java', '.kt', '.cpp', '.c', '.sql',
    '.zip', '.rar', '.7z', '.tar', '.gz', '.apk'
  ];
  static const List<String> _apkExts = ['.apk', '.xapk', '.apkm', '.aab'];
  static const List<String> _archiveExts = [
    '.zip', '.rar', '.7z', '.tar', '.gz', '.bz2', '.xz',
    '.iso', '.apk', '.xapk', '.apkm', '.aab', '.exe', '.msi', '.dmg',
    '.deb', '.rpm', '.bin'
  ];

  static Future<String> getRootStoragePath() async {
    if (Platform.isAndroid) {
      final emulated = Directory('/storage/emulated/0');
      if (await emulated.exists()) return emulated.path;
    } else if (Platform.isWindows) {
      final user = Platform.environment['USERPROFILE'];
      if (user != null && await Directory(user).exists()) return user;
    } else if (Platform.isLinux || Platform.isMacOS) {
      final home = Platform.environment['HOME'];
      if (home != null && await Directory(home).exists()) return home;
    }
    try {
      final docDir = await path_provider.getApplicationDocumentsDirectory();
      return docDir.path;
    } catch (_) {
      return Directory.current.path;
    }
  }

  static List<String> _getPlatformFolders(String folderName, List<String> androidDefaults) {
    if (Platform.isWindows) {
      final user = Platform.environment['USERPROFILE'] ?? '';
      final oneDrive = Platform.environment['OneDrive'] ?? Platform.environment['OneDriveConsumer'] ?? '';
      final folders = <String>[
        p.join(user, folderName),
        p.join(user, 'Downloads'),
        p.join(user, 'Desktop'),
      ];
      if (oneDrive.isNotEmpty) {
        folders.add(p.join(oneDrive, folderName));
        folders.add(p.join(oneDrive, 'Desktop'));
        folders.add(p.join(oneDrive, 'Documents'));
        folders.add(p.join(oneDrive, 'Pictures'));
      }
      return folders;
    } else if (Platform.isLinux || Platform.isMacOS) {
      final home = Platform.environment['HOME'] ?? '';
      return [
        p.join(home, folderName),
        p.join(home, 'Downloads'),
        p.join(home, 'Desktop'),
      ];
    }
    return androidDefaults;
  }

  static Future<String> getDownloadsPath() async {
    if (Platform.isAndroid) {
      final dl = Directory('/storage/emulated/0/Download');
      if (await dl.exists()) return dl.path;
    }
    try {
      final dl = await path_provider.getDownloadsDirectory();
      if (dl != null) return dl.path;
    } catch (_) {}
    return await getRootStoragePath();
  }

  /// Lists items according to the selected category or path.
  static Future<List<LocalItem>> getItems({
    required StorageCategory category,
    String? currentDirectoryPath,
  }) async {
    try {
      switch (category) {
        case StorageCategory.recent:
          if (Platform.isAndroid) {
            final media = await _queryAndroidMediaStore(StorageCategory.recent);
            if (media.isNotEmpty) return media;
          }
          return await _getRecentFiles();

        case StorageCategory.files:
          final targetPath = currentDirectoryPath ?? await getRootStoragePath();
          return await _listDirectory(targetPath);

        case StorageCategory.downloads:
          final dlPath = await getDownloadsPath();
          return await _listDirectory(dlPath);

        case StorageCategory.received:
          final sendSnapDir = await FileHandler.getDownloadsDirectory();
          return await _listDirectory(sendSnapDir.path);

        case StorageCategory.photos:
          if (Platform.isAndroid) {
            final media = await _queryAndroidMediaStore(StorageCategory.photos);
            if (media.isNotEmpty) return media;
          }
          return await _scanForFiles(
            extensions: _imageExts,
            targetFolders: _getPlatformFolders('Pictures', [
              '/storage/emulated/0/DCIM/Camera',
              '/storage/emulated/0/DCIM',
              '/storage/emulated/0/Pictures',
              '/storage/emulated/0/Download',
            ]),
          );

        case StorageCategory.videos:
          if (Platform.isAndroid) {
            final media = await _queryAndroidMediaStore(StorageCategory.videos);
            if (media.isNotEmpty) return media;
          }
          return await _scanForFiles(
            extensions: _videoExts,
            targetFolders: _getPlatformFolders('Videos', [
              '/storage/emulated/0/DCIM/Camera',
              '/storage/emulated/0/DCIM',
              '/storage/emulated/0/Movies',
              '/storage/emulated/0/Download',
              '/storage/emulated/0/Pictures',
            ]),
          );

        case StorageCategory.audio:
          if (Platform.isAndroid) {
            final media = await _queryAndroidMediaStore(StorageCategory.audio);
            if (media.isNotEmpty) return media;
          }
          return await _scanForFiles(
            extensions: _audioExts,
            targetFolders: _getPlatformFolders('Music', [
              '/storage/emulated/0/Music',
              '/storage/emulated/0/Download',
              '/storage/emulated/0/Audio',
              '/storage/emulated/0/Podcasts',
            ]),
          );

        case StorageCategory.apps:
          if (Platform.isAndroid) {
            final installedApps = await _queryAndroidInstalledApps();
            final apkFiles = await _scanForFiles(
              extensions: _apkExts,
              targetFolders: [
                '/storage/emulated/0/Download',
                '/storage/emulated/0/Download/SendSnap',
              ],
            );
            final seenPaths = <String>{};
            final combined = <LocalItem>[];
            for (final item in [...apkFiles, ...installedApps]) {
              if (seenPaths.add(item.path)) {
                combined.add(item);
              }
            }
            return combined;
          }
          return await _scanForFiles(
            extensions: const ['.apk', '.xapk', '.exe', '.msi', '.zip'],
            targetFolders: _getPlatformFolders('Downloads', [
              '/storage/emulated/0/Download',
            ]),
          );

        case StorageCategory.documents:
          if (Platform.isAndroid) {
            final media = await _queryAndroidMediaStore(StorageCategory.documents);
            if (media.isNotEmpty) return media;
          }
          return await _scanForFiles(
            extensions: _docExts,
            targetFolders: _getPlatformFolders('Documents', [
              '/storage/emulated/0/Documents',
              '/storage/emulated/0/Download',
            ]),
          );

        case StorageCategory.archives:
          if (Platform.isAndroid) {
            final media = await _queryAndroidMediaStore(StorageCategory.archives);
            final scanned = await _scanForFiles(
              extensions: _archiveExts,
              targetFolders: [
                '/storage/emulated/0/Download',
                '/storage/emulated/0/Download/SendSnap',
                '/storage/emulated/0/Documents',
              ],
            );
            final seen = <String>{};
            final combined = <LocalItem>[];
            for (final item in [...media, ...scanned]) {
              if (seen.add(item.path)) combined.add(item);
            }
            combined.sort((a, b) => b.modified.compareTo(a.modified));
            return combined;
          }
          return await _scanForFiles(
            extensions: _archiveExts,
            targetFolders: _getPlatformFolders('Downloads', [
              '/storage/emulated/0/Download',
              '/storage/emulated/0/Documents',
            ]),
          );
      }
    } catch (e) {
      debugPrint('[LocalStorageService] Error loading category $category: $e');
      return [];
    }
  }

  /// Lists a specific directory in a background isolate, separating folders and files.
  static Future<List<LocalItem>> _listDirectory(String dirPath) async {
    return await Isolate.run(() {
      final dir = Directory(dirPath);
      if (!dir.existsSync()) return <LocalItem>[];

      final folders = <LocalItem>[];
      final files = <LocalItem>[];

      try {
        final entries = dir.listSync(followLinks: false);
        for (final entity in entries) {
          final name = p.basename(entity.path);
          if (name.startsWith('.')) continue;

          try {
            final stat = entity.statSync();
            final isDir = stat.type == FileSystemEntityType.directory;
            final item = LocalItem(
              path: entity.path,
              name: name,
              size: isDir ? 0 : stat.size,
              modified: stat.modified,
              isDirectory: isDir,
              extension: isDir ? '' : p.extension(entity.path).toLowerCase(),
            );

            if (isDir) {
              folders.add(item);
            } else {
              files.add(item);
            }
          } catch (_) {}
        }
      } catch (_) {}

      folders.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      files.sort((a, b) => b.modified.compareTo(a.modified));

      return [...folders, ...files];
    });
  }

  static Future<List<LocalItem>> _queryAndroidMediaStore(StorageCategory category) async {
    try {
      const channel = MethodChannel('com.the356company.sendsnap/file_utils');
      final typeStr = category == StorageCategory.videos
          ? 'videos'
          : category == StorageCategory.photos
              ? 'photos'
              : category == StorageCategory.audio
                  ? 'audio'
                  : category == StorageCategory.documents
                      ? 'documents'
                      : category == StorageCategory.archives
                          ? 'archives'
                          : 'recents';
      final rawList = await channel.invokeMethod<List<dynamic>>(
        'queryMediaFiles',
        {'type': typeStr},
      );
      if (rawList != null && rawList.isNotEmpty) {
        final items = <LocalItem>[];
        for (final entry in rawList) {
          if (entry is Map) {
            final path = entry['path']?.toString() ?? '';
            final name = entry['name']?.toString() ?? p.basename(path);
            final size = (entry['size'] as num?)?.toInt() ?? 0;
            final modMs = (entry['modified'] as num?)?.toInt() ?? 0;
            final ext = p.extension(name).isNotEmpty
                ? p.extension(name).toLowerCase()
                : p.extension(path).toLowerCase();
            items.add(LocalItem(
              path: path,
              name: name,
              size: size,
              modified: DateTime.fromMillisecondsSinceEpoch(modMs),
              isDirectory: false,
              extension: ext,
            ));
          }
        }
        return items;
      }
    } catch (e) {
      debugPrint('[LocalStorageService] MediaStore query failed: $e');
    }
    return [];
  }

  static Future<List<LocalItem>> _queryAndroidInstalledApps() async {
    try {
      const channel = MethodChannel('com.the356company.sendsnap/file_utils');
      final rawList = await channel.invokeMethod<List<dynamic>>('queryInstalledApps');
      if (rawList != null && rawList.isNotEmpty) {
        final items = <LocalItem>[];
        for (final entry in rawList) {
          if (entry is Map) {
            final path = entry['path']?.toString() ?? '';
            final name = entry['name']?.toString() ?? p.basename(path);
            final pkgName = entry['packageName']?.toString();
            final size = (entry['size'] as num?)?.toInt() ?? 0;
            final modMs = (entry['modified'] as num?)?.toInt() ?? 0;
            if (path.isEmpty) continue;
            items.add(LocalItem(
              path: path,
              name: name,
              size: size,
              modified: DateTime.fromMillisecondsSinceEpoch(modMs),
              isDirectory: false,
              extension: '.apk',
              packageName: pkgName,
              isInstalledApp: true,
            ));
          }
        }
        return items;
      }
    } catch (e) {
      debugPrint('[LocalStorageService] Installed apps query failed: $e');
    }
    return [];
  }

  /// Copies an installed APK (typically named `base.apk`) into a temporary staging
  /// directory using the friendly `<AppName>.apk` filename before sending.
  static Future<File?> prepareApkForSending(
    String sourcePath,
    String displayName,
  ) async {
    try {
      final sourceFile = File(sourcePath);
      if (!await sourceFile.exists()) return null;

      final sanitized = displayName
          .replaceAll(RegExp(r'[/\\:*?"<>|]'), '_')
          .trim();
      final finalName = sanitized.toLowerCase().endsWith('.apk')
          ? sanitized
          : '$sanitized.apk';

      if (p.basename(sourcePath).toLowerCase() == finalName.toLowerCase()) {
        return sourceFile;
      }

      final tempDir = await path_provider.getTemporaryDirectory();
      final stagingDir = Directory(p.join(tempDir.path, 'sendsnap_apks'));
      if (!await stagingDir.exists()) {
        await stagingDir.create(recursive: true);
      }
      final stagedFile = File(p.join(stagingDir.path, finalName));
      await sourceFile.copy(stagedFile.path);
      return stagedFile;
    } catch (e) {
      debugPrint('[LocalStorageService] prepareApkForSending error: $e');
      final fallback = File(sourcePath);
      return await fallback.exists() ? fallback : null;
    }
  }

  static Future<File?> prepareFileForSending(LocalItem item) async {
    if (item.isInstalledApp) {
      return prepareApkForSending(item.path, item.name);
    }
    if (item.path.startsWith('content://')) {
      final resolved = await FileHandler.resolveContentUri(item.path);
      if (resolved != null && await File(resolved).exists()) {
        return File(resolved);
      }
      return null;
    }
    final f = File(item.path);
    return await f.exists() ? f : null;
  }

  /// Scans known media/documents folders in a background isolate.
  static Future<List<LocalItem>> _scanForFiles({
    required List<String> extensions,
    required List<String> targetFolders,
  }) async {
    return await Isolate.run(() {
      final results = <LocalItem>[];
      final visitedPaths = <String>{};

      void processFile(File file) {
        if (!visitedPaths.contains(file.path)) {
          final ext = p.extension(file.path).toLowerCase();
          if (extensions.contains(ext)) {
            try {
              final stat = file.statSync();
              results.add(LocalItem(
                path: file.path,
                name: p.basename(file.path),
                size: stat.size,
                modified: stat.modified,
                isDirectory: false,
                extension: ext,
              ));
              visitedPaths.add(file.path);
            } catch (_) {}
          }
        }
      }

      for (final folderPath in targetFolders) {
        final dir = Directory(folderPath);
        if (!dir.existsSync()) continue;

        try {
          final entities = dir.listSync(recursive: false, followLinks: false);
          for (final entity in entities) {
            if (entity is File) {
              processFile(entity);
            } else if (entity is Directory && !p.basename(entity.path).startsWith('.')) {
              // 1 level of subdirectories
              try {
                final subEntities = entity.listSync(recursive: false, followLinks: false);
                for (final sub in subEntities) {
                  if (sub is File) {
                    processFile(sub);
                  }
                }
              } catch (_) {}
            }
          }
        } catch (_) {}
      }

      results.sort((a, b) => b.modified.compareTo(a.modified));
      if (results.length > 150) {
        return results.sublist(0, 150);
      }
      return results;
    });
  }

  /// Scans common storage folders for the most recent files in a background isolate.
  static Future<List<LocalItem>> _getRecentFiles() async {
    final searchFolders = <String>[];
    if (Platform.isAndroid) {
      searchFolders.addAll([
        '/storage/emulated/0/DCIM/Camera',
        '/storage/emulated/0/Download',
        '/storage/emulated/0/Pictures',
        '/storage/emulated/0/Documents',
      ]);
    } else if (Platform.isWindows) {
      final user = Platform.environment['USERPROFILE'] ?? '';
      final oneDrive = Platform.environment['OneDrive'] ?? Platform.environment['OneDriveConsumer'] ?? '';
      searchFolders.addAll([
        p.join(user, 'Downloads'),
        p.join(user, 'Desktop'),
        p.join(user, 'Documents'),
        p.join(user, 'Pictures'),
      ]);
      if (oneDrive.isNotEmpty) {
        searchFolders.addAll([
          p.join(oneDrive, 'Desktop'),
          p.join(oneDrive, 'Documents'),
          p.join(oneDrive, 'Pictures'),
        ]);
      }
    } else {
      final home = Platform.environment['HOME'] ?? '';
      searchFolders.addAll([
        p.join(home, 'Downloads'),
        p.join(home, 'Desktop'),
        p.join(home, 'Documents'),
        p.join(home, 'Pictures'),
      ]);
    }

    try {
      final sendSnapDir = await FileHandler.getDownloadsDirectory();
      searchFolders.add(sendSnapDir.path);
    } catch (_) {}

    return await Isolate.run(() {
      final results = <LocalItem>[];
      final visitedPaths = <String>{};

      for (final folderPath in searchFolders) {
        final dir = Directory(folderPath);
        if (!dir.existsSync()) continue;

        try {
          final entries = dir.listSync(recursive: false, followLinks: false);
          for (final entry in entries) {
            if (entry is File && !visitedPaths.contains(entry.path)) {
              final name = p.basename(entry.path);
              if (name.startsWith('.')) continue;

              try {
                final stat = entry.statSync();
                final ext = p.extension(entry.path).toLowerCase();
                results.add(LocalItem(
                  path: entry.path,
                  name: name,
                  size: stat.size,
                  modified: stat.modified,
                  isDirectory: false,
                  extension: ext,
                ));
                visitedPaths.add(entry.path);
              } catch (_) {}
            }
          }
        } catch (_) {}
      }

      results.sort((a, b) => b.modified.compareTo(a.modified));
      if (results.length > 150) {
        return results.sublist(0, 150);
      }
      return results;
    });
  }
}
