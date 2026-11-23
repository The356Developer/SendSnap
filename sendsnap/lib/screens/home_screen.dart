import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config/constants.dart';
import '../l10n/app_localizations.dart';
import '../models/device.dart';
import '../models/transfer.dart';
import '../providers/device_provider.dart';
import '../providers/locale_provider.dart';
import '../providers/transfer_provider.dart';
import '../services/air_gesture_classifier.dart';
import '../services/air_gesture_service.dart';
import '../services/bidi_helper.dart';
import '../services/direct_p2p_service.dart';
import '../services/file_handler.dart';
import '../services/local_storage_service.dart';
import '../services/permission_service.dart';
import '../services/portal_stream_client.dart';
import '../widgets/ambient_background.dart';
import '../widgets/bouncing_card.dart';
import '../widgets/device_avatar.dart';
import '../widgets/draggable_file_token.dart';
import '../widgets/glass_container.dart';
import '../widgets/in_app_file_picker_sheet.dart';
import '../widgets/media_viewer_modal.dart';
import '../widgets/network_status_pill.dart';
import '../widgets/portal_ghost_card.dart';
import '../widgets/qr_scanner_sheet.dart';
import '../widgets/radar_widget.dart';
import '../widgets/segmented_edge_portal_dock.dart';

class HomeScreen extends StatefulWidget {
  final List<File>? initialFiles;
  const HomeScreen({super.key, this.initialFiles});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  List<File> _selectedFiles = [];
  List<File> _stagedAirFiles = [];
  List<LocalItem> _recentItems = [];
  String _incomingGhostFileName = '';
  double _incomingGhostPenetration = 0.0;
  double _incomingGhostY = 0.5;
  NearbyDevice? _activeHoveredDevice;
  bool _isDesktopDragging = false;
  final PortalStreamClient _portalClient = PortalStreamClient();
  final AirGestureService _airGestureService = AirGestureService();
  StreamSubscription<AirGestureFrame>? _airFrameSub;
  bool _isHandDetected = false;
  bool _isAirTrackingStarting = false;
  bool _airCameraDenied = false;
  bool _appResumed = true;
  DateTime? _airGrabStartedAt;
  DateTime? _lastReceiverReleaseAt;
  bool _showEdgePortalHint = false;
  bool _isSearchHelpExpanded = false;
  bool _errorSnackBarVisible = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (widget.initialFiles != null && widget.initialFiles!.isNotEmpty) {
      _selectedFiles = List.from(widget.initialFiles!);
    }
    SharedPreferences.getInstance().then((prefs) {
      if (mounted) {
        setState(() {
          _showEdgePortalHint = !(prefs.getBool('has_used_edge_portal') ?? false);
        });
      }
    });
    _loadRecentFiles();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final devProv = Provider.of<DeviceProvider>(context, listen: false);
      final transProv = Provider.of<TransferProvider>(context, listen: false);
      devProv.onPortalEvent = _handleIncomingPortalEvent;
      devProv.onAirSessionClaimed = (claimer, token) {
        if (!mounted) return;
        final filesToSend = _stagedAirFiles.isNotEmpty
            ? List<File>.from(_stagedAirFiles)
            : List<File>.from(_selectedFiles);
        _stagedAirFiles = [];
        _airGrabStartedAt = null;
        if (filesToSend.isNotEmpty) {
          _portalClient.sendDragDrop(
            fileName: p.basename(filesToSend.first.path),
          );
          _initiateTransfer(
            context,
            claimer,
            devProv,
            transProv,
            files: filesToSend,
          );
        }
      };
      if (_selectedFiles.isNotEmpty && !devProv.isDiscovering) {
        devProv.startActiveDiscovery();
      } else {
        devProv.initWarmDiscovery();
      }
      if (Platform.isAndroid) {
        _checkAndroidSharedFiles();
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!mounted) return;
    final devProv = Provider.of<DeviceProvider>(context, listen: false);
    devProv.onAppLifecycleChanged(state);
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      _appResumed = false;
      unawaited(_stopBackgroundAirTracking());
    } else if (state == AppLifecycleState.resumed) {
      _appResumed = true;
      _airCameraDenied = false;
      _loadRecentFiles();
      _syncBackgroundAirTracking(
        devProv,
        Provider.of<TransferProvider>(context, listen: false),
      );
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _airFrameSub?.cancel();
    unawaited(_airGestureService.dispose());
    _portalClient.disconnect();
    super.dispose();
  }

  Future<void> _loadRecentFiles() async {
    try {
      final received = await LocalStorageService.getItems(
        category: StorageCategory.received,
      );
      if (!mounted) return;
      final transProv = Provider.of<TransferProvider>(context, listen: false);
      final Map<String, LocalItem> byPath = {};

      for (final t in transProv.transfers) {
        if (t.status != TransferStatus.completed) continue;
        final path = t.localPath;
        if (path == null) continue;
        final file = File(path);
        if (!file.existsSync()) continue;
        byPath[path] = LocalItem(
          path: path,
          name: p.basename(path),
          size: t.fileSize > 0 ? t.fileSize : file.lengthSync(),
          modified: t.createdAt,
          isDirectory: false,
          extension: p.extension(path).toLowerCase(),
        );
      }

      for (final item in received) {
        if (!item.isDirectory && !byPath.containsKey(item.path)) {
          byPath[item.path] = item;
        }
      }

      final combined = byPath.values.toList()
        ..sort((a, b) => b.modified.compareTo(a.modified));

      if (mounted) {
        setState(() {
          _recentItems = combined.take(10).toList();
        });
      }
    } catch (_) {}
  }

  void _handleIncomingPortalEvent(Map<String, dynamic> event) {
    if (!mounted) return;
    final type = event['type'];
    if (type == 'DRAG_MOVE') {
      setState(() {
        _incomingGhostFileName = (event['fileName'] as String?) ?? '';
        _incomingGhostPenetration =
            (event['penetration'] as num?)?.toDouble() ?? 0.0;
        _incomingGhostY = (event['y'] as num?)?.toDouble() ?? 0.5;
      });
    } else if (type == 'DRAG_CANCEL') {
      setState(() {
        _incomingGhostFileName = '';
        _incomingGhostPenetration = 0.0;
      });
    } else if (type == 'DRAG_DROP') {
      HapticFeedback.heavyImpact();
      setState(() {
        _incomingGhostPenetration = 1.0;
      });
      Future.delayed(const Duration(milliseconds: 1000), () {
        if (mounted) {
          setState(() {
            _incomingGhostFileName = '';
            _incomingGhostPenetration = 0.0;
          });
        }
      });
    }
  }

  void _onDragUpdate(Offset globalPos, Size screenSize, {String? fileName}) {
    if (_activeHoveredDevice == null || _selectedFiles.isEmpty) return;
    final threshold = screenSize.width - 150.0;
    final name = fileName ??
        (_selectedFiles.isNotEmpty
            ? p.basename(_selectedFiles.first.path)
            : '');
    if (globalPos.dx >= threshold) {
      final penetration =
          ((globalPos.dx - threshold) / 150.0).clamp(0.0, 1.0);
      final normalizedY = (globalPos.dy / screenSize.height).clamp(0.0, 1.0);
      _portalClient.sendDragMove(
        fileName: name,
        penetration: penetration,
        normalizedY: normalizedY,
      );
    } else {
      _portalClient.sendDragCancel();
    }
  }

  static const MethodChannel _androidChannel =
      MethodChannel('com.the356company.sendsnap/file_utils');

  void _checkAndroidSharedFiles() async {
    try {
      _androidChannel.setMethodCallHandler((call) async {
        if (call.method == 'onFilesShared') {
          final List<dynamic>? paths = call.arguments as List<dynamic>?;
          if (paths != null && paths.isNotEmpty) {
            final files = paths
                .map((p) => File(p.toString()))
                .where((f) => f.existsSync())
                .toList();
            if (files.isNotEmpty && mounted) {
              setState(() {
                _selectedFiles = files;
              });
              final devProv =
                  Provider.of<DeviceProvider>(context, listen: false);
              if (!devProv.isDiscovering) {
                devProv.startActiveDiscovery();
              }
            }
          }
        }
      });
      final List<dynamic>? initialPaths = await _androidChannel
          .invokeMethod<List<dynamic>>('getInitialSharedFiles');
      if (initialPaths != null && initialPaths.isNotEmpty) {
        final files = initialPaths
            .map((p) => File(p.toString()))
            .where((f) => f.existsSync())
            .toList();
        if (files.isNotEmpty && mounted) {
          setState(() {
            _selectedFiles = files;
          });
          final devProv = Provider.of<DeviceProvider>(context, listen: false);
          if (!devProv.isDiscovering) {
            devProv.startActiveDiscovery();
          }
        }
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final devProv = Provider.of<DeviceProvider>(context);
    final transProv = Provider.of<TransferProvider>(context);
    final isBusy = devProv.isAdvertising || devProv.isDiscovering;

    _showErrorIfNeeded(context, devProv);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _syncBackgroundAirTracking(devProv, transProv);
      }
    });

    final airIncoming = devProv.activeIncomingAirSession;
    final ghostFileName = _incomingGhostFileName.isNotEmpty
        ? _incomingGhostFileName
        : (airIncoming?.previewName ?? '');
    final ghostPenetration = _incomingGhostFileName.isNotEmpty
        ? _incomingGhostPenetration
        : (airIncoming != null ? 0.65 : 0.0);

    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.keyO, control: true): () {
          _handleSend(this.context, devProv, transProv);
        },
        const SingleActivator(LogicalKeyboardKey.keyO, meta: true): () {
          _handleSend(this.context, devProv, transProv);
        },
        const SingleActivator(LogicalKeyboardKey.escape): () {
          if (isBusy) {
            devProv.stopAll();
            setState(() => _selectedFiles = []);
          }
        },
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          backgroundColor: Colors.transparent,
          body: AmbientBackground(
            child: DropTarget(
              onDragEntered: (detail) =>
                  setState(() => _isDesktopDragging = true),
              onDragExited: (detail) =>
                  setState(() => _isDesktopDragging = false),
              onDragDone: (detail) {
                setState(() {
                  _isDesktopDragging = false;
                  _selectedFiles =
                      detail.files.map((x) => File(x.path)).toList();
                });
                if (_selectedFiles.isNotEmpty && !devProv.isDiscovering) {
                  devProv.startActiveDiscovery();
                }
              },
              child: Stack(
                children: [
                  SafeArea(
                    child: Column(
                      children: [
                        Expanded(
                          child: Center(
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 600),
                              child: SingleChildScrollView(
                                physics: const BouncingScrollPhysics(),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: AppSpacing.l,
                                  vertical: AppSpacing.m,
                                ),
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    _buildHeader(context, devProv),
                                    const SizedBox(height: AppSpacing.m),
                                    AnimatedSwitcher(
                                      duration:
                                          const Duration(milliseconds: 350),
                                      switchInCurve: Curves.easeOutCubic,
                                      switchOutCurve: Curves.easeInCubic,
                                      child: !isBusy
                                          ? _buildReadyState(
                                              context,
                                              devProv,
                                              transProv,
                                            )
                                          : _buildBusyState(
                                              context,
                                              devProv,
                                              transProv,
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

                  // Segmented Edge Portal Dock for Discovered Devices
                  if (devProv.isDiscovering &&
                      devProv.nearbyDevices.isNotEmpty)
                    SegmentedEdgePortalDock(
                      devices: devProv.nearbyDevices,
                      onHoverChanged: (target, penetration, y) {
                        if (target != _activeHoveredDevice) {
                          if (_activeHoveredDevice != null) {
                            _portalClient.sendDragCancel();
                          }
                          _activeHoveredDevice = target;
                        }
                        if (target != null &&
                            _selectedFiles.isNotEmpty &&
                            target.hasLanIp &&
                            !target.isWifiDirect) {
                          _portalClient.connect(target.ip, port: target.port);
                          _portalClient.sendDragMove(
                            fileName: p.basename(_selectedFiles.first.path),
                            penetration: penetration,
                            normalizedY: y,
                          );
                        }
                      },
                      onFileDropped: (target, files) {
                        if (files.isNotEmpty) {
                          _portalClient.sendDragDrop(
                            fileName: p.basename(files.first.path),
                          );
                        }
                        _activeHoveredDevice = null;
                        if (_showEdgePortalHint) {
                          setState(() => _showEdgePortalHint = false);
                        }
                        SharedPreferences.getInstance().then(
                          (prefs) =>
                              prefs.setBool('has_used_edge_portal', true),
                        );
                        _initiateTransfer(
                          context,
                          target,
                          devProv,
                          transProv,
                          files: files,
                        );
                      },
                    ),

                  // Incoming Portal Ghost Card for Receiver Mode
                  PortalGhostCard(
                    isVisible:
                        devProv.isAdvertising && ghostFileName.isNotEmpty,
                    fileName: ghostFileName,
                    penetration: ghostPenetration,
                    normalizedY: _incomingGhostY,
                    isLeftEdge: true,
                  ),

                  // Ambient Air Hand-Tracking Screen Glow
                  _buildAirAuraOverlay(devProv),

                  // Desktop Drag & Drop Visual Overlay
                  if (_isDesktopDragging)
                    Positioned.fill(
                      child: Container(
                        color: AppColors.primary.withValues(alpha: 0.15),
                        child: Center(
                          child: GlassContainer(
                            blur: 20,
                            opacity: 0.88,
                            borderRadius: 28,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 32,
                              vertical: 24,
                            ),
                            borderColor:
                                AppColors.primary.withValues(alpha: 0.5),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(
                                  Icons.file_download_rounded,
                                  size: 52,
                                  color: AppColors.primary,
                                ),
                                const SizedBox(height: 12),
                                Text(
                                  'Drop files to share',
                                  style: TextStyle(
                                    fontSize: 18,
                                    fontWeight: FontWeight.w700,
                                    color: AppColors.textPrimaryOf(context),
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  'Release files to discover nearby devices',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: AppColors.textSecondaryOf(context),
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
          bottomNavigationBar: _buildBottomTransferStatus(context, transProv),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Clean Top Navbar: App Logo + SendSnap Title + Language + Settings
  // ---------------------------------------------------------------------------

  Widget _buildHeader(BuildContext context, DeviceProvider devProv) {
    final l10n = AppLocalizations.of(context);
    final isBusy = devProv.isAdvertising || devProv.isDiscovering;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final titleColor = isDark ? Colors.white : AppColors.textPrimary;
    final inkBorder = isDark ? AppColors.chalkInk : AppColors.ink;
    final isCompact = MediaQuery.sizeOf(context).width < 390;

    return GlassContainer(
      blur: 25,
      opacity: 0.72,
      borderRadius: 26,
      padding: EdgeInsets.symmetric(
        horizontal: isCompact ? 12 : 16,
        vertical: 12,
      ),
      child: Row(
        children: [
          if (isBusy) ...[
            Tooltip(
              message: l10n?.commonBack ?? 'Back',
              child: BouncingCard(
                onTap: () {
                  devProv.stopAll();
                  setState(() {
                    _selectedFiles = [];
                    _isSearchHelpExpanded = false;
                  });
                },
                child: Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    color: AppColors.error.withValues(alpha: 0.14),
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: AppColors.error,
                      width: 1.8,
                    ),
                  ),
                  child: const Icon(
                    Icons.arrow_back_rounded,
                    size: 19,
                    color: AppColors.error,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 10),
          ],
          Container(
            padding: const EdgeInsets.all(2.5),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: AppColors.primaryGradient,
              border: Border.all(color: inkBorder, width: 1.6),
            ),
            child: CircleAvatar(
              radius: isCompact ? 16 : 17,
              backgroundColor: Colors.white,
              child: Image.asset(
                'assets/icon/app_icon.png',
                height: isCompact ? 22 : 24,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: AlignmentDirectional.centerStart,
                  child: Text(
                    'SendSnap',
                    maxLines: 1,
                    softWrap: false,
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w900,
                      letterSpacing: -0.5,
                      color: titleColor,
                      height: 1.15,
                    ),
                  ),
                ),
                const SizedBox(height: 1),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: AlignmentDirectional.centerStart,
                  child: Text(
                    devProv.displayName,
                    maxLines: 1,
                    softWrap: false,
                    style: const TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                      color: AppColors.primary,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          if (!isBusy) ...[
            Tooltip(
              message: l10n?.settingsLanguage ?? 'Language',
              child: BouncingCard(
                onTap: () => _showLanguageDialog(context),
                child: Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    color: isDark
                        ? Colors.white.withValues(alpha: 0.08)
                        : AppColors.surface,
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: inkBorder.withValues(alpha: 0.75),
                      width: 1.6,
                    ),
                  ),
                  child: const Icon(
                    Icons.language_rounded,
                    size: 19,
                    color: AppColors.primary,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
          ],
          Tooltip(
            message: l10n?.settingsTitle ?? 'Settings',
            child: BouncingCard(
              onTap: () => Navigator.pushNamed(context, '/settings'),
              child: Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: isDark
                      ? Colors.white.withValues(alpha: 0.08)
                      : AppColors.surface,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: inkBorder.withValues(alpha: 0.75),
                    width: 1.6,
                  ),
                ),
                child: Icon(
                  Icons.settings_rounded,
                  size: 19,
                  color: titleColor,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _showLanguageDialog(BuildContext context) {
    showDialog(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.35),
      builder: (dialogCtx) {
        return Consumer<LocaleProvider>(
          builder: (context, localeProv, _) {
            final l10n = AppLocalizations.of(context);
            final isDark = Theme.of(context).brightness == Brightness.dark;
            final textPrimary =
                isDark ? Colors.white : AppColors.textPrimary;
            return Dialog(
              backgroundColor: Colors.transparent,
              elevation: 0,
              insetPadding:
                  const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
              child: GlassContainer(
                blur: 24,
                opacity: 0.92,
                borderRadius: 24,
                padding: const EdgeInsets.all(20),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 360),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: AppColors.primary.withValues(alpha: 0.12),
                            ),
                            child: const Icon(
                              Icons.language_rounded,
                              color: AppColors.primary,
                              size: 20,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              l10n?.settingsLanguage ?? 'Language',
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w700,
                                color: textPrimary,
                              ),
                            ),
                          ),
                          IconButton(
                            icon: Icon(
                              Icons.close_rounded,
                              size: 20,
                              color: AppColors.textSecondaryOf(context),
                            ),
                            onPressed: () => Navigator.pop(dialogCtx),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      ...LocaleProvider.supportedLanguages.map((option) {
                        final isSelected =
                            localeProv.currentCode == option.code;
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: BouncingCard(
                            onTap: () {
                              localeProv.setLanguage(option.code);
                              Navigator.pop(dialogCtx);
                            },
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 200),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 12,
                              ),
                              decoration: BoxDecoration(
                                color: isSelected
                                    ? AppColors.primary
                                    : (isDark
                                        ? Colors.white.withValues(alpha: 0.06)
                                        : Colors.black.withValues(alpha: 0.04)),
                                borderRadius: BorderRadius.circular(16),
                                border: Border.all(
                                  color: isSelected
                                      ? AppColors.primary
                                      : Colors.black.withValues(alpha: 0.06),
                                  width: 1.2,
                                ),
                              ),
                              child: Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      option.nativeName,
                                      style: TextStyle(
                                        fontSize: 14,
                                        fontWeight: isSelected
                                            ? FontWeight.w700
                                            : FontWeight.w500,
                                        color: isSelected
                                            ? Colors.white
                                            : textPrimary,
                                      ),
                                    ),
                                  ),
                                  if (option.code != 'system')
                                    Text(
                                      option.englishName,
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: isSelected
                                            ? Colors.white
                                                .withValues(alpha: 0.8)
                                            : AppColors.textSecondaryOf(context),
                                      ),
                                    ),
                                  if (isSelected) ...[
                                    const SizedBox(width: 8),
                                    const Icon(
                                      Icons.check_circle_rounded,
                                      color: Colors.white,
                                      size: 18,
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ),
                        );
                      }),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  // ---------------------------------------------------------------------------
  // Main Menu: Google Files-Inspired Recents Carousel + Send / Receive
  // ---------------------------------------------------------------------------

  Widget _buildReadyState(
    BuildContext context,
    DeviceProvider devProv,
    TransferProvider transProv,
  ) {
    final l10n = AppLocalizations.of(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final titleColor = isDark ? Colors.white : AppColors.textPrimary;

    return Column(
      key: const ValueKey('ready_state'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Google Files-inspired Recents Header & Card Carousel
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Text(
                'Recents',
                style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.3,
                  color: titleColor,
                ),
              ),
            ),
            TextButton(
              onPressed: () async {
                await Navigator.pushNamed(context, '/received_files');
                _loadRecentFiles();
              },
              style: TextButton.styleFrom(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: Text(
                l10n?.receivedTitle ?? 'See all',
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: AppColors.primary,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        if (_recentItems.isNotEmpty) ...[
          SizedBox(
            height: 172,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              physics: const BouncingScrollPhysics(),
              itemCount: _recentItems.length,
              separatorBuilder: (_, _) => const SizedBox(width: 12),
              itemBuilder: (context, index) => _buildRecentFileCard(
                context,
                item: _recentItems[index],
                index: index,
                devProv: devProv,
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.l),
        ] else ...[
          BouncingCard(
            onTap: () async {
              await Navigator.pushNamed(context, '/received_files');
              _loadRecentFiles();
            },
            child: GlassContainer(
              blur: 18,
              opacity: 0.72,
              borderRadius: 22,
              padding:
                  const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: AppColors.primary.withValues(alpha: 0.12),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.history_rounded,
                      color: AppColors.primary,
                      size: 20,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Text(
                      l10n?.receivedTitle ?? 'Received Files',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: titleColor,
                      ),
                    ),
                  ),
                  Icon(
                    Icons.chevron_right_rounded,
                    size: 20,
                    color: AppColors.textSecondaryOf(context),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.l),
        ],

        // Primary SEND and RECEIVE Hero Buttons
        _buildAppleHeroButton(
          title: l10n?.homeSendButton ?? 'SEND',
          subtitle: l10n?.homeSendSubtitle ?? 'Send files to a nearby device',
          icon: Icons.arrow_upward_rounded,
          gradient: AppColors.sendGradient,
          shadowColor: AppColors.primary,
          onTap: () => _handleSend(context, devProv, transProv),
        ),
        const SizedBox(height: AppSpacing.m),
        _buildAppleHeroButton(
          title: l10n?.homeReceiveButton ?? 'RECEIVE',
          subtitle: l10n?.homeReceiveSubtitle ?? 'Receive files right now',
          icon: Icons.arrow_downward_rounded,
          gradient: AppColors.receiveGradient,
          shadowColor: AppColors.receivePrimary,
          onTap: () => devProv.toggleAdvertising(),
        ),
        const SizedBox(height: AppSpacing.l),
        Center(child: NetworkStatusPill(devProv: devProv)),
      ],
    );
  }

  Widget _buildRecentFileCard(
    BuildContext context, {
    required LocalItem item,
    required int index,
    required DeviceProvider devProv,
  }) {
    final isImg = item.isImage && File(item.path).existsSync();

    return BouncingCard(
      onTap: () {
        if (item.isImage) {
          MediaViewerModal.show(
            context,
            item: item,
            items: _recentItems,
            initialIndex: index,
            onShare: () {
              final f = File(item.path);
              if (f.existsSync()) {
                setState(() => _selectedFiles = [f]);
                devProv.startActiveDiscovery();
              }
            },
          );
        } else {
          FileHandler.openFile(item.path);
        }
      },
      child: Container(
        width: 148,
        height: 172,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          color: const Color(0xFF1E2430),
          border: Border.all(
            color: Theme.of(context).brightness == Brightness.dark
                ? AppColors.chalkInk
                : AppColors.ink,
            width: 2.0,
          ),
          boxShadow: [
            BoxShadow(
              color: Theme.of(context).brightness == Brightness.dark
                  ? Colors.black.withValues(alpha: 0.8)
                  : AppColors.ink,
              blurRadius: 0,
              offset: const Offset(3.5, 4.0),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(18),
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (isImg)
                Image.file(
                  File(item.path),
                  fit: BoxFit.cover,
                  cacheWidth: 280,
                  errorBuilder: (_, _, _) => _buildRecentCardPlaceholder(item),
                )
              else
                _buildRecentCardPlaceholder(item),

              // Bottom dark gradient scrim like Google Files
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      stops: const [0.30, 1.0],
                      colors: [
                        Colors.transparent,
                        Colors.black.withValues(alpha: 0.82),
                      ],
                    ),
                  ),
                ),
              ),

              // Top-right quick send button
              Positioned(
                top: 8,
                right: 8,
                child: GestureDetector(
                  onTap: () {
                    final f = File(item.path);
                    if (f.existsSync()) {
                      HapticFeedback.selectionClick();
                      setState(() => _selectedFiles = [f]);
                      devProv.startActiveDiscovery();
                    }
                  },
                  child: Container(
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.45),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.send_rounded,
                      color: Colors.white,
                      size: 14,
                    ),
                  ),
                ),
              ),

              // Bottom filename & caption
              Positioned(
                left: 11,
                right: 11,
                bottom: 11,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      item.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        height: 1.2,
                      ),
                    ),
                    const SizedBox(height: 3),
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: AlignmentDirectional.centerStart,
                      child: Text(
                        item.formattedSize.isNotEmpty
                            ? 'SendSnap • ${item.formattedSize}'
                            : 'SendSnap',
                        maxLines: 1,
                        softWrap: false,
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.78),
                          fontSize: 10.5,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildRecentCardPlaceholder(LocalItem item) {
    IconData icon = Icons.insert_drive_file_rounded;
    List<Color> colors = [const Color(0xFF3B5BFE), const Color(0xFF1E3A8A)];
    if (item.isVideo) {
      icon = Icons.play_circle_fill_rounded;
      colors = [const Color(0xFFEC4899), const Color(0xFF831843)];
    } else if (item.isAudio) {
      icon = Icons.music_note_rounded;
      colors = [const Color(0xFFF59E0B), const Color(0xFF78350F)];
    } else if (item.isDocument) {
      icon = Icons.description_rounded;
      colors = [const Color(0xFF06B6D4), const Color(0xFF164E63)];
    }
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: colors,
        ),
      ),
      child: Center(
        child: Icon(
          icon,
          size: 44,
          color: Colors.white.withValues(alpha: 0.85),
        ),
      ),
    );
  }

  Widget _buildAppleHeroButton({
    required String title,
    required String subtitle,
    required IconData icon,
    required LinearGradient gradient,
    required Color shadowColor,
    required VoidCallback onTap,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final inkBorder = isDark ? AppColors.chalkInk : AppColors.ink;

    return BouncingCard(
      onTap: onTap,
      scaleFactor: 0.98,
      child: Container(
        height: 110,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(24),
          gradient: gradient,
          border: Border.all(
            color: inkBorder,
            width: 2.4,
          ),
          boxShadow: [
            BoxShadow(
              color: isDark
                  ? Colors.black.withValues(alpha: 0.85)
                  : AppColors.ink,
              blurRadius: 0,
              offset: const Offset(4.5, 5.5),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(21.5),
          child: Stack(
            children: [
              // Comic marker highlight band along the top edge
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                height: 10,
                child: ColoredBox(
                  color: Colors.white.withValues(alpha: 0.18),
                ),
              ),
              // Sketched corner accent circle
              Positioned(
                right: -18,
                bottom: -22,
                child: Container(
                  width: 118,
                  height: 118,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.white.withValues(alpha: 0.12),
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.22),
                      width: 1.8,
                    ),
                  ),
                ),
              ),
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
                child: Row(
                  children: [
                    // Hand-inked white badge with dark ink border & offset shadow
                    Container(
                      width: 54,
                      height: 54,
                      decoration: BoxDecoration(
                        color: AppColors.surface,
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: AppColors.ink,
                          width: 2.2,
                        ),
                        boxShadow: const [
                          BoxShadow(
                            color: AppColors.ink,
                            blurRadius: 0,
                            offset: Offset(2.5, 3.0),
                          ),
                        ],
                      ),
                      child: Icon(icon, color: shadowColor, size: 28),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          FittedBox(
                            fit: BoxFit.scaleDown,
                            alignment: AlignmentDirectional.centerStart,
                            child: Text(
                              title,
                              maxLines: 1,
                              softWrap: false,
                              style: const TextStyle(
                                fontSize: 22,
                                fontWeight: FontWeight.w900,
                                letterSpacing: 1.0,
                                color: Colors.white,
                              ),
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            subtitle,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              height: 1.2,
                              color: Colors.white.withValues(alpha: 0.94),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 10),
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.white.withValues(alpha: 0.20),
                        border: Border.all(
                          color: Colors.white.withValues(alpha: 0.55),
                          width: 1.6,
                        ),
                      ),
                      child: const Icon(
                        Icons.arrow_forward_rounded,
                        color: Colors.white,
                        size: 20,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Send & Receive Busy State (Collapsible Search/Connect Card, Minimal Text)
  // ---------------------------------------------------------------------------

  Widget _buildBusyState(
    BuildContext context,
    DeviceProvider devProv,
    TransferProvider transProv,
  ) {
    final l10n = AppLocalizations.of(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final titleColor = isDark ? Colors.white : AppColors.textPrimary;

    return Column(
      key: const ValueKey('busy_state'),
      mainAxisSize: MainAxisSize.min,
      children: [
        RadarWidget(
          active: true,
          label: devProv.isAdvertising
              ? (l10n?.homeRadarReady ?? 'Ready to receive')
              : (l10n?.homeRadarSearching ?? 'Searching nearby...'),
        ),
        if (devProv.isDiscovering) ...[
          const SizedBox(height: AppSpacing.m),
          if (_selectedFiles.isNotEmpty) ...[
            DraggableFileToken(
              files: _selectedFiles,
              isAirGrabbed: devProv.isHoldingAirSession,
              isHandDetected: _isHandDetected,
              onClear: () {
                if (devProv.isHoldingAirSession) {
                  unawaited(devProv.cancelAirGrab());
                  _portalClient.sendDragCancel();
                }
                setState(() {
                  _selectedFiles = [];
                  _stagedAirFiles = [];
                  _airGrabStartedAt = null;
                });
              },
              onAddMore: () => _pickAdditionalFiles(context),
              onRemoveFile: (file) {
                setState(() {
                  _selectedFiles.removeWhere((f) => f.path == file.path);
                });
                if (_selectedFiles.isEmpty && devProv.isHoldingAirSession) {
                  unawaited(devProv.cancelAirGrab());
                  _portalClient.sendDragCancel();
                  _stagedAirFiles = [];
                  _airGrabStartedAt = null;
                }
              },
              onDragUpdate: (globalPos, {fileName}) {
                _onDragUpdate(
                  globalPos,
                  MediaQuery.of(context).size,
                  fileName: fileName,
                );
              },
            ),
            if (_showEdgePortalHint && devProv.nearbyDevices.isNotEmpty) ...[
              const SizedBox(height: 10),
              _buildEdgePortalHint(),
            ],
          ] else ...[
            BouncingCard(
              onTap: () => _pickAdditionalFiles(context),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
                decoration: BoxDecoration(
                  gradient: AppColors.primaryGradient,
                  borderRadius: BorderRadius.circular(20),
                  boxShadow: [
                    BoxShadow(
                      color: AppColors.primary.withValues(alpha: 0.28),
                      blurRadius: 12,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.add_photo_alternate_rounded,
                      size: 18,
                      color: Colors.white,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      l10n?.homeSendSubtitle ?? 'Choose files to send',
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ],

        // Receiver Card (Single clean QR Code button)
        if (devProv.isAdvertising) ...[
          const SizedBox(height: AppSpacing.l),
          GlassContainer(
            blur: 20,
            opacity: 0.75,
            borderRadius: 24,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(
                      child: Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: AppColors.success.withValues(alpha: 0.15),
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(
                              Icons.wifi_tethering,
                              size: 22,
                              color: AppColors.success,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                FittedBox(
                                  fit: BoxFit.scaleDown,
                                  alignment: AlignmentDirectional.centerStart,
                                  child: Text(
                                    l10n?.homeRadarReady ?? 'Ready to Receive',
                                    maxLines: 1,
                                    softWrap: false,
                                    style: TextStyle(
                                      fontWeight: FontWeight.w800,
                                      fontSize: 15,
                                      color: titleColor,
                                    ),
                                  ),
                                ),
                                if (devProv.hasLanIp && devProv.localIp != null) ...[
                                  const SizedBox(height: 2),
                                  FittedBox(
                                    fit: BoxFit.scaleDown,
                                    alignment: AlignmentDirectional.centerStart,
                                    child: Text(
                                      BidiHelper.isolate(devProv.localIp!),
                                      maxLines: 1,
                                      softWrap: false,
                                      style: TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w600,
                                        color: AppColors.textSecondaryOf(context),
                                      ),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 10),
                    BouncingCard(
                      onTap: () => _showReceiverQrCode(context, devProv),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 9),
                        decoration: BoxDecoration(
                          gradient: AppColors.primaryGradient,
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(
                              Icons.qr_code_2_rounded,
                              size: 18,
                              color: Colors.white,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              l10n?.homeQrCode ?? 'QR Code',
                              maxLines: 1,
                              softWrap: false,
                              style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.bold,
                                fontSize: 13,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
                if (devProv.airDirectStatusMessage != null) ...[
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 9),
                    decoration: BoxDecoration(
                      color: AppColors.secondary.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: AppColors.secondary.withValues(alpha: 0.55),
                      ),
                    ),
                    child: Row(
                      children: [
                        const SizedBox(
                          width: 15,
                          height: 15,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: AppColors.secondary,
                          ),
                        ),
                        const SizedBox(width: 9),
                        Expanded(
                          child: Text(
                            devProv.airDirectStatusMessage!,
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              color: titleColor,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ] else if (!devProv.hasLanIp) ...[
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 10),
                    decoration: BoxDecoration(
                      color: AppColors.warning.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: AppColors.warning.withValues(alpha: 0.55),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Padding(
                              padding: EdgeInsets.only(top: 1),
                              child: Icon(
                                Icons.wifi_tethering_rounded,
                                size: 17,
                                color: AppColors.warning,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                'No shared Wi-Fi? Turn on Personal Hotspot on one device, then connect the other device\'s Wi-Fi to it.',
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                  color: titleColor,
                                  height: 1.35,
                                ),
                              ),
                            ),
                          ],
                        ),
                        if (Platform.isAndroid || Platform.isWindows) ...[
                          const SizedBox(height: 10),
                          _buildHotspotWifiButtons(
                            context,
                            devProv,
                            compact: true,
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],

        // Sender Discovered Devices + Hotspot Guide + Collapsible Search / Connect Card
        if (devProv.isDiscovering) ...[
          const SizedBox(height: AppSpacing.m),
          if (devProv.nearbyDevices.isNotEmpty) ...[
            _buildDeviceDiscovery(context, devProv, transProv),
            const SizedBox(height: AppSpacing.m),
          ] else if (!devProv.hasLanIp) ...[
            _buildHotspotGuideCard(context, devProv),
            const SizedBox(height: AppSpacing.m),
          ],
          _buildCollapsibleSearchCard(context, devProv, transProv),
        ],
      ],
    );
  }

  Future<void> _launchConnectionSettings(
    DeviceProvider devProv, {
    required bool hotspot,
  }) async {
    HapticFeedback.selectionClick();
    if (hotspot) {
      await devProv.openHotspotSettings();
    } else {
      await devProv.openWifiSettings();
    }
    await Future.delayed(const Duration(milliseconds: 500));
    await devProv.refreshNetworkStatus(forceRefresh: true);
  }

  Widget _buildHotspotWifiButtons(
    BuildContext context,
    DeviceProvider devProv, {
    bool compact = false,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final titleColor = isDark ? Colors.white : AppColors.textPrimary;
    final vPad = compact ? 8.0 : 10.0;
    final fontSize = compact ? 12.0 : 12.5;
    final iconSize = compact ? 16.0 : 17.0;

    return Row(
      children: [
        Expanded(
          child: BouncingCard(
            onTap: () => _launchConnectionSettings(devProv, hotspot: true),
            child: Container(
              padding: EdgeInsets.symmetric(horizontal: 8, vertical: vPad),
              decoration: BoxDecoration(
                color: AppColors.warning,
                borderRadius: BorderRadius.circular(12),
              ),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.wifi_tethering_rounded,
                      size: iconSize,
                      color: Colors.black,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      'Open Hotspot',
                      maxLines: 1,
                      softWrap: false,
                      style: TextStyle(
                        fontSize: fontSize,
                        fontWeight: FontWeight.w800,
                        color: Colors.black,
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
            onTap: () => _launchConnectionSettings(devProv, hotspot: false),
            child: Container(
              padding: EdgeInsets.symmetric(horizontal: 8, vertical: vPad),
              decoration: BoxDecoration(
                color: isDark
                    ? Colors.white.withValues(alpha: 0.10)
                    : Colors.black.withValues(alpha: 0.06),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: (isDark ? Colors.white : Colors.black)
                      .withValues(alpha: 0.12),
                ),
              ),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.wifi_rounded,
                      size: iconSize,
                      color: titleColor,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      'Open Wi-Fi',
                      maxLines: 1,
                      softWrap: false,
                      style: TextStyle(
                        fontSize: fontSize,
                        fontWeight: FontWeight.w700,
                        color: titleColor,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildHotspotGuideCard(
    BuildContext context,
    DeviceProvider devProv,
  ) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final titleColor = isDark ? Colors.white : AppColors.textPrimary;
    final bodyColor = AppColors.textSecondaryOf(context);

    return GlassContainer(
      blur: 16,
      opacity: 0.80,
      borderRadius: 22,
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: AppColors.warning.withValues(alpha: 0.16),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.wifi_tethering_rounded,
                  size: 18,
                  color: AppColors.warning,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Connect Both Devices Directly',
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w800,
                    color: titleColor,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            '1. Turn on Personal Hotspot on one device\n2. Connect the other device\'s Wi-Fi to that hotspot, then return here',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: bodyColor,
              height: 1.45,
            ),
          ),
          if (Platform.isAndroid || Platform.isWindows) ...[
            const SizedBox(height: 12),
            _buildHotspotWifiButtons(context, devProv),
          ],
        ],
      ),
    );
  }

  Widget _buildCollapsibleSearchCard(
    BuildContext context,
    DeviceProvider devProv,
    TransferProvider transProv,
  ) {
    final l10n = AppLocalizations.of(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final titleColor = isDark ? Colors.white : AppColors.textPrimary;

    return GlassContainer(
      blur: 16,
      opacity: 0.78,
      borderRadius: 22,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: () {
              HapticFeedback.selectionClick();
              setState(() {
                _isSearchHelpExpanded = !_isSearchHelpExpanded;
              });
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(7),
                    decoration: BoxDecoration(
                      color: AppColors.primary.withValues(alpha: 0.14),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.wifi_find_rounded,
                      size: 17,
                      color: AppColors.primary,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: AlignmentDirectional.centerStart,
                      child: Text(
                        l10n?.homeRadarSearching ??
                            'Looking for nearby devices...',
                        maxLines: 1,
                        softWrap: false,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: titleColor,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                    decoration: BoxDecoration(
                      color: AppColors.primary.withValues(alpha: 0.10),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text(
                          'QR / IP',
                          maxLines: 1,
                          softWrap: false,
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            color: AppColors.primary,
                          ),
                        ),
                        const SizedBox(width: 2),
                        Icon(
                          _isSearchHelpExpanded
                              ? Icons.expand_less_rounded
                              : Icons.expand_more_rounded,
                          size: 16,
                          color: AppColors.primary,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (_isSearchHelpExpanded) ...[
            const SizedBox(height: 10),
            Text(
              'Connect both devices to the same Wi-Fi, or turn on Personal Hotspot on one phone and connect the other phone\'s Wi-Fi to it. You can also connect via QR or IP:',
              style: TextStyle(
                fontSize: 11.5,
                color: AppColors.textSecondaryOf(context),
                height: 1.35,
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: BouncingCard(
                    onTap: () => _handleScanQr(devProv, transProv),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 10,
                      ),
                      decoration: BoxDecoration(
                        gradient: AppColors.primaryGradient,
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const Icon(
                              Icons.qr_code_scanner_rounded,
                              size: 17,
                              color: Colors.white,
                            ),
                            const SizedBox(width: 7),
                            Text(
                              l10n?.homeScanQr ?? 'Scan QR',
                              maxLines: 1,
                              softWrap: false,
                              style: const TextStyle(
                                fontSize: 12.5,
                                fontWeight: FontWeight.w700,
                                color: Colors.white,
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
                    onTap: () =>
                        _showManualIpDialog(context, devProv, transProv),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 10,
                      ),
                      decoration: BoxDecoration(
                        color: isDark
                            ? Colors.white.withValues(alpha: 0.08)
                            : Colors.black.withValues(alpha: 0.05),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              Icons.edit_note_rounded,
                              size: 18,
                              color: titleColor,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              l10n?.homeConnectManual ?? 'Enter IP',
                              maxLines: 1,
                              softWrap: false,
                              style: TextStyle(
                                fontSize: 12.5,
                                fontWeight: FontWeight.w700,
                                color: titleColor,
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
            if ((Platform.isAndroid || Platform.isWindows) &&
                devProv.nearbyDevices.isEmpty) ...[
              const SizedBox(height: 10),
              _buildHotspotWifiButtons(context, devProv, compact: true),
            ],
          ],
        ],
      ),
    );
  }

  Widget _buildDeviceDiscovery(
    BuildContext context,
    DeviceProvider devProv,
    TransferProvider transProv,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
          child: Text(
            'DISCOVERED DEVICES',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w800,
              letterSpacing: 1.2,
              color: AppColors.textSecondaryOf(context),
            ),
          ),
        ),
        const SizedBox(height: 4),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          physics: const BouncingScrollPhysics(),
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            children: devProv.nearbyDevices
                .map(
                  (device) =>
                      _buildDeviceItem(context, device, devProv, transProv),
                )
                .toList(),
          ),
        ),
      ],
    );
  }

  Widget _buildDeviceItem(
    BuildContext context,
    NearbyDevice device,
    DeviceProvider devProv,
    TransferProvider transProv,
  ) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final titleColor = isDark ? Colors.white : AppColors.textPrimary;

    return DragTarget<List<File>>(
      onWillAcceptWithDetails: (details) => details.data.isNotEmpty,
      onAcceptWithDetails: (details) {
        HapticFeedback.heavyImpact();
        _initiateTransfer(
          context,
          device,
          devProv,
          transProv,
          files: details.data,
        );
      },
      builder: (context, candidateData, rejectedData) {
        final isTargeted = candidateData.isNotEmpty;
        return AnimatedScale(
          scale: isTargeted ? 1.08 : 1.0,
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutBack,
          child: BouncingCard(
            onTap: () => _initiateTransfer(
              context,
              device,
              devProv,
              transProv,
              files: _selectedFiles,
            ),
            child: GlassContainer(
              blur: 20,
              opacity: isTargeted ? 0.95 : 0.75,
              borderRadius: 24,
              borderColor: isTargeted ? AppColors.primary : null,
              borderWidth: isTargeted ? 2.0 : 1.0,
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              margin: const EdgeInsets.only(right: 14),
              boxShadow: [
                BoxShadow(
                  color: isTargeted
                      ? AppColors.primary.withValues(alpha: 0.35)
                      : Colors.black.withValues(alpha: 0.05),
                  blurRadius: isTargeted ? 20 : 14,
                  offset: const Offset(0, 4),
                ),
              ],
              child: ConstrainedBox(
                constraints: const BoxConstraints(minWidth: 124, maxWidth: 164),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    DeviceAvatar(device: device, size: 48),
                    const SizedBox(height: 10),
                    Text(
                      device.endpointName,
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 12.5,
                        height: 1.2,
                        color: isTargeted ? AppColors.primary : titleColor,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 3),
                    Text(
                      isTargeted
                          ? 'Drop to send'
                          : _getDeviceFriendlySubtitle(device.deviceType),
                      style: TextStyle(
                        fontSize: 10.5,
                        color: isTargeted
                            ? AppColors.primary
                            : AppColors.textSecondaryOf(context),
                        fontWeight:
                            isTargeted ? FontWeight.w700 : FontWeight.w600,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  String _getDeviceFriendlySubtitle(String type) {
    final t = type.toLowerCase();
    if (t.contains('windows')) return 'Windows PC';
    if (t.contains('ios') || t.contains('iphone')) return 'iPhone';
    if (t.contains('ipad')) return 'iPad';
    if (t.contains('android')) return 'Android';
    if (t.contains('linux')) return 'Linux PC';
    return 'Nearby';
  }

  Widget _buildEdgePortalHint() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: AppColors.primary.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: AppColors.primary.withValues(alpha: 0.35),
          width: 1,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.arrow_forward_rounded,
            size: 15,
            color: AppColors.primary,
          ),
          const SizedBox(width: 6),
          const Flexible(
            child: Text(
              'Drag file card to right edge to snap directly',
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w700,
                color: AppColors.primary,
              ),
            ),
          ),
          const SizedBox(width: 8),
          GestureDetector(
            onTap: () {
              setState(() => _showEdgePortalHint = false);
              SharedPreferences.getInstance().then(
                (prefs) => prefs.setBool('has_used_edge_portal', true),
              );
            },
            child: Container(
              padding: const EdgeInsets.all(2),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: AppColors.primary.withValues(alpha: 0.15),
              ),
              child: const Icon(
                Icons.close_rounded,
                size: 12,
                color: AppColors.primary,
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _showReceiverQrCode(BuildContext context, DeviceProvider devProv) {
    final l10n = AppLocalizations.of(context);
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => Consumer<DeviceProvider>(
        builder: (_, liveDevProv, _) {
          final ip = liveDevProv.localIp ?? '';
          final hasIp = liveDevProv.hasLanIp;
          final hotspot = liveDevProv.activeHotspotInfo;
          final qrData = DirectP2pService.buildQrPayload(
            lanIp: hasIp ? ip : null,
            port: liveDevProv.nearbyService.httpServer.port ?? 53318,
            hotspot: hotspot,
            deviceId: liveDevProv.nearbyService.localDevice?.id,
            deviceName: liveDevProv.displayName,
          );
          final isDark = Theme.of(context).brightness == Brightness.dark;
          final sheetBg = isDark ? const Color(0xFF171B24) : Colors.white;
          final titleColor = isDark ? Colors.white : AppColors.textPrimary;

          return BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
            child: Container(
              decoration: BoxDecoration(
                color: sheetBg.withValues(alpha: 0.92),
                borderRadius:
                    const BorderRadius.vertical(top: Radius.circular(36)),
                border: Border.all(
                  color: Colors.white.withValues(alpha: isDark ? 0.12 : 1.0),
                  width: 1.5,
                ),
              ),
              padding: const EdgeInsets.all(AppSpacing.xl),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 44,
                    height: 5,
                    decoration: BoxDecoration(
                      color: Colors.grey.withValues(alpha: 0.3),
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  const SizedBox(height: 20),
                  Text(
                    l10n?.homeScanToConnect ?? 'Scan to Connect',
                    style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.5,
                      color: titleColor,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    l10n?.homeConnectDirectly(liveDevProv.displayName) ??
                        'Connect directly to ${liveDevProv.displayName}',
                    style: TextStyle(
                      color: AppColors.textSecondaryOf(context),
                      fontSize: 13.5,
                    ),
                  ),
                  const SizedBox(height: 20),
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(24),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.08),
                          blurRadius: 20,
                          offset: const Offset(0, 8),
                        ),
                      ],
                    ),
                    child: SizedBox(
                      height: 180,
                      width: 180,
                      child: QrImageView(
                        data: qrData,
                        version: QrVersions.auto,
                      ),
                    ),
                  ),
                  if (hasIp) ...[
                    const SizedBox(height: 16),
                    GestureDetector(
                      onTap: () {
                        Clipboard.setData(ClipboardData(text: ip));
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(
                              l10n?.homeIpCopied ??
                                  'IP address copied to clipboard!',
                            ),
                            duration: const Duration(seconds: 2),
                          ),
                        );
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 8,
                        ),
                        decoration: BoxDecoration(
                          color: (isDark ? Colors.white : Colors.black)
                              .withValues(alpha: 0.06),
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              BidiHelper.isolate(ip),
                              style: TextStyle(
                                fontWeight: FontWeight.w700,
                                fontSize: 14,
                                color: titleColor,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Icon(
                              Icons.copy_rounded,
                              size: 14,
                              color: AppColors.textSecondaryOf(context),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: 16),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  void _showManualIpDialog(
    BuildContext context,
    DeviceProvider devProv,
    TransferProvider transProv,
  ) {
    final controller = TextEditingController();
    final isDark = Theme.of(context).brightness == Brightness.dark;
    showDialog(
      context: context,
      builder: (ctx) => BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
        child: AlertDialog(
          backgroundColor: (isDark ? const Color(0xFF1C212C) : Colors.white)
              .withValues(alpha: 0.94),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(28),
          ),
          title: Text(
            AppLocalizations.of(context)?.homeConnectManual ?? 'Connect by IP',
            style: TextStyle(
              fontWeight: FontWeight.w800,
              color: AppColors.textPrimaryOf(context),
            ),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Enter the IP shown on the receiver:',
                style: TextStyle(
                  fontSize: 13,
                  color: AppColors.textSecondaryOf(context),
                ),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: controller,
                autofocus: true,
                style: TextStyle(color: AppColors.textPrimaryOf(context)),
                decoration: InputDecoration(
                  hintText: 'e.g. 192.168.1.45',
                  hintStyle: TextStyle(
                    color: AppColors.textSecondaryOf(context),
                  ),
                  filled: true,
                  fillColor: (isDark ? Colors.white : Colors.black)
                      .withValues(alpha: 0.05),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(16),
                    borderSide: BorderSide.none,
                  ),
                  prefixIcon: Icon(
                    Icons.wifi_rounded,
                    size: 20,
                    color: AppColors.textSecondaryOf(context),
                  ),
                ),
                keyboardType: TextInputType.datetime,
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(
                AppLocalizations.of(context)?.actionCancel ?? 'Cancel',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
            ElevatedButton(
              onPressed: () async {
                final ip = controller.text.trim();
                final messenger = ScaffoldMessenger.of(context);
                Navigator.pop(ctx);
                if (ip.isNotEmpty) {
                  final found = await devProv.connectByIp(ip);
                  if (!found && mounted) {
                    messenger.showSnackBar(
                      SnackBar(
                        content: Text('Could not reach device at $ip'),
                        backgroundColor: AppColors.error,
                      ),
                    );
                  }
                }
              },
              style: ElevatedButton.styleFrom(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
                padding:
                    const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              ),
              child: Text(
                AppLocalizations.of(context)?.homeConnectManual ?? 'Connect',
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _handleScanQr(
    DeviceProvider devProv,
    TransferProvider transProv,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    final l10n = AppLocalizations.of(context);
    final status = await Permission.camera.request();
    if (!status.isGranted) {
      if (mounted) {
        messenger.showSnackBar(
          SnackBar(
            content: Text(
              l10n?.homeCameraPermission ??
                  'Camera permission is required to scan QR codes.',
            ),
            backgroundColor: AppColors.error,
          ),
        );
      }
      return;
    }
    if (!mounted) return;
    final scannedCode = await QrScannerSheet.show(context);
    if (scannedCode == null || scannedCode.isEmpty) return;
    if (!mounted) return;
    messenger.showSnackBar(
      const SnackBar(
        content: Text('Connecting...'),
        duration: Duration(seconds: 2),
      ),
    );
    final targetDevice = await devProv.connectFromQr(scannedCode);
    if (!mounted) return;
    if (targetDevice != null) {
      if (_selectedFiles.isNotEmpty) {
        _initiateTransfer(context, targetDevice, devProv, transProv);
      } else {
        messenger.showSnackBar(
          SnackBar(
            content: Text(
              'Connected to ${targetDevice.name}! Choose files to send.',
            ),
            backgroundColor: AppColors.success,
          ),
        );
        _handleSend(context, devProv, transProv);
      }
    } else {
      messenger.showSnackBar(
        const SnackBar(
          content: Text(
            'Could not reach device. Make sure Wi-Fi is turned ON on both devices.',
          ),
          backgroundColor: AppColors.error,
        ),
      );
    }
  }

  void _handleSend(
    BuildContext context,
    DeviceProvider devProv,
    TransferProvider transProv,
  ) async {
    unawaited(devProv.boostWarmDiscovery());
    List<File>? selected;
    if (!Platform.isAndroid && !Platform.isIOS) {
      final result = await FilePicker.platform.pickFiles(
        allowMultiple: true,
        type: FileType.any,
      );
      if (result != null && result.paths.isNotEmpty) {
        selected = result.paths
            .whereType<String>()
            .map((path) => File(path))
            .toList();
      }
    } else {
      selected = await InAppFilePickerSheet.show(context, allowMultiple: true);
    }
    if (selected != null && selected.isNotEmpty) {
      setState(() {
        _selectedFiles = selected!;
      });
      if (!devProv.isDiscovering) {
        devProv.startActiveDiscovery();
      }
    }
  }

  Future<void> _pickAdditionalFiles(BuildContext context) async {
    List<File>? selected;
    if (!Platform.isAndroid && !Platform.isIOS) {
      final result = await FilePicker.platform.pickFiles(
        allowMultiple: true,
        type: FileType.any,
      );
      if (result != null && result.paths.isNotEmpty) {
        selected = result.paths
            .whereType<String>()
            .map((path) => File(path))
            .toList();
      }
    } else {
      selected = await InAppFilePickerSheet.show(context, allowMultiple: true);
    }
    if (selected != null && selected.isNotEmpty && mounted) {
      setState(() {
        final existingPaths = _selectedFiles.map((f) => f.path).toSet();
        for (final file in selected!) {
          if (!existingPaths.contains(file.path)) {
            _selectedFiles.add(file);
          }
        }
      });
    }
  }

  void _initiateTransfer(
    BuildContext context,
    NearbyDevice target,
    DeviceProvider devProv,
    TransferProvider transProv, {
    List<File>? files,
  }) async {
    final filesToSend = (files != null && files.isNotEmpty)
        ? List<File>.from(files)
        : List<File>.from(_selectedFiles);
    if (filesToSend.isEmpty) return;

    final isDirectWifi = target.isWifiDirect && !target.hasLanIp;
    _showConnectingSheet(
      context,
      target.endpointName,
      isDirectWifi: isDirectWifi,
    );
    final scaffoldMessenger = ScaffoldMessenger.of(context);
    final nav = Navigator.of(context);
    final connected = await devProv.requestConnectionAndWait(target.endpointId);
    if (nav.canPop()) {
      nav.pop();
    }
    if (connected) {
      final resolvedTarget =
          devProv.nearbyService.getDevice(target.endpointId) ?? target;
      final sentPaths = filesToSend.map((f) => f.path).toSet();
      setState(() {
        _selectedFiles.removeWhere((f) => sentPaths.contains(f.path));
      });
      if (mounted && !transProv.isTransferRouteOpen) {
        nav.pushNamed('/transfer').then((result) {
          if (!mounted) return;
          _loadRecentFiles();
          if (result == 'main_menu') {
            setState(() {
              _selectedFiles.clear();
            });
            return;
          }
          if (_selectedFiles.isNotEmpty && !devProv.isDiscovering) {
            devProv.startActiveDiscovery();
          }
        });
      }
      await transProv.sendFiles(
        resolvedTarget,
        filesToSend,
        devProv.nearbyService,
      );
      _loadRecentFiles();
    } else {
      if (mounted) {
        scaffoldMessenger.showSnackBar(
          const SnackBar(
            content: Text(
              'Failed to connect. Make sure Wi-Fi is turned ON on both devices.',
            ),
            backgroundColor: AppColors.error,
          ),
        );
      }
    }
  }

  void _showConnectingSheet(
    BuildContext context,
    String deviceName, {
    bool isDirectWifi = false,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isDismissible: false,
      builder: (context) => BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
        child: Container(
          constraints: const BoxConstraints(minHeight: 220),
          decoration: BoxDecoration(
            color: (isDark ? const Color(0xFF171B24) : Colors.white)
                .withValues(alpha: 0.92),
            borderRadius:
                const BorderRadius.vertical(top: Radius.circular(32)),
          ),
          padding: const EdgeInsets.all(AppSpacing.xl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const CircularProgressIndicator(),
              const SizedBox(height: AppSpacing.l),
              Text(
                AppLocalizations.of(context)?.transferConnecting(deviceName) ??
                    'Connecting to $deviceName...',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textPrimaryOf(context),
                ),
              ),
              if (isDirectWifi) ...[
                const SizedBox(height: AppSpacing.s),
                Text(
                  'Setting up direct Wi-Fi link… Tap "Connect" if Android asks.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: AppColors.textSecondaryOf(context),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBottomTransferStatus(
    BuildContext context,
    TransferProvider transProv,
  ) {
    if (transProv.activeTransfer == null) return const SizedBox.shrink();

    final transfer = transProv.activeTransfer!;
    final batchCount = transProv.currentBatchTransfers.length;
    final statusTitle = batchCount > 1
        ? '${transfer.fileName} (${transProv.completedBatchCount}/$batchCount)'
        : transfer.fileName;

    return SafeArea(
      child: Container(
        margin: const EdgeInsets.all(16),
        child: GlassContainer(
          blur: 25,
          opacity: 0.85,
          borderRadius: 24,
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      statusTitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 14,
                        color: AppColors.textPrimaryOf(context),
                      ),
                    ),
                    const SizedBox(height: 6),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        value: transProv.batchProgress,
                        minHeight: 6,
                        backgroundColor:
                            AppColors.primary.withValues(alpha: 0.12),
                        valueColor: const AlwaysStoppedAnimation<Color>(
                          AppColors.primary,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: AppSpacing.l),
              BouncingCard(
                onTap: () async {
                  final result =
                      await Navigator.pushNamed(context, '/transfer');
                  if (!mounted || result != true) return;
                  final dp =
                      Provider.of<DeviceProvider>(this.context, listen: false);
                  final tp = Provider.of<TransferProvider>(
                    this.context,
                    listen: false,
                  );
                  _handleSend(this.context, dp, tp);
                },
                child: Container(
                  padding: const EdgeInsets.all(10),
                  decoration: const BoxDecoration(
                    gradient: AppColors.primaryGradient,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.arrow_forward_rounded,
                    color: Colors.white,
                    size: 18,
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
  // Auto-Dismissing Bottom Error Banner with 'FIX' Button
  // ---------------------------------------------------------------------------

  void _showErrorIfNeeded(BuildContext context, DeviceProvider devProv) {
    if (devProv.hasAnyNetworkReady && _errorSnackBarVisible) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _errorSnackBarVisible) {
          _errorSnackBarVisible = false;
          ScaffoldMessenger.of(context).hideCurrentSnackBar();
        }
      });
    }

    if (devProv.lastError != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && devProv.lastError != null) {
          final errorMsg = devProv.lastError!;
          final wifiOff = devProv.lastErrorIsWifiOff;
          devProv.clearError();
          final messenger = ScaffoldMessenger.of(context);
          messenger.hideCurrentSnackBar();
          _errorSnackBarVisible = true;
          messenger
              .showSnackBar(
                SnackBar(
                  content: Text(errorMsg),
                  backgroundColor: AppColors.error,
                  duration: const Duration(seconds: 4),
                  behavior: SnackBarBehavior.floating,
                  action: SnackBarAction(
                    label: 'FIX',
                    textColor: Colors.white,
                    onPressed: () {
                      _errorSnackBarVisible = false;
                      messenger.hideCurrentSnackBar();
                      if (wifiOff) {
                        devProv.openWifiSettings();
                      } else {
                        PermissionService().openSettings();
                      }
                    },
                  ),
                ),
              )
              .closed
              .then((_) {
                _errorSnackBarVisible = false;
              });
        }
      });
    }
  }

  bool _shouldRunBackgroundAirTracking(
    DeviceProvider devProv,
    TransferProvider transProv,
  ) {
    return _appResumed &&
        !transProv.isTransferRouteOpen &&
        ((devProv.isDiscovering && _selectedFiles.isNotEmpty) ||
            devProv.isAdvertising);
  }

  void _syncBackgroundAirTracking(
    DeviceProvider devProv,
    TransferProvider transProv,
  ) {
    if (!Platform.isAndroid && !Platform.isWindows && !Platform.isLinux) {
      return;
    }

    if (devProv.isAdvertising &&
        devProv.activeIncomingAirSession != null &&
        _lastReceiverReleaseAt != null &&
        DateTime.now().difference(_lastReceiverReleaseAt!).inMilliseconds <=
            2500) {
      _lastReceiverReleaseAt = null;
      HapticFeedback.heavyImpact();
      unawaited(devProv.claimIncomingAirSession());
    }

    final shouldTrack = _shouldRunBackgroundAirTracking(devProv, transProv);

    if (shouldTrack &&
        !_airGestureService.isRunning &&
        !_isAirTrackingStarting &&
        !_airCameraDenied) {
      unawaited(_startBackgroundAirTracking());
    } else if (!shouldTrack &&
        (_airGestureService.isRunning || _isAirTrackingStarting)) {
      unawaited(_stopBackgroundAirTracking());
    }
  }

  Future<void> _startBackgroundAirTracking() async {
    if (_isAirTrackingStarting || _airGestureService.isRunning) return;
    _isAirTrackingStarting = true;
    try {
      final supported = await _airGestureService.isSupported();
      if (!supported) {
        _airCameraDenied = true;
        return;
      }

      if (Platform.isAndroid) {
        var granted = await Permission.camera.isGranted;
        if (!granted) {
          granted = await PermissionService().requestCameraPermission();
        }
        if (!granted) {
          _airCameraDenied = true;
          return;
        }
      }

      if (!mounted || !_appResumed) return;

      _airFrameSub ??= _airGestureService.frames.listen(
        _onBackgroundAirFrame,
        onError: (_) {},
      );
      final started = await _airGestureService.start();
      if (!mounted) {
        await _airGestureService.stop();
        return;
      }
      final devProv = Provider.of<DeviceProvider>(context, listen: false);
      final transProv = Provider.of<TransferProvider>(context, listen: false);
      final stillShouldTrack =
          _shouldRunBackgroundAirTracking(devProv, transProv);
      if (started && !stillShouldTrack) {
        await _airGestureService.stop();
        return;
      }
      if (!started && stillShouldTrack) {
        _airCameraDenied = true;
      }
    } finally {
      _isAirTrackingStarting = false;
    }
  }

  Future<void> _stopBackgroundAirTracking() async {
    if (_airGestureService.isRunning || _isAirTrackingStarting) {
      await _airGestureService.stop();
    }
    if (mounted && _isHandDetected) {
      setState(() {
        _isHandDetected = false;
      });
    }
  }

  void _onBackgroundAirFrame(AirGestureFrame frame) {
    if (!mounted) return;
    if (frame.detected != _isHandDetected) {
      setState(() {
        _isHandDetected = frame.detected;
      });
    }

    final devProv = Provider.of<DeviceProvider>(context, listen: false);
    final action = frame.triggeredAction;

    // Sender mode: grab & cancel directly from the default Send screen
    if (devProv.isDiscovering && _selectedFiles.isNotEmpty) {
      if (action == AirGestureAction.grab && !devProv.isHoldingAirSession) {
        HapticFeedback.heavyImpact();
        _airGrabStartedAt = DateTime.now();
        _stagedAirFiles = List<File>.from(_selectedFiles);

        int totalBytes = 0;
        for (final file in _stagedAirFiles) {
          try {
            totalBytes += file.lengthSync();
          } catch (_) {}
        }
        final firstName = p.basename(_stagedAirFiles.first.path);
        final previewName = _stagedAirFiles.length == 1
            ? firstName
            : '$firstName +${_stagedAirFiles.length - 1}';

        unawaited(
          devProv.stageAirGrab(
            fileCount: _stagedAirFiles.length,
            previewName: previewName,
            totalBytes: totalBytes,
          ),
        );

        final lanTarget = devProv.nearbyDevices
            .where((d) => d.hasLanIp && !d.isWifiDirect)
            .firstOrNull;
        if (lanTarget != null) {
          unawaited(
            _portalClient.connect(lanTarget.ip, port: lanTarget.port).then((ok) {
              if (ok) {
                _portalClient.sendDragMove(
                  fileName: previewName,
                  penetration: 0.65,
                  normalizedY: 0.5,
                );
              }
            }),
          );
        }
      } else if (action == AirGestureAction.release &&
          devProv.isHoldingAirSession) {
        final heldMs = _airGrabStartedAt == null
            ? 0
            : DateTime.now().difference(_airGrabStartedAt!).inMilliseconds;
        final centered = frame.handCenter.dx >= 0.15 &&
            frame.handCenter.dx <= 0.85 &&
            frame.handCenter.dy >= 0.15 &&
            frame.handCenter.dy <= 0.85;
        if (heldMs >= 1500 && frame.openness >= 0.72 && centered) {
          HapticFeedback.selectionClick();
          _airGrabStartedAt = null;
          _stagedAirFiles = [];
          unawaited(devProv.cancelAirGrab());
          _portalClient.sendDragCancel();
        }
      }
      return;
    }

    // Receiver mode: open hand drops / receives the incoming grabbed file
    if (devProv.isAdvertising) {
      final incoming = devProv.activeIncomingAirSession;
      final isOpenRelease = action == AirGestureAction.release ||
          (incoming != null &&
              frame.posture == HandPosture.open &&
              frame.openness >= 0.68);
      if (isOpenRelease) {
        if (incoming != null) {
          HapticFeedback.heavyImpact();
          _lastReceiverReleaseAt = null;
          setState(() {
            _incomingGhostPenetration = 1.0;
          });
          unawaited(devProv.claimIncomingAirSession());
          Future.delayed(const Duration(milliseconds: 900), () {
            if (mounted) {
              setState(() {
                _incomingGhostPenetration = 0.0;
              });
            }
          });
        } else if (action == AirGestureAction.release) {
          _lastReceiverReleaseAt = DateTime.now();
        }
      }
    }
  }

  Widget _buildAirAuraOverlay(DeviceProvider devProv) {
    final bool isAirActive = devProv.isHoldingAirSession ||
        (devProv.isAdvertising && devProv.activeIncomingAirSession != null);
    final bool isAirLit = _isHandDetected || isAirActive;

    return Positioned.fill(
      child: IgnorePointer(
        child: AnimatedOpacity(
          opacity: isAirLit ? 1.0 : 0.0,
          duration: const Duration(milliseconds: 260),
          curve: Curves.easeOutCubic,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 260),
            decoration: BoxDecoration(
              border: Border.all(
                color: AppColors.secondary.withValues(
                  alpha: isAirActive ? 0.78 : 0.36,
                ),
                width: isAirActive ? 3.5 : 2.0,
              ),
              gradient: RadialGradient(
                center: Alignment.center,
                radius: 0.95,
                colors: [
                  Colors.transparent,
                  AppColors.secondary.withValues(
                    alpha: isAirActive ? 0.22 : 0.08,
                  ),
                ],
                stops: const [0.58, 1.0],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
