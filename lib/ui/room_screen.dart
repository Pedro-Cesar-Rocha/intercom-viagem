import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../call/intercom_controller.dart';
import '../core/protocol.dart';
import 'sheets.dart';
import 'theme.dart';
import 'widgets/common.dart';
import 'widgets/participant_tile.dart';
import 'widgets/radar.dart';

class RoomScreen extends StatefulWidget {
  const RoomScreen({super.key, required this.controller});

  final IntercomController controller;

  @override
  State<RoomScreen> createState() => _RoomScreenState();
}

class _RoomScreenState extends State<RoomScreen> {
  StreamSubscription<String>? _toastSub;
  bool _popped = false;

  IntercomController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    _toastSub = c.toasts.listen((msg) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(
          content: Text(msg),
          duration: const Duration(seconds: 2),
        ));
    });
    c.addListener(_onChange);
  }

  @override
  void dispose() {
    unawaited(_toastSub?.cancel());
    c.removeListener(_onChange);
    super.dispose();
  }

  void _onChange() {
    if (c.phase == Phase.idle && !_popped) {
      _popped = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.of(context).pop();
      });
    }
  }

  bool get _freeToLeave =>
      c.phase == Phase.idle || c.phase == Phase.error || c.phase == Phase.ended;

  Future<void> _confirmLeave() async {
    if (_freeToLeave ||
        c.phase == Phase.preparing ||
        c.phase == Phase.searching ||
        (c.phase == Phase.connecting && !c.isHost)) {
      await c.leave();
      return;
    }
    final host = c.isHost;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: Text(host ? 'Encerrar a sala?' : 'Sair da sala?'),
        content: Text(host
            ? 'Todo mundo que está na sala será desconectado.'
            : 'Você pode entrar de novo quando quiser.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Continuar'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.danger,
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(host ? 'Encerrar' : 'Sair'),
          ),
        ],
      ),
    );
    if (ok == true) await c.leave();
  }

  Future<void> _askAddress() async {
    final ip = await showDialog<String>(
      context: context,
      builder: (ctx) => _AddressDialog(initial: c.hostAddress ?? ''),
    );
    if (ip == null || ip.trim().isEmpty) return;
    if (InternetAddress.tryParse(ip.trim()) == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Endereço inválido.')));
      return;
    }
    c.connectTo(ip);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        return PopScope<Object?>(
          canPop: _freeToLeave,
          onPopInvokedWithResult: (didPop, result) {
            if (didPop) {
              if (c.phase != Phase.idle) unawaited(c.leave());
              return;
            }
            unawaited(_confirmLeave());
          },
          child: Scaffold(
            body: AppBackground(
              child: SafeArea(
                child: Column(
                  children: [
                    _Header(c: c, onSettings: () => showSettingsSheet(context, c)),
                    Expanded(
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 280),
                        switchInCurve: Curves.easeOut,
                        switchOutCurve: Curves.easeIn,
                        child: _body(),
                      ),
                    ),
                    _bottomBar(),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _body() {
    return switch (c.phase) {
      Phase.idle || Phase.preparing => KeyedSubtree(
          key: const ValueKey('preparing'),
          child: _CenteredStatus(
            icon: Icons.graphic_eq_rounded,
            title: 'Preparando…',
            message: c.statusDetail,
            busy: true,
          ),
        ),
      Phase.searching || Phase.connecting => c.isHost
          ? KeyedSubtree(
              key: const ValueKey('opening'),
              child: _CenteredStatus(
                icon: Icons.wifi_tethering_rounded,
                title: 'Abrindo a sala…',
                message: c.statusDetail,
                busy: true,
              ),
            )
          : KeyedSubtree(
              key: const ValueKey('searching'),
              child: _SearchingView(c: c, onAskAddress: _askAddress),
            ),
      Phase.live || Phase.reconnecting => KeyedSubtree(
          key: const ValueKey('room'),
          child: _RoomView(
            c: c,
            onPeerTap: (id) => showPeerSheet(context, c, id),
          ),
        ),
      Phase.ended => KeyedSubtree(
          key: const ValueKey('ended'),
          child: _MessageView(
            icon: Icons.meeting_room_rounded,
            color: AppColors.textDim,
            title: 'A sala foi encerrada',
            message: 'Quem criou a sala saiu ou fechou o app.',
            primaryLabel: 'Procurar de novo',
            onPrimary: c.retry,
            secondaryLabel: 'Voltar ao início',
            onSecondary: c.leave,
          ),
        ),
      Phase.error => KeyedSubtree(
          key: const ValueKey('error'),
          child: _MessageView(
            icon: Icons.error_outline_rounded,
            color: AppColors.danger,
            title: c.errorTitle ?? 'Algo deu errado',
            message: c.errorMessage ?? '',
            primaryLabel:
                c.errorNeedsSettings ? 'Abrir ajustes' : 'Tentar de novo',
            onPrimary:
                c.errorNeedsSettings ? c.native.openAppSettings : c.retry,
            secondaryLabel: c.errorNeedsSettings ? 'Tentar de novo' : 'Voltar',
            onSecondary: c.errorNeedsSettings ? c.retry : c.leave,
          ),
        ),
    };
  }

  Widget _bottomBar() {
    final live = c.phase == Phase.live || c.phase == Phase.reconnecting;
    if (live) {
      return Container(
        padding: const EdgeInsets.fromLTRB(20, 10, 20, 14),
        decoration: BoxDecoration(
          color: AppColors.bg1.withValues(alpha: 0.92),
          border: const Border(top: BorderSide(color: AppColors.outline)),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: RoundControl(
                icon: c.speakerOn ? Icons.volume_up_rounded : Icons.hearing_rounded,
                label: c.speakerOn ? 'Viva-voz' : 'Fone',
                active: c.speakerOn,
                onTap: () => c.setSpeaker(!c.speakerOn),
              ),
            ),
            MicButton(muted: c.muted, level: c.myLevel, onTap: c.toggleMute),
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: RoundControl(
                icon: Icons.call_end_rounded,
                label: c.isHost ? 'Encerrar' : 'Sair',
                danger: true,
                onTap: _confirmLeave,
              ),
            ),
          ],
        ),
      );
    }
    if (c.phase == Phase.error || c.phase == Phase.ended || c.phase == Phase.idle) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 6, 20, 18),
      child: SizedBox(
        width: double.infinity,
        child: OutlinedButton.icon(
          style: OutlinedButton.styleFrom(
            foregroundColor: AppColors.text,
            side: const BorderSide(color: AppColors.outline),
            padding: const EdgeInsets.symmetric(vertical: 14),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          ),
          onPressed: _confirmLeave,
          icon: const Icon(Icons.close_rounded),
          label: const Text('Cancelar'),
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.c, required this.onSettings});

  final IntercomController c;
  final VoidCallback onSettings;

  @override
  Widget build(BuildContext context) {
    final (label, color, pulse) = _status();
    final title = c.roomName.isNotEmpty
        ? c.roomName
        : (c.isHost ? 'Sua sala' : 'Comboio');
    final live = c.phase == Phase.live || c.phase == Phase.reconnecting;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 10, 8, 6),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w900,
                    letterSpacing: -0.3,
                  ),
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    StatusPill(label: label, color: color, pulse: pulse),
                    if (live) ...[
                      const SizedBox(width: 10),
                      const Icon(Icons.group_rounded,
                          size: 16, color: AppColors.textDim),
                      const SizedBox(width: 4),
                      Text(
                        '${c.peopleCount}/${Proto.maxPeers}',
                        style: const TextStyle(
                          color: AppColors.textDim,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Ajustes',
            onPressed: onSettings,
            icon: const Icon(Icons.tune_rounded),
          ),
        ],
      ),
    );
  }

  (String, Color, bool) _status() {
    return switch (c.phase) {
      Phase.idle || Phase.preparing => ('Preparando', AppColors.amber, true),
      Phase.searching => ('Procurando a sala', AppColors.amber, true),
      Phase.connecting => ('Conectando', AppColors.amber, true),
      Phase.live => c.hubAlive
          ? ('No ar', AppColors.success, false)
          : ('Sinal fraco', AppColors.warning, true),
      Phase.reconnecting => ('Reconectando', AppColors.warning, true),
      Phase.ended => ('Encerrada', AppColors.textDim, false),
      Phase.error => ('Erro', AppColors.danger, false),
    };
  }
}

class _RoomView extends StatelessWidget {
  const _RoomView({required this.c, required this.onPeerTap});

  final IntercomController c;
  final void Function(String id) onPeerTap;

  @override
  Widget build(BuildContext context) {
    final people = c.participants.take(Proto.maxPeers).toList();
    return Column(
      children: [
        if (c.isHost) _HostBanner(c: c),
        if (c.phase == Phase.reconnecting && !c.isHost)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
            child: NoticeBanner(
              icon: Icons.sync_rounded,
              text: c.statusDetail.isEmpty
                  ? 'Reconectando com a sala…'
                  : c.statusDetail,
            ),
          )
        else if (c.phase == Phase.live && !c.hubAlive && !c.isHost)
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 6, 16, 0),
            child: NoticeBanner(
              icon: Icons.network_check_rounded,
              text: 'O sinal com o host está fraco. Fiquem mais perto do '
                  'celular que faz o hotspot.',
            ),
          ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            child: LayoutBuilder(
              builder: (context, box) {
                const gap = 14.0;
                final w = (box.maxWidth - gap) / 2;
                final h = (box.maxHeight - gap) / 2;
                final ratio = (w / (h <= 0 ? w : h)).clamp(0.55, 1.4);
                return GridView.count(
                  crossAxisCount: 2,
                  mainAxisSpacing: gap,
                  crossAxisSpacing: gap,
                  childAspectRatio: ratio,
                  physics: const NeverScrollableScrollPhysics(),
                  children: [
                    for (final p in people)
                      ParticipantTile(
                        key: ValueKey(p.id),
                        p: p,
                        onTap: p.isMe ? null : () => onPeerTap(p.id),
                      ),
                    for (var i = people.length; i < Proto.maxPeers; i++)
                      const EmptySlotTile(),
                  ],
                );
              },
            ),
          ),
        ),
      ],
    );
  }
}

class _HostBanner extends StatelessWidget {
  const _HostBanner({required this.c});

  final IntercomController c;

  @override
  Widget build(BuildContext context) {
    final ip = c.hostInterfaces.isEmpty ? null : c.hostInterfaces.first.ip;
    final alone = c.peopleCount <= 1;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 6, 16, 0),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: AppColors.amber.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppColors.amber.withValues(alpha: 0.30)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 2),
            child: Icon(Icons.wifi_tethering_rounded, color: AppColors.amber),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  alone ? 'Esperando o pessoal entrar' : 'Sala aberta',
                  style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15),
                ),
                if (alone) ...[
                  const SizedBox(height: 4),
                  const Text(
                    'Peça para os outros entrarem no Wi-Fi deste celular e '
                    'tocarem em "Entrar na sala".',
                    style: TextStyle(color: AppColors.textDim, fontSize: 13, height: 1.35),
                  ),
                ],
                const SizedBox(height: 6),
                Text(
                  ip == null
                      ? (Platform.isIOS
                          ? 'O endereço aparece quando alguém conectar no hotspot.'
                          : 'Hotspot não detectado: ligue o Roteador Wi-Fi.')
                      : 'Endereço da sala: $ip',
                  style: TextStyle(
                    color: ip == null ? AppColors.warning : AppColors.amber,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (ip == null && Platform.isAndroid)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: InkWell(
                      onTap: c.native.openHotspotSettings,
                      child: const Text(
                        'Abrir ajustes do hotspot ›',
                        style: TextStyle(
                          color: AppColors.text,
                          fontWeight: FontWeight.w700,
                          decoration: TextDecoration.underline,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SearchingView extends StatelessWidget {
  const _SearchingView({required this.c, required this.onAskAddress});

  final IntercomController c;
  final VoidCallback onAskAddress;

  @override
  Widget build(BuildContext context) {
    final started = c.searchStartedAt;
    final slow = started != null &&
        DateTime.now().difference(started) > const Duration(seconds: 15);
    final notice = c.fullRoomNotice;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
      child: Column(
        children: [
          Radar(
            size: 200,
            child: Container(
              width: 74,
              height: 74,
              decoration: BoxDecoration(
                color: AppColors.surfaceHigh,
                shape: BoxShape.circle,
                border: Border.all(color: AppColors.amber.withValues(alpha: 0.5)),
              ),
              child: const Icon(Icons.wifi_rounded, color: AppColors.amber, size: 34),
            ),
          ),
          const SizedBox(height: 10),
          Text(
            c.phase == Phase.connecting ? 'Entrando na sala…' : 'Procurando a sala…',
            style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w900),
          ),
          const SizedBox(height: 6),
          Text(
            c.statusDetail,
            textAlign: TextAlign.center,
            style: const TextStyle(color: AppColors.textDim, height: 1.35),
          ),
          if (notice != null) ...[
            const SizedBox(height: 14),
            NoticeBanner(icon: Icons.block_rounded, color: AppColors.danger, text: notice),
          ],
          const SizedBox(height: 20),
          Container(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: AppColors.outline),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const StepLine(
                  number: 1,
                  text: 'No celular do host: hotspot ligado e sala criada.',
                ),
                const StepLine(
                  number: 2,
                  text: 'Neste celular: conecte no Wi-Fi do hotspot do host '
                      '(mesmo que diga "sem internet").',
                ),
                StepLine(
                  number: 3,
                  text: Platform.isIOS
                      ? 'Se o iPhone perguntar sobre "Rede Local", toque em '
                          'Permitir.'
                      : 'Deixe o Wi-Fi ligado; a sala aparece sozinha.',
                ),
              ],
            ),
          ),
          if (slow) ...[
            const SizedBox(height: 12),
            NoticeBanner(
              icon: Icons.lightbulb_outline_rounded,
              color: AppColors.amber,
              text: Platform.isIOS
                  ? 'Ainda nada? Confira em Ajustes › Privacidade › Rede Local se '
                      'o Comboio está permitido, ou digite o endereço que aparece '
                      'na tela do host.'
                  : 'Ainda nada? Confira se você está no Wi-Fi certo, ou digite o '
                      'endereço que aparece na tela do host.',
            ),
          ],
          const SizedBox(height: 10),
          TextButton.icon(
            onPressed: onAskAddress,
            icon: const Icon(Icons.keyboard_rounded),
            label: const Text('Digitar o endereço do host'),
          ),
        ],
      ),
    );
  }
}

class _CenteredStatus extends StatelessWidget {
  const _CenteredStatus({
    required this.icon,
    required this.title,
    required this.message,
    this.busy = false,
  });

  final IconData icon;
  final String title;
  final String message;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 86,
              height: 86,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  if (busy)
                    const SizedBox(
                      width: 86,
                      height: 86,
                      child: CircularProgressIndicator(
                        strokeWidth: 3,
                        color: AppColors.amber,
                      ),
                    ),
                  Icon(icon, color: AppColors.amber, size: 34),
                ],
              ),
            ),
            const SizedBox(height: 20),
            Text(
              title,
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w900),
            ),
            const SizedBox(height: 6),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: AppColors.textDim),
            ),
          ],
        ),
      ),
    );
  }
}

class _MessageView extends StatelessWidget {
  const _MessageView({
    required this.icon,
    required this.color,
    required this.title,
    required this.message,
    required this.primaryLabel,
    required this.onPrimary,
    required this.secondaryLabel,
    required this.onSecondary,
  });

  final IconData icon;
  final Color color;
  final String title;
  final String message;
  final String primaryLabel;
  final VoidCallback onPrimary;
  final String secondaryLabel;
  final VoidCallback onSecondary;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 88,
              height: 88,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.12),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, color: color, size: 42),
            ),
            const SizedBox(height: 20),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w900),
            ),
            const SizedBox(height: 8),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: AppColors.textDim, height: 1.4),
            ),
            const SizedBox(height: 26),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 15),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                ),
                onPressed: onPrimary,
                child: Text(primaryLabel,
                    style: const TextStyle(fontWeight: FontWeight.w800)),
              ),
            ),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: TextButton(
                onPressed: onSecondary,
                child: Text(secondaryLabel),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AddressDialog extends StatefulWidget {
  const _AddressDialog({required this.initial});

  final String initial;

  @override
  State<_AddressDialog> createState() => _AddressDialogState();
}

class _AddressDialogState extends State<_AddressDialog> {
  late final TextEditingController _text =
      TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppColors.surface,
      title: const Text('Endereço do host'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Ele aparece na tela de quem criou a sala '
            '(por exemplo 192.168.43.1).',
            style: TextStyle(color: AppColors.textDim),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _text,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
            ],
            decoration: const InputDecoration(hintText: '192.168.x.x'),
            onSubmitted: (v) => Navigator.of(context).pop(v),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_text.text),
          child: const Text('Conectar'),
        ),
      ],
    );
  }
}
