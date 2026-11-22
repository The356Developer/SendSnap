import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../config/constants.dart';
import '../providers/device_provider.dart';
import '../services/air_gesture_classifier.dart';
import '../services/air_gesture_service.dart';
import '../services/permission_service.dart';
import 'bouncing_card.dart';

enum AirGestureMode {
  sender,
  receiver,
}

class AirGestureOverlay extends StatefulWidget {
  final AirGestureMode mode;
  final int fileCount;
  final String previewName;
  final int totalBytes;

  const AirGestureOverlay({
    super.key,
    required this.mode,
    this.fileCount = 0,
    this.previewName = '',
    this.totalBytes = 0,
  });

  static Future<bool?> show(
    BuildContext context, {
    required AirGestureMode mode,
    int fileCount = 0,
    String previewName = '',
    int totalBytes = 0,
  }) {
    return showDialog<bool>(
      context: context,
      barrierDismissible: false,
      barrierColor: Colors.black.withValues(alpha: 0.84),
      useSafeArea: true,
      builder: (_) => AirGestureOverlay(
        mode: mode,
        fileCount: fileCount,
        previewName: previewName,
        totalBytes: totalBytes,
      ),
    );
  }

  @override
  State<AirGestureOverlay> createState() => _AirGestureOverlayState();
}

class _AirGestureOverlayState extends State<AirGestureOverlay>
    with SingleTickerProviderStateMixin {
  static const Duration _holdDuration = Duration(seconds: 30);

  final AirGestureService _gestureService = AirGestureService();
  final PermissionService _permissionService = PermissionService();

  StreamSubscription<AirGestureFrame>? _frameSub;
  AirGestureFrame? _latestFrame;
  Timer? _countdownTimer;
  DateTime? _holdStartedAt;
  double _holdProgress = 0.0;
  int _remainingSeconds = 30;

  bool _initializing = true;
  bool _isHolding = false;
  bool _caughtSuccess = false;
  bool _permissionDenied = false;
  String? _errorMessage;
  String? _hintToast;
  Timer? _hintTimer;

  late final AnimationController _pulseController;
  DeviceProvider? _deviceProvider;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1600),
    )..repeat(reverse: true);
    _initCameraAndDetector();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _deviceProvider = Provider.of<DeviceProvider>(context, listen: false);
  }

  Future<void> _initCameraAndDetector() async {
    final devProv = Provider.of<DeviceProvider>(context, listen: false);
    unawaited(devProv.refreshNetworkStatus(forceRefresh: true));
    if (widget.mode == AirGestureMode.receiver) {
      unawaited(devProv.startAirReceiverScan());
    }
    final supported = await _gestureService.isSupported();
    if (!mounted) return;
    if (!supported) {
      setState(() {
        _initializing = false;
        _errorMessage = 'Front camera is not available on this device.';
      });
      return;
    }

    final granted = await _permissionService.requestCameraPermission();
    if (!mounted) return;
    if (!granted) {
      setState(() {
        _initializing = false;
        _permissionDenied = true;
        _errorMessage =
            'Camera permission is required so SendSnap can detect your hand gestures locally.';
      });
      return;
    }

    _frameSub = _gestureService.frames.listen(
      _onGestureFrame,
      onError: (Object err) {
        if (!mounted) return;
        setState(() {
          _initializing = false;
          _errorMessage = err.toString();
        });
      },
    );

    final started = await _gestureService.start();
    if (!mounted) return;
    setState(() {
      _initializing = false;
      if (!started) {
        _errorMessage = 'Could not start the front camera for Air Gestures.';
      }
    });
  }

  void _onGestureFrame(AirGestureFrame frame) {
    if (!mounted) return;
    setState(() {
      _latestFrame = frame;
    });

    final action = frame.triggeredAction;
    if (action == null) return;

    final devProv = Provider.of<DeviceProvider>(context, listen: false);

    if (widget.mode == AirGestureMode.sender) {
      if (action == AirGestureAction.grab && !_isHolding) {
        HapticFeedback.heavyImpact();
        _startHoldCountdown();
        devProv.stageAirGrab(
          fileCount: widget.fileCount,
          previewName: widget.previewName,
          totalBytes: widget.totalBytes,
          ttl: _holdDuration,
        );
      } else if (action == AirGestureAction.release && _isHolding) {
        final heldElapsedMs = _holdStartedAt == null
            ? 0
            : DateTime.now().difference(_holdStartedAt!).inMilliseconds;
        final centered = frame.handCenter.dx >= 0.15 &&
            frame.handCenter.dx <= 0.85 &&
            frame.handCenter.dy >= 0.15 &&
            frame.handCenter.dy <= 0.85;
        if (heldElapsedMs >= 1500 && frame.openness >= 0.72 && centered) {
          HapticFeedback.selectionClick();
          _stopHoldCountdown();
          devProv.cancelAirGrab();
          _showHint('Released to cancel — close fist again to Air Grab.');
        }
      }
    } else {
      if (action == AirGestureAction.release && !_caughtSuccess) {
        final incoming = devProv.activeIncomingAirSession;
        if (incoming != null) {
          HapticFeedback.heavyImpact();
          setState(() {
            _caughtSuccess = true;
          });
          _claimAndClose(devProv);
        } else {
          HapticFeedback.lightImpact();
          _showHint('No Air file held nearby yet — grab on sender phone first.');
        }
      }
    }
  }

  Future<void> _claimAndClose(DeviceProvider devProv) async {
    await devProv.claimIncomingAirSession();
    await _gestureService.stop();
    await Future.delayed(const Duration(milliseconds: 350));
    if (mounted) {
      Navigator.of(context).pop(true);
    }
  }

  void _startHoldCountdown() {
    _countdownTimer?.cancel();
    _holdStartedAt = DateTime.now();
    setState(() {
      _isHolding = true;
      _holdProgress = 1.0;
      _remainingSeconds = _holdDuration.inSeconds;
    });

    _countdownTimer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (!mounted || _holdStartedAt == null) return;
      final elapsed = DateTime.now().difference(_holdStartedAt!);
      final remainingMs =
          (_holdDuration.inMilliseconds - elapsed.inMilliseconds)
              .clamp(0, _holdDuration.inMilliseconds);
      if (remainingMs <= 0) {
        _stopHoldCountdown();
        _showHint('Air Grab timed out — close your fist again to re-grab.');
        if (widget.mode == AirGestureMode.sender && !_gestureService.isRunning) {
          unawaited(_gestureService.start());
        }
        return;
      }
      setState(() {
        _holdProgress = remainingMs / _holdDuration.inMilliseconds;
        _remainingSeconds = (remainingMs / 1000).ceil();
      });
    });
  }

  void _stopHoldCountdown() {
    _countdownTimer?.cancel();
    _countdownTimer = null;
    _holdStartedAt = null;
    if (mounted) {
      setState(() {
        _isHolding = false;
        _holdProgress = 0.0;
        _remainingSeconds = 0;
      });
    }
  }

  void _showHint(String text) {
    _hintTimer?.cancel();
    setState(() => _hintToast = text);
    _hintTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) {
        setState(() => _hintToast = null);
      }
    });
  }

  Future<void> _handleClose() async {
    _stopHoldCountdown();
    final devProv = _deviceProvider ??
        Provider.of<DeviceProvider>(context, listen: false);
    if (widget.mode == AirGestureMode.sender && devProv.isHoldingAirSession) {
      await devProv.cancelAirGrab();
    } else if (widget.mode == AirGestureMode.receiver) {
      devProv.stopAirReceiverScan(notify: true);
    }
    await _gestureService.stop();
    if (mounted) {
      Navigator.of(context).pop(false);
    }
  }

  @override
  void dispose() {
    _countdownTimer?.cancel();
    _hintTimer?.cancel();
    _frameSub?.cancel();
    _pulseController.dispose();
    if (widget.mode == AirGestureMode.receiver) {
      _deviceProvider?.stopAirReceiverScan(notify: false);
    }
    unawaited(_gestureService.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final devProv = context.watch<DeviceProvider>();
    final incoming = devProv.activeIncomingAirSession;
    final frame = _latestFrame;

    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 24),
      child: Container(
        constraints: const BoxConstraints(maxWidth: 420),
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: const Color(0xFF101521).withValues(alpha: 0.96),
          borderRadius: BorderRadius.circular(28),
          border: Border.all(
            color: (_isHolding || _caughtSuccess)
                ? AppColors.secondary
                : Colors.white.withValues(alpha: 0.16),
            width: 2.0,
          ),
          boxShadow: [
            BoxShadow(
              color: (_isHolding || _caughtSuccess
                      ? AppColors.secondary
                      : AppColors.primary)
                  .withValues(alpha: 0.28),
              blurRadius: 32,
              spreadRadius: 2,
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(9),
                  decoration: BoxDecoration(
                    color: AppColors.primary.withValues(alpha: 0.2),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    widget.mode == AirGestureMode.sender
                        ? Icons.pan_tool_alt_rounded
                        : Icons.back_hand_rounded,
                    color: AppColors.secondary,
                    size: 20,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.mode == AirGestureMode.sender
                            ? 'Air Grab Mode'
                            : 'Air Catch Mode',
                        style: const TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w800,
                          color: Colors.white,
                        ),
                      ),
                      Text(
                        'On-device AI hand tracking (no video saved)',
                        style: TextStyle(
                          fontSize: 11.5,
                          color: Colors.white.withValues(alpha: 0.65),
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  onPressed: _handleClose,
                  icon: const Icon(Icons.close_rounded, color: Colors.white70),
                  tooltip: 'Close',
                ),
              ],
            ),
            const SizedBox(height: 14),
            if (_errorMessage != null)
              _buildErrorState()
            else ...[
              if (widget.mode == AirGestureMode.sender)
                _buildPayloadPill(
                  '${widget.fileCount} file${widget.fileCount == 1 ? '' : 's'} ready: ${widget.previewName}',
                )
              else if (incoming != null)
                _buildPayloadPill(
                  '✨ ${incoming.sender.name} holds ${incoming.previewName}',
                  highlight: true,
                )
              else
                _buildPayloadPill('Waiting for nearby Air Grab...'),
              if (devProv.airDirectStatusMessage != null) ...[
                const SizedBox(height: 10),
                _buildDirectStatusBanner(devProv.airDirectStatusMessage!),
              ] else if (Platform.isAndroid &&
                  !devProv.isWifiEnabled &&
                  !devProv.hasLanIp &&
                  devProv.activeHotspotInfo == null) ...[
                const SizedBox(height: 10),
                _buildWifiCautionBanner(devProv),
              ],
              const SizedBox(height: 14),
              AspectRatio(
                aspectRatio: 1.0,
                child: Container(
                  decoration: BoxDecoration(
                    color: const Color(0xFF090D16),
                    borderRadius: BorderRadius.circular(24),
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.12),
                    ),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(24),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        AnimatedBuilder(
                          animation: _pulseController,
                          builder: (_, _) {
                            return CustomPaint(
                              painter: _HandConstellationPainter(
                                frame: frame,
                                isHolding: _isHolding || _caughtSuccess,
                                pulseValue: _pulseController.value,
                                isReceiver:
                                    widget.mode == AirGestureMode.receiver,
                              ),
                            );
                          },
                        ),
                        if (_initializing)
                          const Center(
                            child: CircularProgressIndicator(
                              color: AppColors.secondary,
                            ),
                          ),
                        Positioned(
                          top: 12,
                          left: 12,
                          child: _buildPostureBadge(frame),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              if (_isHolding) ...[
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: LinearProgressIndicator(
                    value: _holdProgress,
                    minHeight: 6,
                    backgroundColor: Colors.white.withValues(alpha: 0.12),
                    valueColor: const AlwaysStoppedAnimation<Color>(
                      AppColors.secondary,
                    ),
                  ),
                ),
                const SizedBox(height: 8),
              ],
              Text(
                _buildInstructionText(frame, incoming != null),
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: Colors.white,
                ),
              ),
              if (_hintToast != null) ...[
                const SizedBox(height: 6),
                Text(
                  _hintToast!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppColors.accent,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ],
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: BouncingCard(
                onTap: _handleClose,
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.18),
                    ),
                  ),
                  alignment: Alignment.center,
                  child: const Text(
                    'Cancel',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                      fontSize: 14,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildErrorState() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 20),
      child: Column(
        children: [
          const Icon(
            Icons.videocam_off_rounded,
            size: 46,
            color: AppColors.warning,
          ),
          const SizedBox(height: 12),
          Text(
            _errorMessage ?? 'Unable to start camera',
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (_permissionDenied) ...[
            const SizedBox(height: 14),
            ElevatedButton.icon(
              onPressed: () => _permissionService.openSettings(),
              icon: const Icon(Icons.settings_rounded, size: 18),
              label: const Text('Open App Settings'),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildDirectStatusBanner(String message) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: AppColors.secondary.withValues(alpha: 0.16),
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
              message,
              style: const TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w700,
                color: Colors.white,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildWifiCautionBanner(DeviceProvider devProv) {
    final hotspot = devProv.activeHotspotInfo;
    if (hotspot != null) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: AppColors.secondary.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: AppColors.secondary.withValues(alpha: 0.50),
          ),
        ),
        child: Row(
          children: [
            const Icon(
              Icons.wifi_tethering_rounded,
              size: 18,
              color: AppColors.secondary,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Hotspot active (${hotspot.ssid}) — connect the other device to this hotspot or scan QR.',
                style: const TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                  color: Colors.white,
                ),
              ),
            ),
          ],
        ),
      );
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: AppColors.warning.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: AppColors.warning.withValues(alpha: 0.65),
        ),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.wifi_off_rounded,
            size: 18,
            color: AppColors.warning,
          ),
          const SizedBox(width: 8),
          const Expanded(
            child: Text(
              'Wi-Fi is OFF — turn on Wi-Fi so Air Hotspot auto-connects (no router needed).',
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w700,
                color: Colors.white,
              ),
            ),
          ),
          const SizedBox(width: 8),
          TextButton(
            onPressed: () async {
              await devProv.openWifiSettings();
              await Future.delayed(const Duration(milliseconds: 500));
              await devProv.refreshNetworkStatus(forceRefresh: true);
            },
            style: TextButton.styleFrom(
              backgroundColor: AppColors.warning,
              foregroundColor: Colors.black,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
            child: const Text(
              'Turn On',
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPayloadPill(String text, {bool highlight = false}) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: highlight
            ? AppColors.receivePrimary.withValues(alpha: 0.20)
            : Colors.white.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: highlight
              ? AppColors.receiveSecondary.withValues(alpha: 0.65)
              : Colors.white.withValues(alpha: 0.14),
        ),
      ),
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        textAlign: TextAlign.center,
        style: TextStyle(
          fontSize: 12.5,
          fontWeight: FontWeight.w700,
          color: highlight ? AppColors.receiveSecondary : Colors.white70,
        ),
      ),
    );
  }

  Widget _buildPostureBadge(AirGestureFrame? frame) {
    final String label;
    final Color color;
    if (_isHolding) {
      label = 'Locked in Air';
      color = AppColors.accent;
    } else if (_caughtSuccess) {
      label = 'Caught!';
      color = AppColors.receiveSecondary;
    } else if (frame == null || !frame.detected) {
      label = 'Searching hand...';
      color = Colors.white54;
    } else if (frame.posture == HandPosture.open) {
      label = 'Open Palm';
      color = AppColors.secondary;
    } else if (frame.posture == HandPosture.fist) {
      label = 'Fist Closed';
      color = AppColors.accent;
    } else {
      label = 'Hand Locked';
      color = Colors.white;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.55)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w700,
              color: color,
            ),
          ),
        ],
      ),
    );
  }

  String _buildInstructionText(AirGestureFrame? frame, bool hasIncoming) {
    if (_caughtSuccess) {
      return '✨ Caught! Starting P2P transfer...';
    }
    if (widget.mode == AirGestureMode.sender) {
      if (_isHolding) {
        return 'Holding in air (${_remainingSeconds}s)!\nOpen hand on other device to catch, or open palm here to cancel.';
      }
      if (frame == null || !frame.detected) {
        return 'Hold your bare hand up in front of the selfie camera';
      }
      if (frame.posture == HandPosture.open) {
        return 'Now close your hand into a FIST to grab!';
      }
      return 'Show an open palm, then close into a fist to grab';
    } else {
      if (!hasIncoming) {
        return 'Grab files on the sender phone first, then open your fist here';
      }
      if (frame == null || !frame.detected) {
        return 'Bring your closed fist in front of the selfie camera';
      }
      if (frame.posture == HandPosture.fist) {
        return 'Now OPEN your hand to catch the files!';
      }
      return 'Show a closed fist, then open your hand to release & receive';
    }
  }
}

class _HandConstellationPainter extends CustomPainter {
  final AirGestureFrame? frame;
  final bool isHolding;
  final double pulseValue;
  final bool isReceiver;

  static const List<(int, int)> _connections = [
    (0, 1), (1, 2), (2, 3), (3, 4),       // Thumb
    (0, 5), (5, 6), (6, 7), (7, 8),       // Index
    (0, 9), (9, 10), (10, 11), (11, 12),  // Middle
    (0, 13), (13, 14), (14, 15), (15, 16),// Ring
    (0, 17), (17, 18), (18, 19), (19, 20),// Pinky
    (5, 9), (9, 13), (13, 17),            // Palm bridge
  ];

  const _HandConstellationPainter({
    required this.frame,
    required this.isHolding,
    required this.pulseValue,
    required this.isReceiver,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final baseColor = isHolding
        ? AppColors.secondary
        : (isReceiver ? AppColors.receiveSecondary : AppColors.primaryLight);

    // Draw subtle tech grid
    final gridPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.04)
      ..strokeWidth = 1;
    const step = 36.0;
    for (double x = step; x < size.width; x += step) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), gridPaint);
    }
    for (double y = step; y < size.height; y += step) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
    }

    final current = frame;
    if (current == null || !current.detected || current.landmarks.length < 21) {
      if (isHolding && !isReceiver) {
        final center = Offset(size.width / 2, size.height / 2);
        final orbRadius = 28.0 + 10.0 * pulseValue;

        final glowPaint = Paint()
          ..color = AppColors.accent.withValues(alpha: 0.40)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 26);
        canvas.drawCircle(center, orbRadius * 1.6, glowPaint);

        final outerRingPaint = Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.6
          ..color =
              AppColors.secondary.withValues(alpha: 0.45 + 0.45 * pulseValue);
        canvas.drawCircle(center, orbRadius * 1.45, outerRingPaint);

        final ringPaint = Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3.4
          ..color = AppColors.accent;
        canvas.drawCircle(center, orbRadius, ringPaint);

        canvas.drawCircle(
          center,
          12.0 + 3.0 * pulseValue,
          Paint()..color = Colors.white.withValues(alpha: 0.94),
        );
        return;
      }

      final center = Offset(size.width / 2, size.height / 2);
      final ringPaint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.0
        ..color = baseColor.withValues(alpha: 0.25 + 0.35 * pulseValue);
      canvas.drawCircle(center, 44 + 14 * pulseValue, ringPaint);
      canvas.drawCircle(
        center,
        22 + 6 * pulseValue,
        ringPaint..color = baseColor.withValues(alpha: 0.45),
      );
      return;
    }

    Offset toCanvas(HandLandmark lm) => Offset(
          lm.x.clamp(0.0, 1.0) * size.width,
          lm.y.clamp(0.0, 1.0) * size.height,
        );

    final bonePaint = Paint()
      ..color = baseColor.withValues(alpha: 0.55)
      ..strokeWidth = 2.4
      ..strokeCap = StrokeCap.round;

    for (final (a, b) in _connections) {
      canvas.drawLine(
        toCanvas(current.landmarks[a]),
        toCanvas(current.landmarks[b]),
        bonePaint,
      );
    }

    final jointPaint = Paint()..color = Colors.white;
    for (int i = 0; i < current.landmarks.length; i++) {
      final pt = toCanvas(current.landmarks[i]);
      final isTip = i == 4 || i == 8 || i == 12 || i == 16 || i == 20;
      canvas.drawCircle(pt, isTip ? 5.0 : 3.2, jointPaint);
    }

    // Glowing holographic orb at palm center
    final orbPos = Offset(
      current.handCenter.dx * size.width,
      current.handCenter.dy * size.height,
    );
    final orbRadius = 16.0 + (26.0 * current.openness);
    final orbColor = isHolding ? AppColors.accent : baseColor;

    final glowPaint = Paint()
      ..color = orbColor.withValues(alpha: isHolding ? 0.45 : 0.28)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 18);
    canvas.drawCircle(orbPos, orbRadius * 1.35, glowPaint);

    final ringPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = isHolding ? 3.2 : 2.2
      ..color = orbColor;
    canvas.drawCircle(orbPos, orbRadius, ringPaint);

    if (isHolding) {
      canvas.drawCircle(
        orbPos,
        10.0 + 3.0 * pulseValue,
        Paint()..color = Colors.white.withValues(alpha: 0.92),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _HandConstellationPainter oldDelegate) {
    return oldDelegate.frame != frame ||
        oldDelegate.isHolding != isHolding ||
        oldDelegate.pulseValue != pulseValue ||
        oldDelegate.isReceiver != isReceiver;
  }
}
