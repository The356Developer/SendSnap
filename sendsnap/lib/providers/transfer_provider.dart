import 'package:flutter/material.dart';
import 'package:path/path.dart' as path;
import 'dart:io';
import '../models/transfer.dart';
import '../models/device.dart';
import '../services/nearby_service.dart';

class TransferProvider with ChangeNotifier {
  final List<FileTransfer> _transfers = [];
  final List<String> _currentSessionIds = [];
  FileTransfer? _activeTransfer;
  String? _peerName;
  bool _sessionIsIncoming = false;
  bool _isTransferRouteOpen = false;

  // Callbacks for UI navigation & notification
  VoidCallback? onTransferStarted;
  VoidCallback? onTransferCompleted;

  List<FileTransfer> get transfers => _transfers;
  FileTransfer? get activeTransfer => _activeTransfer;
  bool get isTransferRouteOpen => _isTransferRouteOpen;
  String? get peerName => _peerName;
  bool get sessionIsIncoming => _sessionIsIncoming;

  /// Returns the most recent transfer (active or last in list)
  FileTransfer? get currentTransfer =>
      _activeTransfer ?? (_transfers.isNotEmpty ? _transfers.first : null);

  /// All transfers belonging to the active batch/session in display order.
  List<FileTransfer> get currentBatchTransfers {
    if (_currentSessionIds.isEmpty) {
      return _activeTransfer != null ? [_activeTransfer!] : const [];
    }
    final byId = <String, FileTransfer>{
      for (final t in _transfers) t.id: t,
    };
    final batch = <FileTransfer>[];
    for (final id in _currentSessionIds) {
      final item = byId[id];
      if (item != null) batch.add(item);
    }
    return batch;
  }

  bool get hasActiveBatch => currentBatchTransfers.any(
        (t) =>
            t.status == TransferStatus.inProgress ||
            t.status == TransferStatus.pending,
      );

  bool get isBatchComplete =>
      currentBatchTransfers.isNotEmpty && !hasActiveBatch;

  int get completedBatchCount => currentBatchTransfers
      .where((t) => t.status == TransferStatus.completed)
      .length;

  int get failedBatchCount => currentBatchTransfers
      .where(
        (t) =>
            t.status == TransferStatus.failed ||
            t.status == TransferStatus.cancelled,
      )
      .length;

  int get totalBatchBytes =>
      currentBatchTransfers.fold(0, (sum, t) => sum + t.fileSize);

  int get transferredBatchBytes => currentBatchTransfers.fold(
        0,
        (sum, t) =>
            sum +
            (t.status == TransferStatus.completed
                ? t.fileSize
                : t.transferredBytes),
      );

  double get batchProgress {
    final total = totalBatchBytes;
    if (total == 0) {
      return isBatchComplete ? 1.0 : 0.0;
    }
    return (transferredBatchBytes / total).clamp(0.0, 1.0);
  }

  double get currentBatchSpeed {
    for (final t in currentBatchTransfers) {
      if (t.status == TransferStatus.inProgress) {
        return t.speed;
      }
    }
    return 0.0;
  }

  FileTransfer? get currentActiveFile {
    final batch = currentBatchTransfers;
    for (final t in batch) {
      if (t.status == TransferStatus.inProgress) return t;
    }
    for (final t in batch) {
      if (t.status == TransferStatus.pending) return t;
    }
    return batch.isNotEmpty ? batch.last : null;
  }

  void setTransferRouteOpen(bool open) {
    _isTransferRouteOpen = open;
  }

  void addTransfer(FileTransfer transfer) {
    _transfers.insert(0, transfer);
    if (!_currentSessionIds.contains(transfer.id)) {
      _currentSessionIds.add(transfer.id);
    }
    if (transfer.status == TransferStatus.inProgress ||
        transfer.status == TransferStatus.pending) {
      _activeTransfer = transfer;
    }
    notifyListeners();
  }

  void handleIncomingBatch(
    NearbyDevice sender,
    List<FileTransfer> files, {
    String? sessionId,
  }) {
    if (files.isEmpty) return;

    if (!_isTransferRouteOpen ||
        _currentSessionIds.isEmpty ||
        !_sessionIsIncoming) {
      _currentSessionIds.clear();
      _sessionIsIncoming = true;
    }
    _peerName = sender.name;

    FileTransfer? firstIncoming;
    for (final f in files) {
      final incoming = f.copyWith(isIncoming: true);
      firstIncoming ??= incoming;
      _transfers.insert(0, incoming);
      _currentSessionIds.add(incoming.id);
    }
    _activeTransfer = firstIncoming;

    debugPrint(
      '[TransferProvider] Handling incoming batch (${files.length} files) from ${sender.name}',
    );
    notifyListeners();
    onTransferStarted?.call();
  }

  void handleIncomingTransfer(NearbyDevice sender, FileTransfer transfer) {
    handleIncomingBatch(sender, [transfer]);
  }

  void updateTransferProgress({
    required String transferId,
    required int bytesTransferred,
    required int totalBytes,
    required double speed,
  }) {
    final index = _transfers.indexWhere((t) => t.id == transferId);
    if (index == -1) return;

    final updated = _transfers[index].copyWith(
      transferredBytes: bytesTransferred,
      fileSize: totalBytes > 0 ? totalBytes : _transfers[index].fileSize,
      speed: speed,
      status: TransferStatus.inProgress,
    );

    _transfers[index] = updated;
    _activeTransfer = updated;
    notifyListeners();
  }

  void markTransferCompleted({
    required String transferId,
    required String savedPath,
  }) {
    final index = _transfers.indexWhere((t) => t.id == transferId);
    if (index == -1) return;

    final existing = _transfers[index];
    final completed = existing.copyWith(
      transferredBytes: existing.fileSize,
      status: TransferStatus.completed,
      savedPath: existing.isIncoming ? savedPath : existing.savedPath,
      filePath: existing.isIncoming
          ? existing.filePath
          : (existing.filePath ?? savedPath),
      speed: 0.0,
    );

    _transfers[index] = completed;

    FileTransfer? nextActive;
    for (final t in currentBatchTransfers) {
      if (t.status == TransferStatus.inProgress ||
          t.status == TransferStatus.pending) {
        nextActive = t;
        break;
      }
    }
    _activeTransfer = nextActive ?? completed;
    notifyListeners();
    if (isBatchComplete) {
      onTransferCompleted?.call();
    }
  }

  void markTransferFailed({
    required String transferId,
    required String error,
  }) {
    final index = _transfers.indexWhere((t) => t.id == transferId);
    if (index == -1) return;

    final failed = _transfers[index].copyWith(
      status: TransferStatus.failed,
      errorMessage: error,
      speed: 0.0,
    );

    _transfers[index] = failed;

    FileTransfer? nextActive;
    for (final t in currentBatchTransfers) {
      if (t.status == TransferStatus.inProgress ||
          t.status == TransferStatus.pending) {
        nextActive = t;
        break;
      }
    }
    _activeTransfer = nextActive ?? failed;
    notifyListeners();
  }

  /// Initiates sending a file to target device.
  /// Supports either passing a NearbyDevice object or its endpoint ID string.
  Future<bool> sendFile(
    dynamic targetOrEndpointId,
    File file,
    NearbyService service,
  ) async {
    return sendFiles(targetOrEndpointId, [file], service);
  }

  /// Initiates sending multiple files to target device.
  Future<bool> sendFiles(
    dynamic targetOrEndpointId,
    List<File> files,
    NearbyService service,
  ) async {
    if (files.isEmpty) return false;

    NearbyDevice? target;
    if (targetOrEndpointId is NearbyDevice) {
      target = targetOrEndpointId;
    } else if (targetOrEndpointId is String) {
      target = service.getDevice(targetOrEndpointId);
    }

    if (target == null) {
      debugPrint('[TransferProvider] Cannot send file: Target device not found');
      return false;
    }

    if (!_isTransferRouteOpen || _sessionIsIncoming || !hasActiveBatch) {
      _currentSessionIds.clear();
    }
    _sessionIsIncoming = false;
    _peerName = target.name;

    final batchTs = DateTime.now().millisecondsSinceEpoch;
    final transfers = <FileTransfer>[];
    for (int i = 0; i < files.length; i++) {
      final f = files[i];
      final size = await f.length();
      final t = FileTransfer(
        id: '${batchTs}_$i',
        fileName: path.basename(f.path),
        fileSize: size,
        filePath: f.path,
        isIncoming: false,
        status: i == 0 ? TransferStatus.inProgress : TransferStatus.pending,
      );
      transfers.add(t);
      _transfers.insert(0, t);
      _currentSessionIds.add(t.id);
    }
    _activeTransfer = transfers.first;
    notifyListeners();

    final success = await service.sendFilesStream(
      target: target,
      transfers: transfers,
      files: files,
    );

    return success;
  }

  void closeSession() {
    _currentSessionIds.clear();
    _activeTransfer = null;
    _peerName = null;
    notifyListeners();
  }

  void clearHistory() {
    _transfers.removeWhere((t) => t.status != TransferStatus.inProgress);
    _currentSessionIds.removeWhere(
      (id) => !_transfers.any((t) => t.id == id),
    );
    _activeTransfer = null;
    if (_currentSessionIds.isEmpty) {
      _peerName = null;
    }
    notifyListeners();
  }

  void dismissActiveTransfer() {
    if (!hasActiveBatch) {
      closeSession();
      return;
    }
    _activeTransfer = null;
    notifyListeners();
  }
}
