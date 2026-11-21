import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import '../config/constants.dart';
import '../services/local_storage_service.dart';
import '../services/permission_service.dart';
import '../services/file_handler.dart';
import 'bouncing_card.dart';
import 'glass_container.dart';

class InAppFilePickerSheet extends StatefulWidget {
  final bool allowMultiple;
  final StorageCategory initialCategory;

  const InAppFilePickerSheet({
    super.key,
    this.allowMultiple = true,
    this.initialCategory = StorageCategory.recent,
  });

  /// Opens the picker sheet as a full-height modal and returns selected Files.
  static Future<List<File>?> show(
    BuildContext context, {
    bool allowMultiple = true,
    StorageCategory initialCategory = StorageCategory.recent,
  }) {
    return showModalBottomSheet<List<File>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => InAppFilePickerSheet(
        allowMultiple: allowMultiple,
        initialCategory: initialCategory,
      ),
    );
  }

  @override
  State<InAppFilePickerSheet> createState() => _InAppFilePickerSheetState();
}

class _InAppFilePickerSheetState extends State<InAppFilePickerSheet> {
  late StorageCategory _selectedCategory;
  final TextEditingController _searchController = TextEditingController();
  final Set<String> _selectedPaths = {};
  final Map<String, LocalItem> _selectedItems = {};

  List<LocalItem> _items = [];
  bool _isLoading = true;
  bool _isPreparingFiles = false;
  String _searchQuery = '';

  // Folder navigation inside StorageCategory.files
  String? _currentDirPath;
  final List<String> _dirHistory = [];

  final PermissionService _permService = PermissionService();
  bool _hasFullStorageAccess = true;

  @override
  void initState() {
    super.initState();
    _selectedCategory = widget.initialCategory;
    _checkPermissionsAndLoad();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _checkPermissionsAndLoad() async {
    final granted = await _permService.hasManageExternalStoragePermission();
    if (mounted) {
      setState(() {
        _hasFullStorageAccess = granted;
      });
      _loadCategory(_selectedCategory);
    }
  }

  Future<void> _openSystemPicker() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        allowMultiple: widget.allowMultiple,
        type: FileType.any,
      );
      if (result != null && result.paths.isNotEmpty) {
        final files = result.paths
            .whereType<String>()
            .map((p) => File(p))
            .where((f) => f.existsSync())
            .toList();
        if (files.isNotEmpty && mounted) {
          Navigator.of(context).pop(files);
        }
      }
    } catch (e) {
      debugPrint('[InAppFilePickerSheet] Error opening system picker: $e');
    }
  }

  Future<void> _loadCategory(StorageCategory category, {String? targetDir}) async {
    setState(() {
      _isLoading = true;
      _selectedCategory = category;
      if (targetDir != null) {
        _currentDirPath = targetDir;
      }
    });

    final list = await LocalStorageService.getItems(
      category: category,
      currentDirectoryPath: _currentDirPath,
    );

    if (mounted) {
      setState(() {
        _items = list;
        _isLoading = false;
      });
    }
  }

  void _onCategorySelected(StorageCategory category) {
    if (_selectedCategory == category && category != StorageCategory.files) return;
    _dirHistory.clear();
    _currentDirPath = null;
    _searchController.clear();
    _searchQuery = '';
    _loadCategory(category);
  }

  void _enterDirectory(String dirPath) {
    if (_currentDirPath != null) {
      _dirHistory.add(_currentDirPath!);
    }
    _currentDirPath = dirPath;
    _loadCategory(StorageCategory.files, targetDir: dirPath);
  }

  void _navigateUp() {
    if (_dirHistory.isNotEmpty) {
      final prev = _dirHistory.removeLast();
      _currentDirPath = prev;
      _loadCategory(StorageCategory.files, targetDir: prev);
    } else {
      _currentDirPath = null;
      _loadCategory(StorageCategory.files);
    }
  }

  void _toggleSelect(LocalItem item) {
    setState(() {
      if (!widget.allowMultiple) {
        _selectedPaths.clear();
        _selectedItems.clear();
        _selectedPaths.add(item.path);
        _selectedItems[item.path] = item;
      } else {
        if (_selectedPaths.contains(item.path)) {
          _selectedPaths.remove(item.path);
          _selectedItems.remove(item.path);
        } else {
          _selectedPaths.add(item.path);
          _selectedItems[item.path] = item;
        }
      }
    });
  }

  int _calculateTotalSelectedSize() {
    int total = 0;
    for (final pth in _selectedPaths) {
      final selectedItem = _selectedItems[pth];
      if (selectedItem != null) {
        total += selectedItem.size;
        continue;
      }
      final matching = _items.where((i) => i.path == pth);
      if (matching.isNotEmpty) {
        total += matching.first.size;
      } else {
        try {
          final f = File(pth);
          if (f.existsSync()) {
            total += f.lengthSync();
          }
        } catch (_) {}
      }
    }
    return total;
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final totalBytes = _calculateTotalSelectedSize();

    // Filter by search query
    final filteredItems = _searchQuery.isEmpty
        ? _items
        : _items
            .where((i) =>
                i.name.toLowerCase().contains(_searchQuery.toLowerCase()) ||
                (i.packageName?.toLowerCase().contains(_searchQuery.toLowerCase()) ??
                    false))
            .toList();

    return Container(
      height: size.height * 0.88,
      decoration: BoxDecoration(
        color: AppColors.backgroundOf(context),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(32)),
        border: Border(
          top: BorderSide(color: AppColors.inkOf(context), width: 2.0),
          left: BorderSide(color: AppColors.inkOf(context), width: 1.5),
          right: BorderSide(color: AppColors.inkOf(context), width: 1.5),
        ),
        boxShadow: const [
          BoxShadow(
            color: Colors.black26,
            blurRadius: 30,
            offset: Offset(0, -6),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(30)),
        child: Column(
          children: [
            // Drag handle & Header
            _buildHeader(context),

            // Search Bar
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              child: _buildSearchBar(),
            ),

            // Category Chips
            _buildCategoryTabs(),

            // Storage Permission Warning Banner if missing
            if (!_hasFullStorageAccess &&
                (_selectedCategory == StorageCategory.files ||
                    _selectedCategory == StorageCategory.archives))
              _buildPermissionBanner(),

            // Breadcrumb if in folder view
            if (_selectedCategory == StorageCategory.files && _currentDirPath != null)
              _buildBreadcrumbs(),

            // Item List
            Expanded(
              child: _isLoading
                  ? const Center(child: CircularProgressIndicator())
                  : filteredItems.isEmpty
                      ? _buildEmptyState()
                      : ListView.separated(
                          physics: const BouncingScrollPhysics(),
                          cacheExtent: 350,
                          padding: const EdgeInsets.fromLTRB(16, 8, 16, 100),
                          itemCount: filteredItems.length,
                          separatorBuilder: (ctx, idx) => const SizedBox(height: 6),
                          itemBuilder: (context, index) {
                            final item = filteredItems[index];
                            final isSelected = _selectedPaths.contains(item.path);
                            return _buildItemRow(item, isSelected);
                          },
                        ),
            ),

            // Floating Selection Action Bar
            if (_selectedPaths.isNotEmpty)
              _buildBottomBar(totalBytes),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 12, 12, 8),
      child: Column(
        children: [
          // Drag pill
          Center(
            child: Container(
              width: 38,
              height: 4,
              decoration: BoxDecoration(
                color: AppColors.textSecondaryOf(context).withValues(alpha: 0.4),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              const Icon(Icons.folder_copy_rounded, color: AppColors.primary, size: 22),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Choose Files',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 19,
                    fontWeight: FontWeight.w800,
                    color: AppColors.textPrimaryOf(context),
                    letterSpacing: -0.4,
                  ),
                ),
              ),
              const SizedBox(width: 6),
              BouncingCard(
                onTap: _openSystemPicker,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
                  decoration: BoxDecoration(
                    color: AppColors.primary.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: AppColors.primary.withValues(alpha: 0.45),
                      width: 1.4,
                    ),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.folder_open_rounded, color: AppColors.primary, size: 16),
                      SizedBox(width: 5),
                      Text(
                        'Any File',
                        style: TextStyle(
                          color: AppColors.primary,
                          fontSize: 12,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              IconButton(
                icon: Icon(Icons.close_rounded, color: AppColors.textSecondaryOf(context)),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildSearchBar() {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surfaceOf(context),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.subtleBorderOf(context), width: 1.2),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 14),
      child: TextField(
        controller: _searchController,
        onChanged: (val) => setState(() => _searchQuery = val.trim()),
        style: TextStyle(fontSize: 14, color: AppColors.textPrimaryOf(context)),
        decoration: InputDecoration(
          icon: Icon(Icons.search_rounded, size: 20, color: AppColors.textSecondaryOf(context)),
          hintText: _selectedCategory == StorageCategory.apps
              ? 'Search installed apps or APKs...'
              : 'Filter files in this tab...',
          hintStyle: TextStyle(
            color: AppColors.textSecondaryOf(context).withValues(alpha: 0.75),
            fontSize: 14,
          ),
          border: InputBorder.none,
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(vertical: 12),
          suffixIcon: _searchQuery.isNotEmpty
              ? IconButton(
                  icon: Icon(Icons.clear_rounded, size: 18, color: AppColors.textSecondaryOf(context)),
                  onPressed: () {
                    _searchController.clear();
                    setState(() => _searchQuery = '');
                  },
                )
              : null,
        ),
      ),
    );
  }

  Widget _buildCategoryTabs() {
    final categories = [
      (StorageCategory.recent, 'Recent', Icons.schedule_rounded),
      (StorageCategory.apps, 'Apps', Icons.apps_rounded),
      (StorageCategory.downloads, 'Downloads', Icons.download_rounded),
      (StorageCategory.photos, 'Photos', Icons.photo_library_rounded),
      (StorageCategory.videos, 'Videos', Icons.movie_creation_rounded),
      (StorageCategory.audio, 'Audio', Icons.music_note_rounded),
      (StorageCategory.documents, 'Docs', Icons.description_rounded),
      (StorageCategory.archives, 'Archives', Icons.folder_zip_rounded),
      (StorageCategory.received, 'Received', Icons.cloud_download_rounded),
      (StorageCategory.files, 'Storage', Icons.phone_android_rounded),
    ];

    return Container(
      height: 48,
      margin: const EdgeInsets.only(top: 6, bottom: 4),
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        scrollDirection: Axis.horizontal,
        itemCount: categories.length,
        separatorBuilder: (ctx, idx) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final cat = categories[index];
          final isSelected = _selectedCategory == cat.$1;

          return BouncingCard(
            onTap: () => _onCategorySelected(cat.$1),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: BoxDecoration(
                gradient: isSelected ? AppColors.primaryGradient : null,
                color: isSelected ? null : AppColors.surfaceOf(context),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: isSelected ? AppColors.inkOf(context) : AppColors.subtleBorderOf(context),
                  width: isSelected ? 1.6 : 1.0,
                ),
                boxShadow: isSelected
                    ? [
                        BoxShadow(
                          color: AppColors.primary.withValues(alpha: 0.25),
                          blurRadius: 8,
                          offset: const Offset(0, 3),
                        )
                      ]
                    : null,
              ),
              child: Row(
                children: [
                  Icon(
                    cat.$3,
                    size: 16,
                    color: isSelected ? Colors.white : AppColors.textSecondaryOf(context),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    cat.$2,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: isSelected ? FontWeight.w700 : FontWeight.w600,
                      color: isSelected ? Colors.white : AppColors.textPrimaryOf(context),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildBreadcrumbs() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: AppColors.surfaceOf(context).withValues(alpha: 0.7),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_upward_rounded, size: 20, color: AppColors.primary),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
            onPressed: _navigateUp,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _currentDirPath ?? '',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: AppColors.textSecondaryOf(context),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPermissionBanner() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.warning.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.warning.withValues(alpha: 0.35)),
      ),
      child: Row(
        children: [
          const Icon(Icons.folder_special_rounded, color: AppColors.warning, size: 24),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Grant All Files Access to browse all phone subfolders & extensions.',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: AppColors.textPrimaryOf(context),
              ),
            ),
          ),
          TextButton(
            onPressed: () async {
              await _permService.requestStorageManagementIfNeeded();
              _checkPermissionsAndLoad();
            },
            child: const Text('Grant', style: TextStyle(fontWeight: FontWeight.w700, color: AppColors.warning)),
          ),
        ],
      ),
    );
  }

  Widget _buildItemRow(LocalItem item, bool isSelected) {
    final secondaryColor = AppColors.textSecondaryOf(context);
    final subtitle = item.isDirectory
        ? 'Folder'
        : item.isInstalledApp
            ? 'Installed App • ${item.formattedSize}'
            : '${item.formattedSize} • ${_formatDate(item.modified)}';

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        if (item.isDirectory) {
          _enterDirectory(item.path);
        } else {
          _toggleSelect(item);
        }
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: isSelected
              ? AppColors.primary.withValues(alpha: 0.12)
              : AppColors.surfaceOf(context),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: isSelected
                ? AppColors.primary
                : AppColors.subtleBorderOf(context),
            width: isSelected ? 1.6 : 1,
          ),
        ),
        child: Row(
          children: [
            // Preview thumbnail or Icon
            _buildItemLeading(item),
            const SizedBox(width: 12),

            // Name and metadata
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
                      fontWeight: isSelected ? FontWeight.w700 : FontWeight.w600,
                      color: AppColors.textPrimaryOf(context),
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11,
                      color: secondaryColor,
                    ),
                  ),
                ],
              ),
            ),

            // Selection indicator or Folder Chevron
            if (item.isDirectory)
              Icon(Icons.chevron_right_rounded, color: secondaryColor, size: 20)
            else
              AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                width: 24,
                height: 24,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: isSelected ? AppColors.primary : Colors.transparent,
                  border: Border.all(
                    color: isSelected
                        ? AppColors.primary
                        : secondaryColor.withValues(alpha: 0.45),
                    width: 2,
                  ),
                ),
                child: isSelected
                    ? const Icon(Icons.check, size: 16, color: Colors.white)
                    : null,
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildItemLeading(LocalItem item) {
    if (item.isDirectory) {
      return Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: Colors.amber.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(12),
        ),
        child: const Icon(Icons.folder_rounded, color: Colors.amber, size: 26),
      );
    }
    return _buildGenericIcon(item);
  }

  Widget _buildGenericIcon(LocalItem item) {
    Color bg;
    Color fg;
    IconData icon;
    final ext = item.extension.toLowerCase();

    if (item.isImage) {
      bg = Colors.amber.withValues(alpha: 0.18);
      fg = const Color(0xFFE65100);
      icon = Icons.image_rounded;
    } else if (item.isVideo) {
      bg = Colors.pink.withValues(alpha: 0.15);
      fg = Colors.pinkAccent;
      icon = Icons.videocam_rounded;
    } else if (item.isAudio) {
      bg = Colors.deepPurple.withValues(alpha: 0.18);
      fg = Colors.purpleAccent;
      icon = Icons.headphones_rounded;
    } else if (item.isApp) {
      bg = Colors.green.withValues(alpha: 0.16);
      fg = const Color(0xFF16A34A);
      icon = Icons.android_rounded;
    } else if (ext == '.pdf') {
      bg = Colors.red.withValues(alpha: 0.15);
      fg = Colors.redAccent;
      icon = Icons.picture_as_pdf_rounded;
    } else if (item.isArchive) {
      bg = Colors.teal.withValues(alpha: 0.16);
      fg = Colors.teal;
      icon = Icons.folder_zip_rounded;
    } else if (item.isDocument) {
      bg = AppColors.primary.withValues(alpha: 0.15);
      fg = AppColors.primary;
      icon = Icons.description_rounded;
    } else {
      bg = AppColors.primary.withValues(alpha: 0.15);
      fg = AppColors.primary;
      icon = Icons.insert_drive_file_rounded;
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

  Widget _buildEmptyState() {
    final secondaryColor = AppColors.textSecondaryOf(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.folder_off_rounded, size: 54, color: secondaryColor.withValues(alpha: 0.45)),
            const SizedBox(height: 12),
            Text(
              _searchQuery.isNotEmpty
                  ? 'No files match "$_searchQuery"'
                  : 'No files found in this tab',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: secondaryColor,
              ),
            ),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              onPressed: _openSystemPicker,
              icon: const Icon(Icons.file_open_rounded, size: 18),
              label: const Text('Browse Any File Extension'),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primary,
                foregroundColor: Colors.white,
                elevation: 0,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBottomBar(int totalBytes) {
    return GlassContainer(
      blur: 25,
      opacity: 0.92,
      borderRadius: 0,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
      child: SafeArea(
        top: false,
        child: Row(
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '${_selectedPaths.length} ${_selectedPaths.length == 1 ? 'file' : 'files'} selected',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textPrimaryOf(context),
                  ),
                ),
                Text(
                  FileHandler.formatFileSize(totalBytes),
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: AppColors.textSecondaryOf(context),
                  ),
                ),
              ],
            ),
            const Spacer(),
            TextButton(
              onPressed: _isPreparingFiles
                  ? null
                  : () => setState(() {
                        _selectedPaths.clear();
                        _selectedItems.clear();
                      }),
              child: Text(
                'Clear',
                style: TextStyle(
                  color: AppColors.textSecondaryOf(context),
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(width: 8),
            BouncingCard(
              onTap: _isPreparingFiles
                  ? () {}
                  : () async {
                      setState(() => _isPreparingFiles = true);
                      final files = <File>[];
                      for (final pth in _selectedPaths) {
                        final item = _selectedItems[pth];
                        if (item != null) {
                          final prepared =
                              await LocalStorageService.prepareFileForSending(item);
                          if (prepared != null) {
                            files.add(prepared);
                          }
                        } else if (pth.startsWith('content://')) {
                          final resolved = await FileHandler.resolveContentUri(pth);
                          if (resolved != null && File(resolved).existsSync()) {
                            files.add(File(resolved));
                          }
                        } else {
                          final f = File(pth);
                          if (f.existsSync()) {
                            files.add(f);
                          }
                        }
                      }
                      if (mounted) {
                        setState(() => _isPreparingFiles = false);
                        Navigator.of(context).pop(files);
                      }
                    },
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 12),
                decoration: BoxDecoration(
                  gradient: AppColors.primaryGradient,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: AppColors.inkOf(context), width: 1.6),
                  boxShadow: [
                    BoxShadow(
                      color: AppColors.primary.withValues(alpha: 0.35),
                      blurRadius: 14,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: Row(
                  children: [
                    if (_isPreparingFiles)
                      const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                        ),
                      )
                    else
                      const Icon(Icons.send_rounded, color: Colors.white, size: 16),
                    const SizedBox(width: 8),
                    Text(
                      _isPreparingFiles
                          ? 'Preparing...'
                          : 'Select (${_selectedPaths.length})',
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                        fontSize: 14,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _formatDate(DateTime dt) {
    return '${dt.day}/${dt.month}/${dt.year}';
  }
}
