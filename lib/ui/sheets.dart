import 'dart:io';

import 'package:flutter/material.dart';

import '../call/intercom_controller.dart';
import 'theme.dart';
import 'widgets/common.dart';
import 'widgets/participant_tile.dart';

Future<void> showHelpSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(22, 0, 22, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Como funciona',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900),
            ),
            const SizedBox(height: 14),
            const StepLine(
              number: 1,
              text: 'Uma pessoa (o host) liga o Hotspot / Roteador Wi-Fi do '
                  'celular e toca em "Criar sala".',
            ),
            const StepLine(
              number: 2,
              text: 'Os outros conectam no Wi-Fi desse hotspot (pode aparecer '
                  '"sem internet", tudo bem) e tocam em "Entrar na sala".',
            ),
            const StepLine(
              number: 3,
              text: 'Pronto: o áudio começa sozinho. Dá para ficar com a tela '
                  'apagada e o app em segundo plano.',
            ),
            const SizedBox(height: 18),
            const Text(
              'Dicas',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 8),
            const NoticeBanner(
              icon: Icons.headphones_rounded,
              color: AppColors.teal,
              text: 'Fones (com fio ou Bluetooth) deixam o som mais limpo. Sem '
                  'fone, o cancelamento de eco cuida do viva-voz.',
            ),
            const SizedBox(height: 8),
            NoticeBanner(
              icon: Icons.wifi_rounded,
              color: AppColors.amber,
              text: Platform.isIOS
                  ? 'No iPhone, permita "Rede Local" quando o app pedir. Se '
                      'negou sem querer: Ajustes › Privacidade › Rede Local › '
                      'Comboio.'
                  : 'Se o Android avisar que o Wi-Fi está sem internet, '
                      'escolha continuar conectado.',
            ),
            const SizedBox(height: 8),
            const NoticeBanner(
              icon: Icons.directions_car_rounded,
              color: AppColors.textDim,
              text: 'O alcance é o do Wi-Fi do hotspot: ótimo dentro do carro '
                  'ou entre carros bem próximos. Máximo de 4 pessoas.',
            ),
          ],
        ),
      ),
    ),
  );
}

Future<void> showSettingsSheet(BuildContext context, IntercomController c) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => ListenableBuilder(
      listenable: c,
      builder: (ctx, _) {
        final rtt = c.hubRttMs;
        return SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Ajustes',
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900),
                ),
                const SizedBox(height: 6),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: c.speakerOn,
                  onChanged: c.setSpeaker,
                  title: const Text('Viva-voz'),
                  subtitle: const Text(
                      'Desligado: usa o fone ou o alto-falante de ligação. '
                      'Fone Bluetooth tem prioridade.'),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: c.keepScreenOn,
                  onChanged: c.setKeepScreenOn,
                  title: const Text('Manter a tela ligada'),
                  subtitle: const Text(
                      'Para ver quem está falando. Gasta mais bateria.'),
                ),
                if (Platform.isAndroid)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.battery_saver_rounded),
                    title: const Text('Não deixar o Android pausar o app'),
                    subtitle: const Text(
                        'Recomendado para viagens longas com a tela apagada.'),
                    onTap: c.native.requestIgnoreBatteryOptimizations,
                  ),
                if (c.isHost && Platform.isAndroid)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.wifi_tethering_rounded),
                    title: const Text('Abrir ajustes do hotspot'),
                    onTap: c.native.openHotspotSettings,
                  ),
                const Divider(height: 28),
                _InfoRow(label: 'Você', value: c.myName),
                _InfoRow(
                  label: 'Sala',
                  value: c.roomName.isEmpty ? '—' : c.roomName,
                ),
                _InfoRow(
                  label: c.isHost ? 'Endereço da sala' : 'Host',
                  value: c.isHost
                      ? (c.hostInterfaces.isEmpty
                          ? 'aguardando o hotspot'
                          : c.hostInterfaces.map((i) => i.ip).join(', '))
                      : (c.hostAddress ?? '—'),
                ),
                _InfoRow(
                  label: 'Ida e volta até o host',
                  value: rtt == null ? '—' : '$rtt ms',
                ),
                const SizedBox(height: 10),
                const Text(
                  'Comboio 1.0 • áudio WebRTC (Opus) com cancelamento de eco '
                  'e redução de ruído.',
                  style: TextStyle(color: AppColors.textFaint, fontSize: 12),
                ),
              ],
            ),
          ),
        );
      },
    ),
  );
}

Future<void> showPeerSheet(
    BuildContext context, IntercomController c, String peerId) {
  return showModalBottomSheet<void>(
    context: context,
    builder: (ctx) => ListenableBuilder(
      listenable: c,
      builder: (ctx, _) {
        final p = c.peer(peerId);
        if (p == null) {
          return const SafeArea(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Text('Essa pessoa saiu da sala.'),
            ),
          );
        }
        final rtt = p.rttMs;
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(22, 0, 22, 22),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    SpeakingAvatar(
                      name: p.name,
                      color: AppColors.avatarFor(p.id),
                      level: p.level,
                      size: 56,
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            p.name,
                            style: const TextStyle(
                                fontSize: 20, fontWeight: FontWeight.w900),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            p.isConnected
                                ? (rtt == null
                                    ? 'Conectado'
                                    : 'Conectado • ${rtt.round()} ms'
                                        '${p.lossPct >= 1 ? ' • perda ${p.lossPct.toStringAsFixed(0)}%' : ''}')
                                : 'Conectando…',
                            style: const TextStyle(color: AppColors.textDim),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                Text(
                  'Volume de ${p.name}: ${(p.volume * 100).round()}%',
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                Row(
                  children: [
                    const Icon(Icons.volume_mute_rounded, color: AppColors.textDim),
                    Expanded(
                      child: Slider(
                        value: p.volume.clamp(0.0, 2.0),
                        min: 0,
                        max: 2,
                        divisions: 20,
                        label: '${(p.volume * 100).round()}%',
                        onChanged: (v) => c.setPeerVolume(p.id, v),
                      ),
                    ),
                    const Icon(Icons.volume_up_rounded, color: AppColors.textDim),
                  ],
                ),
                Row(
                  children: [
                    TextButton.icon(
                      onPressed: () => c.setPeerVolume(p.id, 0),
                      icon: const Icon(Icons.volume_off_rounded),
                      label: const Text('Silenciar para mim'),
                    ),
                    const Spacer(),
                    TextButton(
                      onPressed: () => c.setPeerVolume(p.id, 1),
                      child: const Text('Volume normal'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    ),
  );
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 150,
            child: Text(label, style: const TextStyle(color: AppColors.textDim)),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}
