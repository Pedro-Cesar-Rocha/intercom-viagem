import 'dart:math';

import 'package:flutter/material.dart';

import '../theme.dart';

/// Fundo escuro com um brilho quente no canto.
class AppBackground extends StatelessWidget {
  const AppBackground({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF131B2C), AppColors.bg0, AppColors.bg0],
          stops: [0, 0.55, 1],
        ),
      ),
      child: Stack(
        children: [
          Positioned(
            top: -140,
            right: -100,
            child: IgnorePointer(
              child: Container(
                width: 320,
                height: 320,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(colors: [
                    AppColors.orange.withValues(alpha: 0.20),
                    AppColors.orange.withValues(alpha: 0.0),
                  ]),
                ),
              ),
            ),
          ),
          Positioned.fill(child: child),
        ],
      ),
    );
  }
}

/// Ícone do app: ondas de rádio saindo de um ponto.
class ComboioLogo extends StatelessWidget {
  const ComboioLogo({super.key, this.size = 64});

  final double size;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(painter: _LogoPainter()),
    );
  }
}

class _LogoPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size s) {
    final rect = Offset.zero & s;
    final rrect = RRect.fromRectAndRadius(rect, Radius.circular(s.width * 0.28));
    final bg = Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [AppColors.amber, AppColors.orange],
      ).createShader(rect);
    canvas.drawRRect(rrect, bg);

    final c = Offset(s.width / 2, s.height / 2);
    canvas.drawCircle(c, s.width * 0.08, Paint()..color = Colors.white);
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = s.width * 0.065
      ..strokeCap = StrokeCap.round;
    const sweep = 1.15;
    for (var i = 1; i <= 2; i++) {
      final r = s.width * (0.13 + 0.115 * i);
      final arc = Rect.fromCircle(center: c, radius: r);
      stroke.color = Colors.white.withValues(alpha: i == 1 ? 1.0 : 0.72);
      canvas.drawArc(arc, -sweep / 2, sweep, false, stroke);
      canvas.drawArc(arc, pi - sweep / 2, sweep, false, stroke);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// Pílula de status com um ponto (que pulsa quando algo está acontecendo).
class StatusPill extends StatelessWidget {
  const StatusPill({
    super.key,
    required this.label,
    required this.color,
    this.pulse = false,
  });

  final String label;
  final Color color;
  final bool pulse;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.13),
        borderRadius: BorderRadius.circular(99),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          PulsingDot(color: color, pulse: pulse),
          const SizedBox(width: 7),
          Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 12.5,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.2,
            ),
          ),
        ],
      ),
    );
  }
}

class PulsingDot extends StatefulWidget {
  const PulsingDot({super.key, required this.color, this.pulse = false, this.size = 8});

  final Color color;
  final bool pulse;
  final double size;

  @override
  State<PulsingDot> createState() => _PulsingDotState();
}

class _PulsingDotState extends State<PulsingDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  );

  @override
  void initState() {
    super.initState();
    if (widget.pulse) _c.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(covariant PulsingDot oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.pulse && !_c.isAnimating) {
      _c.repeat(reverse: true);
    } else if (!widget.pulse && _c.isAnimating) {
      _c.stop();
      _c.value = 1;
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) {
        final t = widget.pulse ? 0.35 + 0.65 * _c.value : 1.0;
        return Container(
          width: widget.size,
          height: widget.size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: widget.color.withValues(alpha: t),
            boxShadow: [
              BoxShadow(
                color: widget.color.withValues(alpha: 0.5 * t),
                blurRadius: 6,
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Cartão grande de ação da tela inicial.
class ActionCard extends StatelessWidget {
  const ActionCard({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.primary = false,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final bool primary;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(24);
    final decoration = primary
        ? BoxDecoration(
            borderRadius: radius,
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [AppColors.amber, AppColors.orange],
            ),
            boxShadow: [
              BoxShadow(
                color: AppColors.orange.withValues(alpha: 0.32),
                blurRadius: 26,
                offset: const Offset(0, 10),
              ),
            ],
          )
        : BoxDecoration(
            borderRadius: radius,
            color: AppColors.surface,
            border: Border.all(color: AppColors.outline),
          );
    final fg = primary ? AppColors.onAmber : AppColors.text;
    final sub = primary ? const Color(0xFF5A3307) : AppColors.textDim;
    return DecoratedBox(
      decoration: decoration,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: radius,
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Row(
              children: [
                Container(
                  width: 54,
                  height: 54,
                  decoration: BoxDecoration(
                    color: primary
                        ? Colors.white.withValues(alpha: 0.28)
                        : AppColors.surfaceHigh,
                    borderRadius: BorderRadius.circular(17),
                  ),
                  child: Icon(icon,
                      color: primary ? fg : AppColors.amber, size: 28),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: TextStyle(
                          color: fg,
                          fontSize: 18.5,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        subtitle,
                        style: TextStyle(color: sub, fontSize: 13.5, height: 1.3),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Icon(Icons.arrow_forward_rounded,
                    color: fg.withValues(alpha: 0.8)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Botão redondo pequeno com legenda (barra de controles).
class RoundControl extends StatelessWidget {
  const RoundControl({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.active = false,
    this.danger = false,
    this.size = 58,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool active;
  final bool danger;
  final double size;

  @override
  Widget build(BuildContext context) {
    final Color bg;
    final Color fg;
    final Color border;
    if (danger) {
      bg = AppColors.danger.withValues(alpha: 0.16);
      fg = AppColors.danger;
      border = AppColors.danger.withValues(alpha: 0.45);
    } else if (active) {
      bg = AppColors.amber.withValues(alpha: 0.16);
      fg = AppColors.amber;
      border = AppColors.amber.withValues(alpha: 0.45);
    } else {
      bg = AppColors.surfaceHigh;
      fg = AppColors.text;
      border = AppColors.outline;
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Material(
          color: bg,
          shape: CircleBorder(side: BorderSide(color: border)),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onTap,
            child: SizedBox(
              width: size,
              height: size,
              child: Icon(icon, color: fg, size: 26),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          label,
          style: const TextStyle(
            color: AppColors.textDim,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}

/// Botão grande do microfone, com um halo que acompanha a voz.
class MicButton extends StatelessWidget {
  const MicButton({
    super.key,
    required this.muted,
    required this.level,
    required this.onTap,
  });

  final bool muted;
  final double level;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    const size = 84.0;
    final glow = muted ? 0.0 : (sqrt(level) * 1.7).clamp(0.0, 1.0);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: size + 40,
          height: size + 40,
          child: Stack(
            alignment: Alignment.center,
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeOut,
                width: size + 6 + 34 * glow,
                height: size + 6 + 34 * glow,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: muted
                      ? Colors.transparent
                      : AppColors.amber.withValues(alpha: 0.10 + 0.20 * glow),
                ),
              ),
              Material(
                shape: const CircleBorder(),
                clipBehavior: Clip.antiAlias,
                color: Colors.transparent,
                child: InkWell(
                  onTap: onTap,
                  child: Ink(
                    width: size,
                    height: size,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: muted
                          ? null
                          : const LinearGradient(
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                              colors: [AppColors.amber, AppColors.orange],
                            ),
                      color: muted ? AppColors.surfaceHigh : null,
                      border: muted
                          ? Border.all(
                              color: AppColors.danger.withValues(alpha: 0.7),
                              width: 2)
                          : null,
                    ),
                    child: Center(
                      child: Icon(
                        muted ? Icons.mic_off_rounded : Icons.mic_rounded,
                        size: 38,
                        color: muted ? AppColors.danger : AppColors.onAmber,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        Text(
          muted ? 'Mudo' : 'Microfone ligado',
          style: TextStyle(
            color: muted ? AppColors.danger : AppColors.textDim,
            fontSize: 12,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }
}

/// Faixa de aviso discreta.
class NoticeBanner extends StatelessWidget {
  const NoticeBanner({
    super.key,
    required this.text,
    this.icon = Icons.info_outline_rounded,
    this.color = AppColors.warning,
  });

  final String text;
  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withValues(alpha: 0.30)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(color: AppColors.text, fontSize: 13.5, height: 1.35),
            ),
          ),
        ],
      ),
    );
  }
}

/// Linha numerada de instruções.
class StepLine extends StatelessWidget {
  const StepLine({super.key, required this.number, required this.text});

  final int number;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 26,
            height: 26,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: AppColors.amber.withValues(alpha: 0.15),
              shape: BoxShape.circle,
            ),
            child: Text(
              '$number',
              style: const TextStyle(
                color: AppColors.amber,
                fontWeight: FontWeight.w800,
                fontSize: 13,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Text(
                text,
                style: const TextStyle(color: AppColors.text, fontSize: 14, height: 1.35),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
