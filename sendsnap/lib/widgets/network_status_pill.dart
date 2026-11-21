import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../config/constants.dart';
import '../l10n/app_localizations.dart';
import '../providers/device_provider.dart';
import 'glass_container.dart';
import 'bouncing_card.dart';
import 'network_diagnostics_sheet.dart';

/// A sleek, interactive network status pill.
/// Shows current Wi-Fi / Direct Wi-Fi status and opens the Network Diagnostics Sheet on tap.
class NetworkStatusPill extends StatefulWidget {
  final DeviceProvider devProv;

  const NetworkStatusPill({super.key, required this.devProv});

  @override
  State<NetworkStatusPill> createState() => _NetworkStatusPillState();
}

class _NetworkStatusPillState extends State<NetworkStatusPill>
    with SingleTickerProviderStateMixin {
  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1600),
    )..repeat(reverse: true);

    _pulseAnimation = CurvedAnimation(
      parent: _pulseController,
      curve: Curves.easeInOut,
    );
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  String _buildLabel(BuildContext context, bool isReady) {
    final l10n = AppLocalizations.of(context);
    if (!isReady) {
      return l10n?.homeWifiDisconnected ?? 'No Wi-Fi';
    }
    final base = l10n?.homeWifiConnected ?? 'Wi-Fi Connected';
    if (!widget.devProv.isAdvertising && widget.devProv.warmDiscoveredCount > 0) {
      return '$base • ${widget.devProv.warmDiscoveredCount} nearby';
    }
    return base;
  }

  @override
  Widget build(BuildContext context) {
    final hasLan = widget.devProv.hasLanIp;
    final hasDirect = widget.devProv.hasDirectWifiReady;
    final isReady = hasLan || hasDirect;
    final dotColor = isReady ? AppColors.success : AppColors.warning;

    return BouncingCard(
      onTap: () {
        HapticFeedback.selectionClick();
        NetworkDiagnosticsSheet.show(context, widget.devProv);
      },
      child: GlassContainer(
        blur: 16,
        opacity: 0.70,
        borderRadius: 22,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Pulsing dot indicator
            AnimatedBuilder(
              animation: _pulseAnimation,
              builder: (context, child) {
                return Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: dotColor,
                    boxShadow: [
                      BoxShadow(
                        color: dotColor.withValues(
                          alpha: 0.4 + (_pulseAnimation.value * 0.4),
                        ),
                        blurRadius: 6 + (_pulseAnimation.value * 4),
                        spreadRadius: 1,
                      ),
                    ],
                  ),
                );
              },
            ),
            const SizedBox(width: 8),

            // Network Info Text
            Text(
              _buildLabel(context, isReady),
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: isReady ? AppColors.textSecondaryOf(context) : AppColors.warning,
              ),
            ),
            const SizedBox(width: 6),

            // Info icon
            Icon(
              Icons.info_outline_rounded,
              size: 13,
              color: isReady ? AppColors.textSecondaryOf(context) : AppColors.warning,
            ),
          ],
        ),
      ),
    );
  }
}
