import 'dart:math';
import 'package:flutter/material.dart';
import '../config/constants.dart';

/// Style A — Hand-Sketched Ink Ripple Radar.
/// Draws organic hand-inked concentric rings, sketch compass ticks,
/// and a bold comic-outlined center beacon.
class RadarWidget extends StatefulWidget {
  final bool active;
  final String label;

  const RadarWidget({
    super.key,
    required this.active,
    this.label = 'Searching...',
  });

  @override
  State<RadarWidget> createState() => _RadarWidgetState();
}

class _RadarWidgetState extends State<RadarWidget>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2200),
    );
    if (widget.active) _controller.repeat();
  }

  @override
  void didUpdateWidget(RadarWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && !_controller.isAnimating) {
      _controller.repeat();
    } else if (!widget.active && _controller.isAnimating) {
      _controller.stop();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final inkColor = isDark ? AppColors.chalkInk : AppColors.ink;
    final pillFill = isDark ? const Color(0xFF1C2029) : AppColors.surface;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        RepaintBoundary(
          child: SizedBox(
            height: 200,
            width: 200,
            child: Stack(
              alignment: Alignment.center,
              children: [
                if (widget.active)
                  CustomPaint(
                    size: const Size(200, 200),
                    painter: _SketchRadarPainter(
                      animation: _controller,
                      inkColor: inkColor,
                    ),
                  ),

                // Center Comic-Outlined Beacon Orb
                Container(
                  width: 74,
                  height: 74,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: AppColors.primary,
                    border: Border.all(
                      color: inkColor,
                      width: 2.5,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: isDark
                            ? Colors.black.withValues(alpha: 0.8)
                            : AppColors.ink,
                        blurRadius: 0,
                        offset: const Offset(3.5, 4.0),
                      ),
                    ],
                  ),
                  child: const Center(
                    child: Icon(
                      Icons.wifi_tethering_rounded,
                      color: Colors.white,
                      size: 34,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),

        // Comic Ink Status Pill
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
          decoration: BoxDecoration(
            color: pillFill,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: inkColor,
              width: 1.8,
            ),
            boxShadow: [
              BoxShadow(
                color: isDark
                    ? Colors.black.withValues(alpha: 0.75)
                    : AppColors.ink,
                blurRadius: 0,
                offset: const Offset(2.5, 3.0),
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: AppColors.primary,
                  border: Border.all(color: inkColor, width: 1.2),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                widget.label,
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w800,
                  color: inkColor,
                  letterSpacing: 0.2,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _SketchRadarPainter extends CustomPainter {
  final Animation<double> animation;
  final Color inkColor;

  _SketchRadarPainter({
    required this.animation,
    required this.inkColor,
  }) : super(repaint: animation);

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final maxRadius = size.width / 2;
    final val = animation.value;

    // 1. Subtle hand-drawn compass tick marks
    final tickPaint = Paint()
      ..color = inkColor.withValues(alpha: 0.18)
      ..strokeWidth = 1.4
      ..strokeCap = StrokeCap.round;
    for (int a = 0; a < 12; a++) {
      final angle = a * (pi / 6);
      final p1 = Offset(
        center.dx + cos(angle) * (maxRadius - 14),
        center.dy + sin(angle) * (maxRadius - 14),
      );
      final p2 = Offset(
        center.dx + cos(angle) * (maxRadius - 6),
        center.dy + sin(angle) * (maxRadius - 6),
      );
      canvas.drawLine(p1, p2, tickPaint);
    }

    // 2. Three hand-sketched wobbling ink ripple waves + marker wash
    for (int i = 0; i < 3; i++) {
      final progress = (val + (i * 0.33)) % 1.0;
      final curve = Curves.easeOutCubic.transform(progress);
      final radius = 36.0 + (curve * (maxRadius - 40.0));
      final alpha = (1.0 - progress).clamp(0.0, 1.0);

      final path = _buildSketchedCirclePath(center, radius, seed: i + 1);

      // Marker wash ring
      final washPaint = Paint()
        ..color = AppColors.primary.withValues(alpha: alpha * 0.28)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 4.5;
      canvas.drawPath(path, washPaint);

      // Crisp dark ink sketch ring
      final strokePaint = Paint()
        ..color = inkColor.withValues(alpha: alpha * 0.55)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.8;
      canvas.drawPath(path, strokePaint);
    }
  }

  Path _buildSketchedCirclePath(Offset center, double radius, {required int seed}) {
    const int segments = 36;
    final path = Path();
    for (int s = 0; s <= segments; s++) {
      final theta = (s / segments) * 2 * pi;
      final wobble = sin(theta * 5 + seed * 1.7) * 1.6 +
          cos(theta * 3 - seed) * 1.1;
      final r = radius + wobble;
      final pt = Offset(
        center.dx + cos(theta) * r,
        center.dy + sin(theta) * r,
      );
      if (s == 0) {
        path.moveTo(pt.dx, pt.dy);
      } else {
        path.lineTo(pt.dx, pt.dy);
      }
    }
    path.close();
    return path;
  }

  @override
  bool shouldRepaint(covariant _SketchRadarPainter oldDelegate) =>
      oldDelegate.inkColor != inkColor;
}
