import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../config/constants.dart';
import '../services/file_handler.dart';
import '../services/local_storage_service.dart';
import '../services/ecosystem_service.dart';
import '../widgets/ambient_background.dart';
import '../widgets/bouncing_card.dart';
import '../widgets/glass_container.dart';
import '../widgets/media_viewer_modal.dart';
import '../l10n/app_localizations.dart';

class ReceivedFilesScreen extends StatefulWidget {
  const ReceivedFilesScreen({super.key});

  @override
  State<ReceivedFilesScreen> createState() => _ReceivedFilesScreenState();
}

class _ReceivedFilesScreenState extends State<ReceivedFilesScreen> {
  List<LocalItem> _files = [];
  bool _isLoading = true;
  String _searchQuery = '';
  final TextEditingController _searchCtrl = TextEditingController();

  bool _isPagelitInstalled = false;
  bool _dismissedPagelitBanner = false;

  @override
  void initState() {
    super.initState();
    _loadReceivedFiles();

    EcosystemService.isPagelitInstalled().then((installed) {
      if (mounted) setState(() => _isPagelitInstalled = installed);
    });
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadReceivedFiles() async {
    setState(() => _isLoading = true);
    final items = await LocalStorageService.getItems(category: StorageCategory.received);
    if (mounted) {
      setState(() {
        _files = items.where((i) => !i.isDirectory).toList();
        _isLoading = false;
      });
    }
  }

  Future<void> _deleteFile(LocalItem item) async {
    final l10n = AppLocalizations.of(context)!;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surfaceOf(ctx),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(color: AppColors.inkOf(ctx), width: 1.6),
        ),
        title: Text(
          l10n.receivedDeleteTitle,
          style: TextStyle(fontWeight: FontWeight.w700, color: AppColors.textPrimaryOf(ctx)),
        ),
        content: Text(
          l10n.receivedDeleteConfirm(item.name),
          style: TextStyle(color: AppColors.textSecondaryOf(ctx)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(l10n.actionCancel),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.error,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(l10n.actionDelete, style: const TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );

    if (confirm == true) {
      try {
        final f = File(item.path);
        if (await f.exists()) {
          await f.delete();
        }
        _loadReceivedFiles();

        EcosystemService.isPagelitInstalled().then((installed) {
          if (mounted) setState(() => _isPagelitInstalled = installed);
        });
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Error deleting file: $e'), backgroundColor: AppColors.error),
          );
        }
      }
    }
  }

  int get _totalBytes => _files.fold(0, (acc, item) => acc + item.size);

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final isRtl = Directionality.of(context) == TextDirection.rtl;

    final filtered = _searchQuery.isEmpty
        ? _files
        : _files.where((f) => f.name.toLowerCase().contains(_searchQuery.toLowerCase())).toList();

    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.space): () {
          if (filtered.isNotEmpty) {
            _openItem(filtered.first);
          }
        },
        const SingleActivator(LogicalKeyboardKey.escape): () {
          Navigator.of(context).pop();
        },
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          backgroundColor: Colors.transparent,
          body: AmbientBackground(
            child: SafeArea(
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 600),
                  child: Column(
                    children: [
                      _buildHeader(context, l10n, isRtl),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                        child: _buildSearchBar(l10n),
                      ),
                      if (!_isPagelitInstalled && !_dismissedPagelitBanner && _files.any((f) => f.isDocument))
                        _buildPagelitCompanionBanner(),
                      Expanded(
                        child: _isLoading
                            ? const Center(child: CircularProgressIndicator())
                            : filtered.isEmpty
                                ? _buildEmptyState(l10n)
                                : ListView.separated(
                                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                                    itemCount: filtered.length,
                                    separatorBuilder: (ctx, idx) => const SizedBox(height: 8),
                                    itemBuilder: (context, index) {
                                      return _buildFileCard(filtered[index], l10n);
                                    },
                                  ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context, AppLocalizations l10n, bool isRtl) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Row(
        children: [
          BouncingCard(
            onTap: () => Navigator.of(context).pop(),
            child: Container(
              padding: const EdgeInsets.all(10),
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
              child: Transform.flip(
                flipX: isRtl,
                child: Icon(Icons.arrow_back_rounded, size: 20, color: AppColors.textPrimaryOf(context)),
              ),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l10n.receivedTitle,
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.5,
                    color: AppColors.textPrimaryOf(context),
                  ),
                ),
                Text(
                  '${l10n.homeFilesCount(_files.length)} • ${FileHandler.formatFileSize(_totalBytes)}',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: AppColors.textSecondaryOf(context)),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: l10n.receivedOpenFolder,
            icon: const Icon(Icons.folder_open_rounded, color: AppColors.primary),
            onPressed: () => FileHandler.openFolderChoice(context),
          ),
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh_rounded, color: AppColors.primary),
            onPressed: _loadReceivedFiles,
          ),
        ],
      ),
    );
  }

  Widget _buildSearchBar(AppLocalizations l10n) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surfaceOf(context),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.subtleBorderOf(context), width: 1.2),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 14),
      child: TextField(
        controller: _searchCtrl,
        onChanged: (val) => setState(() => _searchQuery = val.trim()),
        style: TextStyle(fontSize: 14, color: AppColors.textPrimaryOf(context)),
        decoration: InputDecoration(
          icon: Icon(Icons.search_rounded, size: 20, color: AppColors.textSecondaryOf(context)),
          hintText: l10n.receivedSearchHint,
          hintStyle: TextStyle(color: AppColors.textSecondaryOf(context).withValues(alpha: 0.75), fontSize: 14),
          border: InputBorder.none,
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(vertical: 12),
          suffixIcon: _searchQuery.isNotEmpty
              ? IconButton(
                  icon: Icon(Icons.clear_rounded, size: 18, color: AppColors.textSecondaryOf(context)),
                  onPressed: () {
                    _searchCtrl.clear();
                    setState(() => _searchQuery = '');
                  },
                )
              : null,
        ),
      ),
    );
  }

  Widget _buildFileCard(LocalItem item, AppLocalizations l10n) {
    return GestureDetector(
      onTap: () => _openItem(item),
      child: GlassContainer(
        blur: 0,
        opacity: 0.85,
        borderRadius: 18,
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            _buildLeading(item),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: AppColors.textPrimaryOf(context),
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    '${item.formattedSize} • ${_formatDate(item.modified)}',
                    style: TextStyle(fontSize: 12, color: AppColors.textSecondaryOf(context)),
                  ),
                ],
              ),
            ),
            // Open button
            BouncingCard(
              onTap: () => _openItem(item),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(colors: [AppColors.accent, AppColors.primary]),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.visibility_rounded, size: 14, color: Colors.white),
                    const SizedBox(width: 6),
                    Text(l10n.settingsOpen, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 12)),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 4),
            IconButton(
              tooltip: l10n.receivedOpenFolder,
              icon: Icon(Icons.folder_open_rounded, size: 20, color: AppColors.textSecondaryOf(context)),
              onPressed: () => FileHandler.openFolderChoice(context, filePath: item.path),
            ),
            IconButton(
              tooltip: l10n.actionDelete,
              icon: const Icon(Icons.delete_outline_rounded, size: 20, color: AppColors.error),
              onPressed: () => _deleteFile(item),
            ),
          ],
        ),
      ),
    );
  }

  void _openItem(LocalItem item) {
    if (item.isImage) {
      MediaViewerModal.show(context, item: item);
    } else {
      FileHandler.openFile(item.path);
    }
  }

  Widget _buildLeading(LocalItem item) {
    if (item.isImage) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: SizedBox(
          width: 44,
          height: 44,
          child: Image.file(
            File(item.path),
            fit: BoxFit.cover,
            errorBuilder: (context, error, stackTrace) => _buildFallbackIcon(item),
          ),
        ),
      );
    }
    return _buildFallbackIcon(item);
  }

  Widget _buildFallbackIcon(LocalItem item) {
    final IconData icon;
    final Color fg;
    final Color bg;
    final ext = item.extension.toLowerCase();
    final isArchive = const ['.zip', '.rar', '.7z', '.tar', '.gz'].contains(ext);

    if (item.isVideo) {
      icon = Icons.movie_rounded;
      fg = const Color(0xFFFF9500);
      bg = const Color(0xFFFF9500).withValues(alpha: 0.12);
    } else if (item.isAudio) {
      icon = Icons.music_note_rounded;
      fg = const Color(0xFFAF52DE);
      bg = const Color(0xFFAF52DE).withValues(alpha: 0.12);
    } else if (isArchive) {
      icon = Icons.folder_zip_rounded;
      fg = const Color(0xFFFF2D55);
      bg = const Color(0xFFFF2D55).withValues(alpha: 0.12);
    } else if (item.isDocument) {
      icon = Icons.description_rounded;
      fg = const Color(0xFF007AFF);
      bg = const Color(0xFF007AFF).withValues(alpha: 0.12);
    } else {
      icon = Icons.insert_drive_file_rounded;
      fg = AppColors.textSecondaryOf(context);
      bg = AppColors.subtleFillOf(context);
    }

    return Container(
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Icon(icon, color: fg, size: 22),
    );
  }

  Widget _buildEmptyState(AppLocalizations l10n) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: GlassContainer(
          blur: 24,
          opacity: 0.85,
          borderRadius: 28,
          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 36),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.04),
              blurRadius: 20,
              offset: const Offset(0, 6),
            ),
          ],
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Glowing Ambient Icon Orb
              Container(
                width: 72,
                height: 72,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      AppColors.primary.withValues(alpha: 0.18),
                      AppColors.accent.withValues(alpha: 0.12),
                    ],
                  ),
                  border: Border.all(
                    color: Colors.white,
                    width: 2,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: AppColors.primary.withValues(alpha: 0.15),
                      blurRadius: 18,
                      offset: const Offset(0, 6),
                    ),
                  ],
                ),
                child: const Center(
                  child: Icon(
                    Icons.folder_open_rounded,
                    size: 34,
                    color: AppColors.primary,
                  ),
                ),
              ),
              const SizedBox(height: 20),

              Text(
                l10n.receivedNoFiles,
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                  color: AppColors.textPrimaryOf(context),
                  letterSpacing: -0.3,
                ),
              ),
              const SizedBox(height: 8),

              Text(
                l10n.receivedNoFilesHint,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 13,
                  color: AppColors.textSecondaryOf(context),
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 24),

              // Action Buttons
              Wrap(
                spacing: 10,
                runSpacing: 10,
                alignment: WrapAlignment.center,
                children: [
                  BouncingCard(
                    onTap: () => Navigator.of(context).pop(),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
                      decoration: BoxDecoration(
                        gradient: AppColors.primaryGradient,
                        borderRadius: BorderRadius.circular(18),
                        boxShadow: [
                          BoxShadow(
                            color: AppColors.primary.withValues(alpha: 0.3),
                            blurRadius: 10,
                            offset: const Offset(0, 4),
                          ),
                        ],
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.download_rounded, size: 16, color: Colors.white),
                          const SizedBox(width: 6),
                          Text(
                            l10n.homeRadarReady,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  BouncingCard(
                    onTap: () => FileHandler.openFolderChoice(context),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                      decoration: BoxDecoration(
                        color: AppColors.subtleFillOf(context),
                        borderRadius: BorderRadius.circular(18),
                        border: Border.all(color: AppColors.subtleBorderOf(context)),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.folder_open_rounded, size: 16, color: AppColors.primary),
                          const SizedBox(width: 6),
                          Text(
                            l10n.receivedOpenFolder,
                            style: const TextStyle(
                              color: AppColors.primary,
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  BouncingCard(
                    onTap: _loadReceivedFiles,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                      decoration: BoxDecoration(
                        color: AppColors.subtleFillOf(context),
                        borderRadius: BorderRadius.circular(18),
                        border: Border.all(color: AppColors.subtleBorderOf(context)),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.refresh_rounded, size: 16, color: AppColors.textSecondaryOf(context)),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _formatDate(DateTime dt) {
    return '${dt.day}/${dt.month}/${dt.year} ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }

  Widget _buildPagelitCompanionBanner() {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surfaceOf(context),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFFFF6B6B).withValues(alpha: 0.35)),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFFFF6B6B).withValues(alpha: 0.08),
            blurRadius: 10,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(9),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [Color(0xFFFF6B6B), Color(0xFFFF8E53)],
              ),
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Icon(Icons.auto_stories_rounded, color: Colors.white, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      'Read in Pagelit',
                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: AppColors.textPrimaryOf(context)),
                    ),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        'by The 356 Company',
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: AppColors.textSecondaryOf(context)),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  'Distraction-free reader for your received PDF, Word & Office files',
                  style: TextStyle(fontSize: 11, color: AppColors.textSecondaryOf(context)),
                ),
              ],
            ),
          ),
          BouncingCard(
            onTap: () => EcosystemService.openPagelitStore(),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [Color(0xFFFF6B6B), Color(0xFFFF8E53)],
                ),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Text(
                'Get App',
                style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 11),
              ),
            ),
          ),
          const SizedBox(width: 6),
          IconButton(
            icon: Icon(Icons.close_rounded, size: 16, color: AppColors.textSecondaryOf(context)),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
            onPressed: () => setState(() => _dismissedPagelitBanner = true),
          ),
        ],
      ),
    );
  }
}
