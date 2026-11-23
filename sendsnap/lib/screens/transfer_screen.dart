import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../config/constants.dart';
import '../models/transfer.dart';
import '../providers/device_provider.dart';
import '../providers/transfer_provider.dart';
import '../services/file_handler.dart';
import '../services/local_storage_service.dart';
import '../services/rating_service.dart';
import '../widgets/ambient_background.dart';
import '../widgets/bouncing_card.dart';
import '../widgets/glass_container.dart';
import '../widgets/media_viewer_modal.dart';
import 'received_files_screen.dart';

class TransferScreen extends StatefulWidget {
  final VoidCallback? onReturnHome;

  const TransferScreen({
    super.key,
    this.onReturnHome,
  });

  @override
  State<TransferScreen> createState() => _TransferScreenState();
}

class _TransferScreenState extends State<TransferScreen> {
  bool _hasTriggeredRating = false;
  TransferProvider? _transProv;

  @override
  void initState() {
    super.initState();
    _transProv = Provider.of<TransferProvider>(context, listen: false);
    _transProv?.setTransferRouteOpen(true);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _transProv ??= Provider.of<TransferProvider>(context, listen: false);
    _transProv?.setTransferRouteOpen(true);
  }

  @override
  void dispose() {
    _transProv?.setTransferRouteOpen(false);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final transProv = Provider.of<TransferProvider>(context);
    final batch = transProv.currentBatchTransfers;

    if (batch.isEmpty) {
      return AmbientBackground(
        child: Scaffold(
          backgroundColor: Colors.transparent,
          appBar: AppBar(
            backgroundColor: Colors.transparent,
            elevation: 0,
            leading: _buildTopCloseButton(
              context,
              onTap: () => Navigator.of(context).maybePop(),
            ),
            title: Text(
              'Transfer',
              style: TextStyle(
                fontWeight: FontWeight.w800,
                fontSize: 19,
                color: AppColors.textPrimaryOf(context),
              ),
            ),
            centerTitle: true,
          ),
          body: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'No active transfers',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textSecondaryOf(context),
                  ),
                ),
                const SizedBox(height: 16),
                ElevatedButton.icon(
                  onPressed: () =>
                      _closeAllAndReturnToMainMenu(context, transProv),
                  icon: const Icon(Icons.home_rounded, size: 18),
                  label: const Text('BACK TO MAIN MENU'),
                ),
              ],
            ),
          ),
        ),
      );
    }

    final isBatchComplete = transProv.isBatchComplete;
    final completedFiles =
        batch.where((t) => t.status == TransferStatus.completed).toList();
    final failedCount = transProv.failedBatchCount;
    final isIncoming = transProv.sessionIsIncoming ||
        batch.any((t) => t.isIncoming || (t.savedPath != null && t.filePath == null));

    if (isBatchComplete &&
        completedFiles.isNotEmpty &&
        !_hasTriggeredRating) {
      _hasTriggeredRating = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          RatingService.recordSuccessfulTransfer(context);
        }
      });
    }

    final screenWidth = MediaQuery.sizeOf(context).width;
    final isDesktopLayout = screenWidth >= 740;

    return CallbackShortcuts(
      bindings: {
        if (isBatchComplete)
          const SingleActivator(LogicalKeyboardKey.escape): () =>
              _closeAllAndReturnToMainMenu(context, transProv),
      },
      child: Focus(
        autofocus: true,
        child: AmbientBackground(
          child: Scaffold(
            backgroundColor: Colors.transparent,
            appBar: AppBar(
              backgroundColor: Colors.transparent,
              elevation: 0,
              leading: Padding(
                padding: const EdgeInsets.only(left: 12),
                child: _buildTopCloseButton(
                  context,
                  tooltip: isBatchComplete
                      ? 'Close all & return to main menu'
                      : 'Minimize to background',
                  onTap: () {
                    if (isBatchComplete) {
                      _closeAllAndReturnToMainMenu(context, transProv);
                    } else {
                      Navigator.of(context).pop();
                    }
                  },
                ),
              ),
              title: Text(
                _getAppBarTitle(
                  batch: batch,
                  isComplete: isBatchComplete,
                  isPaused: transProv.isBatchPaused,
                  failedCount: failedCount,
                  cancelledCount: transProv.cancelledBatchCount,
                  isIncoming: isIncoming,
                ),
                style: TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 19,
                  letterSpacing: -0.3,
                  color: AppColors.textPrimaryOf(context),
                ),
              ),
              centerTitle: true,
              actions: [
                if (isDesktopLayout && isBatchComplete)
                  Padding(
                    padding: const EdgeInsets.only(right: 16),
                    child: Center(
                      child: BouncingCard(
                        onTap: () =>
                            _closeAllAndReturnToMainMenu(context, transProv),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 8,
                          ),
                          decoration: BoxDecoration(
                            color: AppColors.surfaceOf(context),
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(
                              color: AppColors.inkOf(context),
                              width: 1.6,
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: AppColors.isDark(context)
                                    ? Colors.black.withValues(alpha: 0.7)
                                    : AppColors.ink,
                                blurRadius: 0,
                                offset: const Offset(2, 2.5),
                              ),
                            ],
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(
                                Icons.home_rounded,
                                size: 16,
                                color: AppColors.primary,
                              ),
                              const SizedBox(width: 6),
                              Text(
                                'Close All',
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                  color: AppColors.textPrimaryOf(context),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            body: SafeArea(
              child: isDesktopLayout
                  ? _buildDesktopLayout(
                      context,
                      transProv: transProv,
                      batch: batch,
                      completedFiles: completedFiles,
                      isBatchComplete: isBatchComplete,
                      isIncoming: isIncoming,
                      failedCount: failedCount,
                    )
                  : _buildMobileLayout(
                      context,
                      transProv: transProv,
                      batch: batch,
                      completedFiles: completedFiles,
                      isBatchComplete: isBatchComplete,
                      isIncoming: isIncoming,
                      failedCount: failedCount,
                    ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTopCloseButton(
    BuildContext context, {
    required VoidCallback onTap,
    String? tooltip,
  }) {
    final btn = BouncingCard(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.all(6),
        decoration: BoxDecoration(
          color: AppColors.surfaceOf(context),
          shape: BoxShape.circle,
          border: Border.all(color: AppColors.inkOf(context), width: 1.6),
          boxShadow: [
            BoxShadow(
              color: AppColors.isDark(context)
                  ? Colors.black.withValues(alpha: 0.7)
                  : AppColors.ink,
              blurRadius: 0,
              offset: const Offset(2, 2.5),
            ),
          ],
        ),
        child: Icon(
          Icons.close_rounded,
          color: AppColors.textPrimaryOf(context),
          size: 20,
        ),
      ),
    );

    if (tooltip != null) {
      return Tooltip(message: tooltip, child: btn);
    }
    return btn;
  }

  void _closeAllAndReturnToMainMenu(
    BuildContext context,
    TransferProvider transProv,
  ) {
    transProv.closeSession();
    if (widget.onReturnHome != null) {
      widget.onReturnHome!();
    } else {
      try {
        Provider.of<DeviceProvider>(context, listen: false)
            .stopAll(resumeWarm: true);
      } on ProviderNotFoundException {
        // Safe in isolated unit/widget tests that only provide TransferProvider.
      } catch (e) {
        debugPrint('[TransferScreen] stopAll error: $e');
      }
    }

    final nav = Navigator.of(context);
    if (nav.canPop()) {
      nav.pop('main_menu');
    }
    nav.popUntil(
      (route) => route.settings.name == '/home' || route.isFirst,
    );
  }

  // ---------------------------------------------------------------------------
  // Desktop Two-Pane Layout (width >= 740)
  // ---------------------------------------------------------------------------

  Widget _buildDesktopLayout(
    BuildContext context, {
    required TransferProvider transProv,
    required List<FileTransfer> batch,
    required List<FileTransfer> completedFiles,
    required bool isBatchComplete,
    required bool isIncoming,
    required int failedCount,
  }) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1040),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Left Summary & Main Actions Pane
              SizedBox(
                width: 340,
                child: GlassContainer(
                  blur: 16,
                  opacity: 0.76,
                  borderRadius: 32,
                  padding: const EdgeInsets.all(24),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.06),
                      blurRadius: 28,
                      offset: const Offset(0, 12),
                    ),
                  ],
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      return SingleChildScrollView(
                        physics: const BouncingScrollPhysics(),
                        child: ConstrainedBox(
                          constraints: BoxConstraints(
                            minHeight: constraints.maxHeight,
                          ),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  _buildProgressRing(
                                    context,
                                    transProv: transProv,
                                    isComplete: isBatchComplete,
                                    failedCount: failedCount,
                                    completedCount: completedFiles.length,
                                    diameter: 140,
                                    strokeWidth: 10,
                                    percentFontSize: 30,
                                    iconSize: 28,
                                  ),
                                  const SizedBox(height: 18),
                                  Text(
                                    _getSummaryHeadline(
                                      transProv: transProv,
                                      batch: batch,
                                      isComplete: isBatchComplete,
                                      isIncoming: isIncoming,
                                      completedCount: completedFiles.length,
                                      failedCount: failedCount,
                                    ),
                                    textAlign: TextAlign.center,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 20,
                                      fontWeight: FontWeight.w800,
                                      letterSpacing: -0.4,
                                      color: AppColors.textPrimaryOf(context),
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                  _buildPeerAndLocationSubtitle(
                                    context,
                                    transProv: transProv,
                                    isComplete: isBatchComplete,
                                    isIncoming: isIncoming,
                                    completedCount: completedFiles.length,
                                    failedCount: failedCount,
                                  ),
                                  const SizedBox(height: 16),
                                  _buildStatsRow(
                                    context,
                                    transProv: transProv,
                                    batch: batch,
                                    completedCount: completedFiles.length,
                                  ),
                                ],
                              ),
                              Padding(
                                padding: const EdgeInsets.only(top: 20),
                                child: _buildLeftPaneActions(
                                  context,
                                  transProv: transProv,
                                  batch: batch,
                                  completedFiles: completedFiles,
                                  isBatchComplete: isBatchComplete,
                                  isIncoming: isIncoming,
                                  failedCount: failedCount,
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
              const SizedBox(width: 20),

              // Right Interactive File Viewer Pane
              Expanded(
                child: GlassContainer(
                  blur: 16,
                  opacity: 0.76,
                  borderRadius: 32,
                  padding: const EdgeInsets.all(20),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.06),
                      blurRadius: 28,
                      offset: const Offset(0, 12),
                    ),
                  ],
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _buildFilesPaneHeader(
                        context,
                        batch: batch,
                        completedFiles: completedFiles,
                        isBatchComplete: isBatchComplete,
                      ),
                      const SizedBox(height: 14),
                      Expanded(
                        child: batch.length == 1 &&
                                isBatchComplete &&
                                completedFiles.length == 1
                            ? _buildSingleFileSpotlight(
                                context,
                                completedFiles.first,
                                completedFiles,
                              )
                            : ListView.separated(
                                physics: const BouncingScrollPhysics(),
                                itemCount: batch.length,
                                separatorBuilder: (_, _) =>
                                    const SizedBox(height: 10),
                                itemBuilder: (context, index) => _buildFileRow(
                                  context,
                                  transProv: transProv,
                                  file: batch[index],
                                  completedFiles: completedFiles,
                                  isIncoming: isIncoming,
                                ),
                              ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Mobile / Narrow Layout (width < 740)
  // ---------------------------------------------------------------------------

  Widget _buildMobileLayout(
    BuildContext context, {
    required TransferProvider transProv,
    required List<FileTransfer> batch,
    required List<FileTransfer> completedFiles,
    required bool isBatchComplete,
    required bool isIncoming,
    required int failedCount,
  }) {
    return Center(
      child: SingleChildScrollView(
        physics: const BouncingScrollPhysics(),
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.l,
          vertical: AppSpacing.m,
        ),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              GlassContainer(
                blur: 16,
                opacity: 0.76,
                borderRadius: 32,
                padding: const EdgeInsets.symmetric(
                  horizontal: 22,
                  vertical: 26,
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.06),
                    blurRadius: 28,
                    offset: const Offset(0, 10),
                  ),
                ],
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _buildProgressRing(
                      context,
                      transProv: transProv,
                      isComplete: isBatchComplete,
                      failedCount: failedCount,
                      completedCount: completedFiles.length,
                      diameter: 136,
                      strokeWidth: 10,
                      percentFontSize: 28,
                      iconSize: 26,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      _getSummaryHeadline(
                        transProv: transProv,
                        batch: batch,
                        isComplete: isBatchComplete,
                        isIncoming: isIncoming,
                        completedCount: completedFiles.length,
                        failedCount: failedCount,
                      ),
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 19,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -0.3,
                        color: AppColors.textPrimaryOf(context),
                      ),
                    ),
                    const SizedBox(height: 8),
                    _buildPeerAndLocationSubtitle(
                      context,
                      transProv: transProv,
                      isComplete: isBatchComplete,
                      isIncoming: isIncoming,
                      completedCount: completedFiles.length,
                      failedCount: failedCount,
                    ),
                    const SizedBox(height: 16),
                    _buildStatsRow(
                      context,
                      transProv: transProv,
                      batch: batch,
                      completedCount: completedFiles.length,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              GlassContainer(
                blur: 16,
                opacity: 0.76,
                borderRadius: 28,
                padding: const EdgeInsets.all(18),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.05),
                    blurRadius: 20,
                    offset: const Offset(0, 8),
                  ),
                ],
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _buildFilesPaneHeader(
                      context,
                      batch: batch,
                      completedFiles: completedFiles,
                      isBatchComplete: isBatchComplete,
                    ),
                    const SizedBox(height: 12),
                    ListView.separated(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      itemCount: batch.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 10),
                      itemBuilder: (context, index) => _buildFileRow(
                        context,
                        transProv: transProv,
                        file: batch[index],
                        completedFiles: completedFiles,
                        isIncoming: isIncoming,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 18),
              _buildLeftPaneActions(
                context,
                transProv: transProv,
                batch: batch,
                completedFiles: completedFiles,
                isBatchComplete: isBatchComplete,
                isIncoming: isIncoming,
                failedCount: failedCount,
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Shared Building Blocks
  // ---------------------------------------------------------------------------

  Widget _buildProgressRing(
    BuildContext context, {
    required TransferProvider transProv,
    required bool isComplete,
    required int failedCount,
    required int completedCount,
    required double diameter,
    required double strokeWidth,
    required double percentFontSize,
    required double iconSize,
  }) {
    final bool allCancelled = isComplete &&
        completedCount == 0 &&
        transProv.cancelledBatchCount == transProv.currentBatchTransfers.length;
    final bool allFailed = isComplete && completedCount == 0 && failedCount > 0;
    final bool partialFailure = isComplete && failedCount > 0 && completedCount > 0;
    final bool isPaused = !isComplete && transProv.isBatchPaused;

    Color progressColor = AppColors.primary;
    IconData centerIcon = Icons.sync_rounded;
    if (allCancelled) {
      progressColor = AppColors.warning;
      centerIcon = Icons.cancel_rounded;
    } else if (allFailed) {
      progressColor = AppColors.error;
      centerIcon = Icons.error_rounded;
    } else if (partialFailure) {
      progressColor = AppColors.warning;
      centerIcon = Icons.warning_rounded;
    } else if (isPaused) {
      progressColor = AppColors.warning;
      centerIcon = Icons.pause_circle_rounded;
    } else if (isComplete) {
      progressColor = AppColors.success;
      centerIcon = Icons.check_circle_rounded;
    }

    final progress = isComplete && failedCount == 0 ? 1.0 : transProv.batchProgress;

    return Stack(
      alignment: Alignment.center,
      children: [
        Container(
          width: diameter + 18,
          height: diameter + 18,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: progressColor.withValues(alpha: isComplete ? 0.30 : 0.16),
                blurRadius: 32,
                spreadRadius: 2,
              ),
            ],
          ),
        ),
        SizedBox(
          width: diameter,
          height: diameter,
          child: CircularProgressIndicator(
            value: progress,
            strokeWidth: strokeWidth,
            backgroundColor: progressColor.withValues(alpha: 0.14),
            valueColor: AlwaysStoppedAnimation<Color>(progressColor),
            strokeCap: StrokeCap.round,
          ),
        ),
        Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(9),
              decoration: BoxDecoration(
                color: progressColor.withValues(alpha: 0.12),
                shape: BoxShape.circle,
              ),
              child: Icon(centerIcon, size: iconSize, color: progressColor),
            ),
            const SizedBox(height: 6),
            Text(
              '${(progress * 100).toInt()}%',
              style: TextStyle(
                fontSize: percentFontSize,
                fontWeight: FontWeight.w800,
                letterSpacing: -0.8,
                color: AppColors.textPrimaryOf(context),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildPeerAndLocationSubtitle(
    BuildContext context, {
    required TransferProvider transProv,
    required bool isComplete,
    required bool isIncoming,
    required int completedCount,
    required int failedCount,
  }) {
    final peer = transProv.peerName;
    if (!isComplete) {
      if (transProv.isBatchPaused) {
        return const Text(
          'Transfer paused',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: AppColors.warning,
            fontSize: 13,
            fontWeight: FontWeight.w700,
          ),
        );
      }
      final speed = transProv.currentBatchSpeed;
      if (speed > 0) {
        final formatted = speed < 1024
            ? '${speed.toStringAsFixed(0)} B/s'
            : speed < 1024 * 1024
                ? '${(speed / 1024).toStringAsFixed(1)} KB/s'
                : '${(speed / (1024 * 1024)).toStringAsFixed(1)} MB/s';
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [
                AppColors.primary.withValues(alpha: 0.12),
                AppColors.secondary.withValues(alpha: 0.12),
              ],
            ),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: AppColors.primary.withValues(alpha: 0.2),
            ),
          ),
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.bolt_rounded, color: AppColors.primary, size: 16),
                const SizedBox(width: 4),
                Text(
                  peer != null && peer.isNotEmpty
                      ? '$formatted • $peer'
                      : formatted,
                  maxLines: 1,
                  softWrap: false,
                  style: const TextStyle(
                    color: AppColors.primary,
                    fontWeight: FontWeight.w800,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
        );
      }
      return Text(
        peer != null && peer.isNotEmpty
            ? '${isIncoming ? 'Receiving from' : 'Sending to'} $peer'
            : 'Keep both devices nearby until finished',
        textAlign: TextAlign.center,
        style: TextStyle(
          color: AppColors.textSecondaryOf(context),
          fontSize: 13,
          fontWeight: FontWeight.w500,
        ),
      );
    }

    if (failedCount > 0 && completedCount == 0) {
      final allCancelled =
          transProv.cancelledBatchCount == transProv.currentBatchTransfers.length;
      return Text(
        allCancelled
            ? 'Transfer was cancelled.'
            : 'Transfer failed. Check connection and try again.',
        textAlign: TextAlign.center,
        style: TextStyle(
          color: allCancelled ? AppColors.warning : AppColors.error,
          fontSize: 13,
          fontWeight: FontWeight.w600,
        ),
      );
    }

    final baseText = isIncoming
        ? 'Saved to Downloads/SendSnap'
        : 'Sent successfully!';
    final peerPart = (peer != null && peer.isNotEmpty)
        ? (isIncoming ? ' • From $peer' : ' • To $peer')
        : '';

    return Text(
      '$baseText$peerPart',
      textAlign: TextAlign.center,
      style: TextStyle(
        color: failedCount > 0 ? AppColors.warning : AppColors.success,
        fontWeight: FontWeight.w700,
        fontSize: 13,
      ),
    );
  }

  Widget _buildStatsRow(
    BuildContext context, {
    required TransferProvider transProv,
    required List<FileTransfer> batch,
    required int completedCount,
  }) {
    return Row(
      children: [
        Expanded(
          child: _buildStatChip(
            context,
            label: 'FILES',
            value: '$completedCount / ${batch.length}',
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _buildStatChip(
            context,
            label: 'TOTAL SIZE',
            value: FileHandler.formatFileSize(transProv.totalBatchBytes),
          ),
        ),
      ],
    );
  }

  Widget _buildStatChip(
    BuildContext context, {
    required String label,
    required String value,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.subtleFillOf(context),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.subtleBorderOf(context)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.8,
              color: AppColors.textSecondaryOf(context),
            ),
          ),
          const SizedBox(height: 3),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w800,
              color: AppColors.textPrimaryOf(context),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLeftPaneActions(
    BuildContext context, {
    required TransferProvider transProv,
    required List<FileTransfer> batch,
    required List<FileTransfer> completedFiles,
    required bool isBatchComplete,
    required bool isIncoming,
    required int failedCount,
  }) {
    if (!isBatchComplete) {
      final isPaused = transProv.isBatchPaused;
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (!isIncoming) ...[
            Row(
              children: [
                Expanded(
                  child: BouncingCard(
                    onTap: transProv.togglePauseAll,
                    child: Container(
                      height: 48,
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      decoration: BoxDecoration(
                        color: (isPaused ? AppColors.primary : AppColors.warning)
                            .withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(18),
                        border: Border.all(
                          color: isPaused ? AppColors.primary : AppColors.warning,
                          width: 1.5,
                        ),
                      ),
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              isPaused
                                  ? Icons.play_arrow_rounded
                                  : Icons.pause_rounded,
                              size: 19,
                              color: isPaused
                                  ? AppColors.primary
                                  : AppColors.warning,
                            ),
                            const SizedBox(width: 5),
                            Text(
                              isPaused ? 'RESUME' : 'PAUSE',
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 0.4,
                                color: isPaused
                                    ? AppColors.primary
                                    : AppColors.warning,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: BouncingCard(
                    onTap: () => transProv.cancelAll(),
                    child: Container(
                      height: 48,
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      decoration: BoxDecoration(
                        color: AppColors.error.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(18),
                        border: Border.all(
                          color: AppColors.error,
                          width: 1.5,
                        ),
                      ),
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const Icon(
                              Icons.close_rounded,
                              size: 19,
                              color: AppColors.error,
                            ),
                            const SizedBox(width: 5),
                            Text(
                              batch.length > 1 ? 'CANCEL ALL' : 'CANCEL',
                              style: const TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 0.4,
                                color: AppColors.error,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
          ],
          SizedBox(
            width: double.infinity,
            child: BouncingCard(
              onTap: () => Navigator.of(context).pop(),
              child: Container(
                height: 48,
                decoration: BoxDecoration(
                  color: AppColors.surfaceOf(context),
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: AppColors.inkOf(context), width: 1.6),
                ),
                child: Center(
                  child: Text(
                    'MINIMIZE',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.4,
                      color: AppColors.textPrimaryOf(context),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      );
    }

    final primaryLabel =
        batch.length > 1 ? 'CLOSE ALL & MAIN MENU' : 'DONE · MAIN MENU';

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (isIncoming && completedFiles.isNotEmpty) ...[
          BouncingCard(
            onTap: () => FileHandler.openFolderChoice(
              context,
              filePath: completedFiles.first.localPath,
            ),
            child: Container(
              height: 48,
              padding: const EdgeInsets.symmetric(horizontal: 14),
              decoration: BoxDecoration(
                color: AppColors.surfaceOf(context),
                borderRadius: BorderRadius.circular(18),
                border: Border.all(
                  color: AppColors.subtleBorderOf(context),
                  width: 1.4,
                ),
              ),
              child: const FittedBox(
                fit: BoxFit.scaleDown,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.folder_open_rounded,
                      color: AppColors.primary,
                      size: 19,
                    ),
                    SizedBox(width: 8),
                    Text(
                      'OPEN FOLDER',
                      style: TextStyle(
                        color: AppColors.primary,
                        fontWeight: FontWeight.w700,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 10),
          BouncingCard(
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const ReceivedFilesScreen()),
              );
            },
            child: Container(
              height: 48,
              padding: const EdgeInsets.symmetric(horizontal: 14),
              decoration: BoxDecoration(
                color: AppColors.surfaceOf(context),
                borderRadius: BorderRadius.circular(18),
                border: Border.all(
                  color: AppColors.subtleBorderOf(context),
                  width: 1.4,
                ),
              ),
              child: const FittedBox(
                fit: BoxFit.scaleDown,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.folder_special_rounded,
                      color: AppColors.primary,
                      size: 19,
                    ),
                    SizedBox(width: 8),
                    Text(
                      'RECEIVED LIBRARY',
                      style: TextStyle(
                        color: AppColors.primary,
                        fontWeight: FontWeight.w700,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
        ],
        BouncingCard(
          onTap: () => _closeAllAndReturnToMainMenu(context, transProv),
          child: Container(
            height: 54,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            decoration: BoxDecoration(
              gradient: failedCount == 0
                  ? AppColors.receiveGradient
                  : AppColors.sendGradient,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: AppColors.inkOf(context), width: 2.0),
              boxShadow: [
                BoxShadow(
                  color: AppColors.isDark(context)
                      ? Colors.black.withValues(alpha: 0.75)
                      : AppColors.ink,
                  blurRadius: 0,
                  offset: const Offset(3, 4),
                ),
              ],
            ),
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.home_rounded, color: Colors.white, size: 20),
                  const SizedBox(width: 8),
                  Text(
                    primaryLabel,
                    style: const TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 14,
                      letterSpacing: 0.4,
                      color: Colors.white,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildFilesPaneHeader(
    BuildContext context, {
    required List<FileTransfer> batch,
    required List<FileTransfer> completedFiles,
    required bool isBatchComplete,
  }) {
    final canOpenGallery = completedFiles.isNotEmpty && batch.length > 1;
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Files (${batch.length})',
                style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.3,
                  color: AppColors.textPrimaryOf(context),
                ),
              ),
              const SizedBox(height: 2),
              Text(
                isBatchComplete
                    ? 'Click any file to view'
                    : 'Transfer queue',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  color: AppColors.textSecondaryOf(context),
                ),
              ),
            ],
          ),
        ),
        if (canOpenGallery)
          BouncingCard(
            onTap: () => _openGallery(context, completedFiles),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: AppColors.primary.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: AppColors.primary.withValues(alpha: 0.2),
                ),
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.photo_library_rounded,
                    size: 16,
                    color: AppColors.primary,
                  ),
                  SizedBox(width: 6),
                  Text(
                    'Gallery View',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: AppColors.primary,
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildSingleFileSpotlight(
    BuildContext context,
    FileTransfer file,
    List<FileTransfer> completedFiles,
  ) {
    final localPath = file.localPath;
    final hasFile = localPath != null && File(localPath).existsSync();
    final isPreviewable = hasFile && _isPreviewableImage(localPath);
    final ext = p.extension(file.fileName).toUpperCase().replaceAll('.', '');

    return LayoutBuilder(
      builder: (context, constraints) {
        return Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Expanded(
              child: Center(
                child: isPreviewable
                    ? InkWell(
                        onTap: () => _openFile(context, file, completedFiles),
                        borderRadius: BorderRadius.circular(24),
                        child: Container(
                          constraints: BoxConstraints(
                            maxHeight: (constraints.maxHeight - 130)
                                .clamp(120.0, 420.0),
                          ),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(24),
                            border: Border.all(
                              color: Colors.black.withValues(alpha: 0.08),
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.08),
                                blurRadius: 20,
                                offset: const Offset(0, 8),
                              ),
                            ],
                          ),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(24),
                            child: Image.file(
                              File(localPath),
                              fit: BoxFit.contain,
                              errorBuilder: (_, _, _) =>
                                  _buildSpotlightTypeIcon(file),
                            ),
                          ),
                        ),
                      )
                    : _buildSpotlightTypeIcon(file),
              ),
            ),
            const SizedBox(height: 14),
            Text(
              file.fileName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w800,
                color: AppColors.textPrimaryOf(context),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '${FileHandler.formatFileSize(file.fileSize)}${ext.isNotEmpty ? ' • $ext' : ''}',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: AppColors.textSecondaryOf(context),
              ),
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              alignment: WrapAlignment.center,
              children: [
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 12,
                    ),
                  ),
                  onPressed: () => _openFile(context, file, completedFiles),
                  icon: Icon(
                    isPreviewable
                        ? Icons.visibility_rounded
                        : Icons.open_in_new_rounded,
                    size: 18,
                  ),
                  label: Text(
                    isPreviewable ? 'View File' : 'Open File',
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.textPrimaryOf(context),
                    side: BorderSide(
                      color: AppColors.subtleBorderOf(context),
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 18,
                      vertical: 12,
                    ),
                  ),
                  onPressed: () => _showInFolder(context, file),
                  icon: const Icon(Icons.folder_open_rounded, size: 18),
                  label: const Text(
                    'Show in Folder',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
              ],
            ),
          ],
        );
      },
    );
  }

  Widget _buildSpotlightTypeIcon(FileTransfer file) {
    final style = _styleForFile(file.fileName);
    return Container(
      padding: const EdgeInsets.all(28),
      decoration: BoxDecoration(
        color: style.color.withValues(alpha: 0.12),
        shape: BoxShape.circle,
        border: Border.all(color: style.color.withValues(alpha: 0.25), width: 2),
      ),
      child: Icon(style.icon, size: 52, color: style.color),
    );
  }

  Widget _buildFileRow(
    BuildContext context, {
    required TransferProvider transProv,
    required FileTransfer file,
    required List<FileTransfer> completedFiles,
    required bool isIncoming,
  }) {
    final isCompleted = file.status == TransferStatus.completed;
    final isInProgress = file.status == TransferStatus.inProgress;
    final isPaused = file.status == TransferStatus.paused;
    final isPending = file.status == TransferStatus.pending;
    final isCancelled = file.status == TransferStatus.cancelled;
    final isFailed = file.status == TransferStatus.failed;

    final localPath = file.localPath;
    final isGalleryCapable = localPath != null && _isGalleryImage(localPath);
    final ext = p.extension(file.fileName).toUpperCase().replaceAll('.', '');

    String statusText;
    Color statusColor = AppColors.textSecondaryOf(context);
    if (isCompleted) {
      statusText = 'Ready to view';
      statusColor = AppColors.success;
    } else if (isInProgress) {
      final pct = (file.progress * 100).toInt();
      statusText = file.speed > 0 ? '$pct% • ${file.formattedSpeed}' : '$pct%';
      statusColor = AppColors.primary;
    } else if (isPaused) {
      final pct = (file.progress * 100).toInt();
      statusText = file.transferredBytes > 0 ? 'Paused • $pct%' : 'Paused';
      statusColor = AppColors.warning;
    } else if (isCancelled) {
      statusText = 'Cancelled';
      statusColor = AppColors.textSecondaryOf(context);
    } else if (isFailed) {
      statusText = file.errorMessage ?? 'Failed';
      statusColor = AppColors.error;
    } else {
      statusText = 'Waiting...';
    }

    final showProgressBar =
        isInProgress || (isPaused && file.transferredBytes > 0);
    final borderColor = isInProgress
        ? AppColors.primary.withValues(alpha: 0.5)
        : isPaused
            ? AppColors.warning.withValues(alpha: 0.5)
            : isFailed
                ? AppColors.error.withValues(alpha: 0.45)
                : AppColors.subtleBorderOf(context);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: isCompleted
            ? () => _openFile(context, file, completedFiles)
            : null,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: AppColors.surfaceOf(context)
                .withValues(alpha: isCompleted ? 0.95 : 0.78),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: borderColor),
          ),
          child: Row(
            children: [
              _buildFileLeadingThumb(file),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      file.fileName,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w700,
                        height: 1.2,
                        color: AppColors.textPrimaryOf(context),
                      ),
                    ),
                    const SizedBox(height: 3),
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: AlignmentDirectional.centerStart,
                      child: Text.rich(
                        TextSpan(
                          children: [
                            TextSpan(
                              text:
                                  '${FileHandler.formatFileSize(file.fileSize)}${ext.isNotEmpty ? ' • $ext' : ''}',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                color: AppColors.textSecondaryOf(context),
                              ),
                            ),
                            const TextSpan(text: '  '),
                            TextSpan(
                              text: statusText,
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                                color: statusColor,
                              ),
                            ),
                          ],
                        ),
                        maxLines: 1,
                        softWrap: false,
                      ),
                    ),
                    if (showProgressBar) ...[
                      const SizedBox(height: 6),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: LinearProgressIndicator(
                          value: file.progress,
                          minHeight: 5,
                          backgroundColor: (isPaused
                                  ? AppColors.warning
                                  : AppColors.primary)
                              .withValues(alpha: 0.14),
                          valueColor: AlwaysStoppedAnimation<Color>(
                            isPaused ? AppColors.warning : AppColors.primary,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 6),
              if (isCompleted) ...[
                IconButton(
                  tooltip: isGalleryCapable ? 'View file' : 'Open file',
                  icon: Icon(
                    isGalleryCapable
                        ? Icons.visibility_rounded
                        : Icons.open_in_new_rounded,
                    color: AppColors.primary,
                    size: 20,
                  ),
                  constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
                  padding: const EdgeInsets.all(6),
                  visualDensity: VisualDensity.compact,
                  onPressed: () => _openFile(context, file, completedFiles),
                ),
                if (isGalleryCapable && MediaQuery.sizeOf(context).width >= 430)
                  IconButton(
                    tooltip: 'Open in default app',
                    icon: Icon(
                      Icons.open_in_new_rounded,
                      color: AppColors.textSecondaryOf(context),
                      size: 18,
                    ),
                    constraints:
                        const BoxConstraints(minWidth: 34, minHeight: 34),
                    padding: const EdgeInsets.all(6),
                    visualDensity: VisualDensity.compact,
                    onPressed: () => _openFile(
                      context,
                      file,
                      completedFiles,
                      forceSystemApp: true,
                    ),
                  ),
                IconButton(
                  tooltip: 'Show in folder',
                  icon: Icon(
                    Icons.folder_open_rounded,
                    color: AppColors.textSecondaryOf(context),
                    size: 20,
                  ),
                  constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
                  padding: const EdgeInsets.all(6),
                  visualDensity: VisualDensity.compact,
                  onPressed: () => _showInFolder(context, file),
                ),
              ] else if (!isIncoming && (isInProgress || isPaused || isPending)) ...[
                IconButton(
                  tooltip: isPaused ? 'Resume file' : 'Pause file',
                  icon: Icon(
                    isPaused ? Icons.play_arrow_rounded : Icons.pause_rounded,
                    color: isPaused ? AppColors.warning : AppColors.primary,
                    size: 19,
                  ),
                  constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                  padding: const EdgeInsets.all(4),
                  visualDensity: VisualDensity.compact,
                  onPressed: () => transProv.togglePauseFile(file.id),
                ),
                IconButton(
                  tooltip: 'Cancel file',
                  icon: const Icon(
                    Icons.close_rounded,
                    color: AppColors.error,
                    size: 19,
                  ),
                  constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                  padding: const EdgeInsets.all(4),
                  visualDensity: VisualDensity.compact,
                  onPressed: () => transProv.cancelFile(file.id),
                ),
              ] else if (isInProgress)
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: AppColors.primary.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    '${(file.progress * 100).toInt()}%',
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                      color: AppColors.primary,
                    ),
                  ),
                )
              else if (isPaused)
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: AppColors.warning.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Text(
                    'Paused',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: AppColors.warning,
                    ),
                  ),
                )
              else if (isCancelled)
                Padding(
                  padding: const EdgeInsets.all(6),
                  child: Icon(
                    Icons.cancel_outlined,
                    color: AppColors.textSecondaryOf(context),
                    size: 20,
                  ),
                )
              else if (isFailed)
                const Padding(
                  padding: EdgeInsets.all(6),
                  child: Icon(
                    Icons.error_rounded,
                    color: AppColors.error,
                    size: 20,
                  ),
                )
              else
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: AppColors.subtleFillOf(context),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    'Waiting',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textSecondaryOf(context),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildFileLeadingThumb(FileTransfer file) {
    final path = file.localPath;
    if (path != null && _isPreviewableImage(path) && File(path).existsSync()) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Image.file(
          File(path),
          width: 48,
          height: 48,
          fit: BoxFit.cover,
          cacheWidth: 120,
          errorBuilder: (_, _, _) => _buildCategoryIconBox(file.fileName),
        ),
      );
    }
    return _buildCategoryIconBox(file.fileName);
  }

  Widget _buildCategoryIconBox(String fileName) {
    final style = _styleForFile(fileName);
    return Container(
      width: 48,
      height: 48,
      decoration: BoxDecoration(
        color: style.color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Icon(style.icon, color: style.color, size: 24),
    );
  }

  // ---------------------------------------------------------------------------
  // Helpers & Actions
  // ---------------------------------------------------------------------------

  String _getAppBarTitle({
    required List<FileTransfer> batch,
    required bool isComplete,
    required bool isPaused,
    required int failedCount,
    required int cancelledCount,
    required bool isIncoming,
  }) {
    if (!isComplete) {
      if (isPaused) return 'Transfer Paused';
      return isIncoming ? 'Receiving Files...' : 'Sending Files...';
    }
    if (cancelledCount == batch.length) {
      return 'Transfer Cancelled';
    }
    if (failedCount == batch.length) {
      return 'Transfer Failed';
    }
    return 'Transfer Complete';
  }

  String _getSummaryHeadline({
    required TransferProvider transProv,
    required List<FileTransfer> batch,
    required bool isComplete,
    required bool isIncoming,
    required int completedCount,
    required int failedCount,
  }) {
    if (!isComplete) {
      if (transProv.isBatchPaused) {
        return batch.length == 1 ? batch.first.fileName : 'Transfer Paused';
      }
      if (batch.length == 1) {
        return batch.first.fileName;
      }
      final currentIndex =
          (completedCount + 1).clamp(1, batch.length);
      return '${isIncoming ? 'Receiving' : 'Sending'} $currentIndex of ${batch.length}...';
    }

    if (transProv.cancelledBatchCount == batch.length) {
      return batch.length > 1
          ? '${batch.length} Files Cancelled'
          : 'Transfer Cancelled';
    }
    if (failedCount == batch.length) {
      return batch.length > 1
          ? '$failedCount Files Failed'
          : 'Transfer Failed';
    }
    if (failedCount > 0) {
      return '$completedCount of ${batch.length} Complete';
    }
    if (batch.length == 1) {
      return isIncoming ? 'File Received' : 'File Sent';
    }
    return '${batch.length} Files ${isIncoming ? 'Received' : 'Sent'}';
  }

  bool _isPreviewableImage(String path) {
    final ext = p.extension(path).toLowerCase();
    return const ['.jpg', '.jpeg', '.png', '.webp', '.gif', '.bmp']
        .contains(ext);
  }

  bool _isGalleryImage(String path) {
    final ext = p.extension(path).toLowerCase();
    return const ['.jpg', '.jpeg', '.png', '.webp', '.gif', '.bmp', '.heic']
        .contains(ext);
  }

  List<LocalItem> _toLocalItems(List<FileTransfer> files) {
    final items = <LocalItem>[];
    for (final t in files) {
      final path = t.localPath;
      if (path == null) continue;
      final file = File(path);
      if (!file.existsSync()) continue;
      items.add(
        LocalItem(
          path: path,
          name: p.basename(path),
          size: t.fileSize > 0 ? t.fileSize : file.lengthSync(),
          modified: t.createdAt,
          isDirectory: false,
          extension: p.extension(path).toLowerCase(),
        ),
      );
    }
    return items;
  }

  void _openFile(
    BuildContext context,
    FileTransfer file,
    List<FileTransfer> completedFiles, {
    bool forceSystemApp = false,
  }) {
    final path = file.localPath;
    if (path == null || !File(path).existsSync()) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('File is not available on disk'),
          backgroundColor: AppColors.error,
        ),
      );
      return;
    }

    if (!forceSystemApp && _isGalleryImage(path)) {
      final items = _toLocalItems(completedFiles);
      final initialIndex = items.indexWhere((it) => it.path == path);
      if (items.isNotEmpty && initialIndex >= 0) {
        MediaViewerModal.show(
          context,
          item: items[initialIndex],
          items: items,
          initialIndex: initialIndex,
        );
        return;
      }
      final f = File(path);
      MediaViewerModal.show(
        context,
        item: LocalItem(
          path: path,
          name: p.basename(path),
          size: file.fileSize > 0 ? file.fileSize : f.lengthSync(),
          modified: file.createdAt,
          isDirectory: false,
          extension: p.extension(path).toLowerCase(),
        ),
      );
      return;
    }

    FileHandler.openFile(path);
  }

  void _openGallery(
    BuildContext context,
    List<FileTransfer> completedFiles,
  ) {
    final items = _toLocalItems(completedFiles);
    if (items.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Files are not available on disk'),
          backgroundColor: AppColors.error,
        ),
      );
      return;
    }
    var initialIndex = items.indexWhere((it) => it.isImage);
    if (initialIndex < 0) initialIndex = 0;

    MediaViewerModal.show(
      context,
      item: items[initialIndex],
      items: items,
      initialIndex: initialIndex,
    );
  }

  void _showInFolder(BuildContext context, FileTransfer file) {
    FileHandler.openFolderChoice(context, filePath: file.localPath);
  }

  _FileCategoryStyle _styleForFile(String fileName) {
    final ext = p.extension(fileName).toLowerCase();
    if (const ['.jpg', '.jpeg', '.png', '.gif', '.webp', '.heic', '.bmp', '.svg']
        .contains(ext)) {
      return const _FileCategoryStyle(Icons.image_rounded, AppColors.primary);
    }
    if (const ['.mp4', '.mkv', '.mov', '.avi', '.3gp', '.webm', '.flv']
        .contains(ext)) {
      return const _FileCategoryStyle(
        Icons.video_file_rounded,
        Colors.pinkAccent,
      );
    }
    if (const ['.mp3', '.m4a', '.wav', '.flac', '.aac', '.ogg', '.opus']
        .contains(ext)) {
      return const _FileCategoryStyle(
        Icons.audio_file_rounded,
        Colors.orange,
      );
    }
    if (ext == '.pdf') {
      return const _FileCategoryStyle(
        Icons.picture_as_pdf_rounded,
        Colors.redAccent,
      );
    }
    if (const ['.zip', '.rar', '.7z', '.tar', '.gz'].contains(ext)) {
      return const _FileCategoryStyle(
        Icons.folder_zip_rounded,
        Colors.deepPurple,
      );
    }
    if (const ['.doc', '.docx', '.xls', '.xlsx', '.ppt', '.pptx', '.txt', '.csv']
        .contains(ext)) {
      return const _FileCategoryStyle(
        Icons.description_rounded,
        Colors.blueAccent,
      );
    }
    return const _FileCategoryStyle(
      Icons.insert_drive_file_rounded,
      AppColors.primary,
    );
  }
}

class _FileCategoryStyle {
  final IconData icon;
  final Color color;

  const _FileCategoryStyle(this.icon, this.color);
}
