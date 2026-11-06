import 'package:flutter/material.dart';

import '../theme.dart';

/// Animação de "procurando": ondas saindo do centro.
class Radar extends StatefulWidget {
  const Radar({
    super.key,
    required this.child,
    this.size = 220,
    this.color = AppColors.amber,
  });

  final Widget child;
  final double size;
  final Color color;

  @override
  State<Radar> createState() => _RadarState();
}

class _RadarState extends State<Radar> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2600),
  )..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          AnimatedBuilder(
            animation: _c,
            builder: (context, _) => CustomPaint(
              size: Size.square(widget.size),
              painter: _RadarPainter(_c.value, widget.color),
            ),
          ),
          widget.child,
        ],
      ),
    );
  }
}

class _RadarPainter extends CustomPainter {
  _RadarPainter(this.progress, this.color);

  final double progress;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final maxR = size.width / 2;
    for (var i = 0; i < 3; i++) {
      final t = (progress + i / 3) % 1.0;
      final r = maxR * (0.28 + 0.72 * t);
      final alpha = (1 - t) * 0.55;
      canvas.drawCircle(
        center,
        r,
        Paint()
          ..style = PaintingStyle.fill
          ..color = color.withValues(alpha: alpha * 0.10),
      );
      canvas.drawCircle(
        center,
        r,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = color.withValues(alpha: alpha),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _RadarPainter oldDelegate) =>
      oldDelegate.progress != progress || oldDelegate.color != color;
}
