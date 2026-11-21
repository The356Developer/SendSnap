import 'package:flutter/material.dart';
import '../config/constants.dart';

/// Style A — Clean Comic / Marker Sketchbook Background.
/// Renders a warm sketchbook paper canvas (or charcoal slate in Dark Mode)
/// with an architect dot-grid and soft flat marker wash accents.
/// Zero GPU blur overhead, 120 FPS performance.
class AmbientBackground extends StatelessWidget {
  final Widget child;
  final bool isDark;

  const AmbientBackground({
    super.key,
    required this.child,
    this.isDark = false,
  });

  @override
  Widget build(BuildContext context) {
    final effectiveDark =
        isDark || Theme.of(context).brightness == Brightness.dark;
    final paperColor =
        effectiveDark ? const Color(0xFF14161C) : AppColors.background;

    return Stack(
      children: [
        Positioned.fill(
          child: ColoredBox(
            color: paperColor,
            child: CustomPaint(
              painter: _SketchbookPaperPainter(isDark: effectiveDark),
            ),
          ),
        ),
        Positioned.fill(child: child),
      ],
    );
  }
}

class _SketchbookPaperPainter extends CustomPainter {
  final bool isDark;

  const _SketchbookPaperPainter({required this.isDark});

  @override
  void paint(Canvas canvas, Size size) {
    // 1. Subtle flat marker highlight washes in corners
    final topWashPaint = Paint()
      ..color = AppColors.primary.withValues(alpha: isDark ? 0.08 : 0.05)
      ..style = PaintingStyle.fill;
    canvas.drawCircle(
      Offset(size.width * 0.12, size.height * 0.08),
      size.width * 0.36,
      topWashPaint,
    );

    final bottomWashPaint = Paint()
      ..color = AppColors.receivePrimary.withValues(alpha: isDark ? 0.07 : 0.05)
      ..style = PaintingStyle.fill;
    canvas.drawCircle(
      Offset(size.width * 0.88, size.height * 0.85),
      size.width * 0.34,
      bottomWashPaint,
    );

    // 2. Architect sketchbook dot-grid
    final dotPaint = Paint()
      ..color = (isDark ? Colors.white : AppColors.ink)
          .withValues(alpha: isDark ? 0.07 : 0.08)
      ..style = PaintingStyle.fill;

    const double step = 26.0;
    for (double x = 14.0; x < size.width; x += step) {
      for (double y = 14.0; y < size.height; y += step) {
        canvas.drawCircle(Offset(x, y), 1.15, dotPaint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _SketchbookPaperPainter oldDelegate) =>
      oldDelegate.isDark != isDark;
}
