import 'dart:math';

import 'package:flutter/material.dart';

import '../../call/intercom_controller.dart';
import '../../call/peer_link.dart';
import '../../core/prefs.dart';
import '../theme.dart';

double voiceGlow(double level) => (sqrt(level) * 1.7).clamp(0.0, 1.0);

/// Avatar com iniciais e um halo que cresce quando a pessoa fala.
class SpeakingAvatar extends StatelessWidget {
  const SpeakingAvatar({
    super.key,
    required this.name,
    required this.color,
    required this.level,
    this.size = 84,
    this.dimmed = false,
  });

  final String name;
  final Color color;
  final double level;
  final double size;
  final bool dimmed;

  @override
  Widget build(BuildContext context) {
    final glow = dimmed ? 0.0 : voiceGlow(level);
    final speaking = glow > 0.28;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: dimmed
              ? [AppColors.surfaceHigh, AppColors.surfaceHigh]
              : [color, Color.lerp(color, Colors.black, 0.35)!],
        ),
        border: Border.all(
          color: speaking ? Colors.white.withValues(alpha: 0.9) : Colors.transparent,
          width: 3,
        ),
        boxShadow: [
          BoxShadow(
            color: color.withValues(alpha: 0.55 * glow),
            blurRadius: 6 + 28 * glow,
            spreadRadius: 1 + 9 * glow,
          ),
        ],
      ),
      alignment: Alignment.center,
      child: Text(
        initialsOf(name),
        style: TextStyle(
          color: dimmed ? AppColors.textDim : const Color(0xFF10131A),
          fontSize: size * 0.34,
          fontWeight: FontWeight.w900,
          letterSpacing: -0.5,
        ),
      ),
    );
  }
}

class ParticipantTile extends StatelessWidget {
  const ParticipantTile({super.key, required this.p, this.onTap});

  final Participant p;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final color = AppColors.avatarFor(p.id);
    final reachable = p.isConnected;
    final glow = (p.muted || !reachable) ? 0.0 : voiceGlow(p.level);
    final speaking = glow > 0.28;
    final radius = BorderRadius.circular(26);
    return AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: radius,
        border: Border.all(
          color: speaking ? color.withValues(alpha: 0.9) : AppColors.outline,
          width: speaking ? 2 : 1,
        ),
        boxShadow: speaking
            ? [BoxShadow(color: color.withValues(alpha: 0.20), blurRadius: 26)]
            : const [],
      ),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: radius,
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 14),
            child: Column(
              children: [
                SizedBox(
                  height: 22,
                  child: Row(
                    children: [
                      if (p.isHost) const _Badge(label: 'HOST', color: AppColors.amber),
                      if (p.isMe) ...[
                        if (p.isHost) const SizedBox(width: 6),
                        const _Badge(label: 'VOCÊ', color: AppColors.teal),
                      ],
                      const Spacer(),
                      if (p.muted)
                        const Icon(Icons.mic_off_rounded,
                            size: 18, color: AppColors.danger),
                    ],
                  ),
                ),
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, c) {
                      // Encolhe com a tela, sem passar do espaço disponível.
                      final s = (min(c.maxWidth, c.maxHeight) * 0.84)
                          .clamp(0.0, 96.0);
                      if (s < 28) return const SizedBox.shrink();
                      return Center(
                        child: SpeakingAvatar(
                          name: p.name,
                          color: color,
                          level: p.muted ? 0 : p.level,
                          size: s,
                          dimmed: !reachable,
                        ),
                      );
                    },
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  p.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                    color: AppColors.text,
                  ),
                ),
                const SizedBox(height: 5),
                _StatusLine(p: p, speaking: speaking),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class EmptySlotTile extends StatelessWidget {
  const EmptySlotTile({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.bg1.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(26),
        border: Border.all(color: AppColors.outline.withValues(alpha: 0.7)),
      ),
      child: const Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.person_add_alt_1_rounded, color: AppColors.textFaint, size: 30),
          SizedBox(height: 8),
          Text(
            'Vaga livre',
            style: TextStyle(color: AppColors.textFaint, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 10,
          fontWeight: FontWeight.w900,
          letterSpacing: 0.8,
        ),
      ),
    );
  }
}

class _StatusLine extends StatelessWidget {
  const _StatusLine({required this.p, required this.speaking});

  final Participant p;
  final bool speaking;

  @override
  Widget build(BuildContext context) {
    if (p.isMe) {
      return _label(
        p.muted ? 'Microfone mudo' : (speaking ? 'Falando…' : 'No ar'),
        p.muted ? AppColors.danger : (speaking ? AppColors.amber : AppColors.textDim),
      );
    }
    if (!p.online) return _label('Reconectando…', AppColors.warning);
    return switch (p.link) {
      LinkStatus.connecting => _label('Conectando…', AppColors.textDim),
      LinkStatus.reconnecting => _label('Reconectando…', AppColors.warning),
      LinkStatus.connected => speaking
          ? _label('Falando…', AppColors.amber)
          : SignalIndicator(rttMs: p.rttMs, lossPct: p.lossPct),
    };
  }

  Widget _label(String text, Color color) => Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: color, fontSize: 12.5, fontWeight: FontWeight.w600),
      );
}

/// Três barrinhas de qualidade + atraso aproximado.
class SignalIndicator extends StatelessWidget {
  const SignalIndicator({super.key, this.rttMs, this.lossPct = 0});

  final double? rttMs;
  final double lossPct;

  int get bars {
    final rtt = rttMs ?? 0;
    if (lossPct > 8 || rtt > 300) return 1;
    if (lossPct > 3 || rtt > 140) return 2;
    return 3;
  }

  @override
  Widget build(BuildContext context) {
    final b = bars;
    final color = b == 3
        ? AppColors.success
        : (b == 2 ? AppColors.warning : AppColors.danger);
    final rtt = rttMs;
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        for (var i = 0; i < 3; i++)
          Container(
            width: 4,
            height: 6.0 + i * 4,
            margin: const EdgeInsets.only(right: 2),
            decoration: BoxDecoration(
              color: i < b ? color : AppColors.outline,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        const SizedBox(width: 6),
        Text(
          rtt == null ? 'Conectado' : '${rtt.round()} ms',
          style: const TextStyle(
            color: AppColors.textDim,
            fontSize: 12.5,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}
