import 'dart:io';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../config/constants.dart';
import '../services/file_handler.dart';
import '../services/local_storage_service.dart';

/// Fullscreen in-app media previewer for images and files.
/// Features interactive pinch/wheel zoom, pan physics, multi-item gallery browsing,
/// keyboard navigation (Left/Right/Escape), and quick actions.
class MediaViewerModal extends StatefulWidget {
  final LocalItem item;
  final List<LocalItem>? items;
  final int initialIndex;
  final VoidCallback? onShare;

  const MediaViewerModal({
    super.key,
    required this.item,
    this.items,
    this.initialIndex = 0,
    this.onShare,
  });

  /// Displays the media viewer as a full-screen frosted glass overlay.
  static Future<void> show(
    BuildContext context, {
    required LocalItem item,
    List<LocalItem>? items,
    int initialIndex = 0,
    VoidCallback? onShare,
  }) {
    return showDialog(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.85),
      useSafeArea: false,
      builder: (ctx) => MediaViewerModal(
        item: item,
        items: items,
        initialIndex: initialIndex,
        onShare: onShare,
      ),
    );
  }

  @override
  State<MediaViewerModal> createState() => _MediaViewerModalState();
}

class _MediaViewerModalState extends State<MediaViewerModal> {
  late int _currentIndex;

  List<LocalItem> get _effectiveItems {
    final list = widget.items;
    if (list != null && list.isNotEmpty) {
      return list;
    }
    return [widget.item];
  }

  LocalItem get _currentItem {
    final items = _effectiveItems;
    final idx = _currentIndex.clamp(0, items.length - 1);
    return items[idx];
  }

  @override
  void initState() {
    super.initState();
    final len = _effectiveItems.length;
    _currentIndex = widget.initialIndex.clamp(0, len - 1);
  }

  void _goPrevious() {
    if (_currentIndex > 0) {
      setState(() {
        _currentIndex--;
      });
    }
  }

  void _goNext() {
    if (_currentIndex < _effectiveItems.length - 1) {
      setState(() {
        _currentIndex++;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final items = _effectiveItems;
    final currentItem = _currentItem;
    final isImg = currentItem.isImage;
    final hasMultiple = items.length > 1;

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.arrowLeft): _goPrevious,
        const SingleActivator(LogicalKeyboardKey.arrowRight): _goNext,
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            Navigator.of(context).pop(),
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          backgroundColor: Colors.transparent,
          body: Stack(
            children: [
              // 1. Frosted Ambient Background
              Positioned.fill(
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
                  child: Container(
                    color: Colors.black.withValues(alpha: 0.65),
                  ),
                ),
              ),

              // 2. Interactive Media Content
              Center(
                child: isImg
                    ? _buildInteractiveImage(currentItem)
                    : _buildNonImagePreview(context, currentItem),
              ),

              // 3. Left / Right Navigation Arrows for Multi-File Viewing
              if (hasMultiple && _currentIndex > 0)
                Align(
                  alignment: Alignment.centerLeft,
                  child: Padding(
                    padding: const EdgeInsets.only(left: 16),
                    child: _buildGlassCircleButton(
                      icon: Icons.chevron_left_rounded,
                      iconSize: 28,
                      padding: 12,
                      tooltip: 'Previous file (Left Arrow)',
                      onTap: _goPrevious,
                    ),
                  ),
                ),
              if (hasMultiple && _currentIndex < items.length - 1)
                Align(
                  alignment: Alignment.centerRight,
                  child: Padding(
                    padding: const EdgeInsets.only(right: 16),
                    child: _buildGlassCircleButton(
                      icon: Icons.chevron_right_rounded,
                      iconSize: 28,
                      padding: 12,
                      tooltip: 'Next file (Right Arrow)',
                      onTap: _goNext,
                    ),
                  ),
                ),

              // 4. Top Floating Glass App Bar
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 12,
                    ),
                    child: Row(
                      children: [
                        // Close Button
                        _buildGlassCircleButton(
                          icon: Icons.close_rounded,
                          tooltip: 'Close (Esc)',
                          onTap: () => Navigator.of(context).pop(),
                        ),
                        const SizedBox(width: 14),

                        // File Title & Size
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                currentItem.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 15,
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: 0.2,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                currentItem.formattedSize,
                                style: TextStyle(
                                  color: Colors.white.withValues(alpha: 0.7),
                                  fontSize: 12,
                                  fontWeight: FontWeight.w400,
                                ),
                              ),
                            ],
                          ),
                        ),

                        // Multi-file Counter Pill
                        if (hasMultiple) ...[
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 6,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.16),
                              borderRadius: BorderRadius.circular(20),
                              border: Border.all(
                                color: Colors.white.withValues(alpha: 0.25),
                                width: 1,
                              ),
                            ),
                            child: Text(
                              '${_currentIndex + 1} / ${items.length}',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                        ],

                        // Share via SendSnap Button
                        if (widget.onShare != null) ...[
                          _buildGlassCircleButton(
                            icon: Icons.send_rounded,
                            tooltip: 'Share via SendSnap',
                            onTap: () {
                              Navigator.of(context).pop();
                              widget.onShare?.call();
                            },
                          ),
                          const SizedBox(width: 10),
                        ],

                        // Show in Folder Button
                        _buildGlassCircleButton(
                          icon: Icons.folder_open_rounded,
                          tooltip: 'Show in Folder',
                          onTap: () => FileHandler.openFolderChoice(
                            context,
                            filePath: currentItem.path,
                          ),
                        ),
                        const SizedBox(width: 10),

                        // Open with System Default App
                        _buildGlassCircleButton(
                          icon: Icons.open_in_new_rounded,
                          tooltip: 'Open with default app',
                          onTap: () => FileHandler.openFile(currentItem.path),
                        ),
                      ],
                    ),
                  ),
                ),
              ),

              // 5. Bottom Hint Pill for Images
              if (isImg)
                Positioned(
                  bottom: 24,
                  left: 0,
                  right: 0,
                  child: SafeArea(
                    child: Center(
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(
                            color: Colors.white.withValues(alpha: 0.2),
                            width: 1,
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.pinch_rounded,
                              size: 14,
                              color: Colors.white.withValues(alpha: 0.8),
                            ),
                            const SizedBox(width: 6),
                            Text(
                              hasMultiple
                                  ? 'Pinch or scroll to zoom • Use arrows to browse'
                                  : 'Pinch or scroll to zoom',
                              style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.8),
                                fontSize: 11,
                                fontWeight: FontWeight.w500,
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
        ),
      ),
    );
  }

  Widget _buildInteractiveImage(LocalItem item) {
    return InteractiveViewer(
      key: ValueKey(item.path),
      minScale: 0.5,
      maxScale: 5.0,
      panEnabled: true,
      scaleEnabled: true,
      child: Image.file(
        File(item.path),
        fit: BoxFit.contain,
        errorBuilder: (context, error, stackTrace) => Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.broken_image_rounded, size: 64, color: Colors.white54),
            const SizedBox(height: 12),
            Text(
              'Could not load image preview',
              style: TextStyle(color: Colors.white.withValues(alpha: 0.8)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildNonImagePreview(BuildContext context, LocalItem item) {
    IconData icon = Icons.insert_drive_file_rounded;
    Color iconColor = AppColors.primary;

    if (item.isVideo) {
      icon = Icons.video_file_rounded;
      iconColor = Colors.pinkAccent;
    } else if (item.isAudio) {
      icon = Icons.audio_file_rounded;
      iconColor = Colors.amber;
    } else if (item.isDocument) {
      icon = Icons.description_rounded;
      iconColor = Colors.blueAccent;
    }

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 32),
      padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 36),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(32),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.25),
          width: 1.5,
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: iconColor.withValues(alpha: 0.2),
              border: Border.all(
                color: iconColor.withValues(alpha: 0.4),
                width: 2,
              ),
            ),
            child: Icon(icon, size: 54, color: iconColor),
          ),
          const SizedBox(height: 20),
          Text(
            item.name,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '${item.extension.toUpperCase().replaceAll('.', '')} • ${item.formattedSize}',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.7),
              fontSize: 13,
            ),
          ),
          const SizedBox(height: 24),
          Wrap(
            spacing: 12,
            runSpacing: 12,
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
                    horizontal: 24,
                    vertical: 14,
                  ),
                ),
                icon: const Icon(Icons.open_in_new_rounded, size: 18),
                label: const Text(
                  'Open with System App',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                onPressed: () => FileHandler.openFile(item.path),
              ),
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.white,
                  side: BorderSide(color: Colors.white.withValues(alpha: 0.35)),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 14,
                  ),
                ),
                icon: const Icon(Icons.folder_open_rounded, size: 18),
                label: const Text(
                  'Show in Folder',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                onPressed: () => FileHandler.openFolderChoice(
                  context,
                  filePath: item.path,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildGlassCircleButton({
    required IconData icon,
    required VoidCallback onTap,
    String? tooltip,
    double iconSize = 20,
    double padding = 10,
  }) {
    Widget btn = GestureDetector(
      onTap: onTap,
      child: Container(
        padding: EdgeInsets.all(padding),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.15),
          shape: BoxShape.circle,
          border: Border.all(
            color: Colors.white.withValues(alpha: 0.25),
            width: 1,
          ),
        ),
        child: Icon(icon, color: Colors.white, size: iconSize),
      ),
    );

    if (tooltip != null) {
      return Tooltip(message: tooltip, child: btn);
    }
    return btn;
  }
}
