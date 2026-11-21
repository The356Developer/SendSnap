import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../config/constants.dart';

/// Style A — Clean Comic / Marker Sketch Container.
/// Replaces heavy glassmorphism blur with crisp dark ink outlines,
/// subtle double-pass hand-sketched pen corners, warm paper surface fill,
/// and a solid offset comic ink block shadow.
class GlassContainer extends StatelessWidget {
  final Widget child;
  final double blur;
  final double opacity;
  final double borderRadius;
  final EdgeInsetsGeometry? padding;
  final EdgeInsetsGeometry? margin;
  final Color? color;
  final Color? borderColor;
  final double borderWidth;
  final List<BoxShadow>? boxShadow;
  final VoidCallback? onTap;

  const GlassContainer({
    super.key,
    required this.child,
    this.blur = 10,
    this.opacity = 0.70,
    this.borderRadius = 24,
    this.padding,
    this.margin,
    this.color,
    this.borderColor,
    this.borderWidth = 1.8,
    this.boxShadow,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final fillColor = color ??
        (isDark ? const Color(0xFF1C2029) : AppColors.surface);
    final inkColor = (borderColor != null && borderColor != Colors.white)
        ? borderColor!
        : (isDark ? AppColors.chalkInk : AppColors.ink);
    final shadowInk = isDark
        ? Colors.black.withValues(alpha: 0.75)
        : AppColors.ink.withValues(alpha: 0.88);
    final effectiveStrokeWidth = borderWidth < 1.6 ? 1.8 : borderWidth;
    final radius = borderRadius.clamp(12.0, 26.0);

    Widget content = CustomPaint(
      painter: _ComicSketchCardPainter(
        fillColor: fillColor,
        inkColor: inkColor,
        shadowColor: shadowInk,
        borderRadius: radius,
        strokeWidth: effectiveStrokeWidth,
      ),
      child: Container(
        padding: padding ?? const EdgeInsets.all(20),
        child: child,
      ),
    );

    if (margin != null) {
      content = Padding(padding: margin!, child: content);
    }

    if (onTap != null) {
      return GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: content,
      );
    }

    return content;
  }
}

class _ComicSketchCardPainter extends CustomPainter {
  final Color fillColor;
  final Color inkColor;
  final Color shadowColor;
  final double borderRadius;
  final double strokeWidth;

  const _ComicSketchCardPainter({
    required this.fillColor,
    required this.inkColor,
    required this.shadowColor,
    required this.borderRadius,
    required this.strokeWidth,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final rrect = RRect.fromRectAndRadius(rect, Radius.circular(borderRadius));

    // 1. Offset solid comic ink block shadow
    final shadowRRect = rrect.shift(const Offset(3.5, 4.0));
    final shadowPaint = Paint()
      ..color = shadowColor
      ..style = PaintingStyle.fill;
    canvas.drawRRect(shadowRRect, shadowPaint);

    // 2. Warm paper / card surface fill
    final fillPaint = Paint()
      ..color = fillColor
      ..style = PaintingStyle.fill;
    canvas.drawRRect(rrect, fillPaint);

    // 3. Primary crisp marker/ink outline
    final borderPaint = Paint()
      ..color = inkColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeJoin = StrokeJoin.round;
    canvas.drawRRect(rrect, borderPaint);

    // 4. Subtle hand-sketched secondary over-stroke along top-left & bottom-right
    final sketchAccentPaint = Paint()
      ..color = inkColor.withValues(alpha: 0.32)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.9
      ..strokeCap = StrokeCap.round;

    final insetRect = rect.deflate(1.1);
    final insetRRect = RRect.fromRectAndRadius(
      insetRect,
      Radius.circular(math.max(4.0, borderRadius - 1.2)),
    );
    canvas.drawRRect(insetRRect, sketchAccentPaint);
  }

  @override
  bool shouldRepaint(covariant _ComicSketchCardPainter oldDelegate) {
    return oldDelegate.fillColor != fillColor ||
        oldDelegate.inkColor != inkColor ||
        oldDelegate.shadowColor != shadowColor ||
        oldDelegate.borderRadius != borderRadius ||
        oldDelegate.strokeWidth != strokeWidth;
  }
}
