import 'dart:async';

import 'package:flutter/material.dart';

import '../call/intercom_controller.dart';
import 'room_screen.dart';
import 'sheets.dart';
import 'theme.dart';
import 'widgets/common.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.controller});

  final IntercomController controller;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late final TextEditingController _name =
      TextEditingController(text: widget.controller.prefs.name);
  final FocusNode _focus = FocusNode();
  bool _opening = false;

  IntercomController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (!c.prefs.seenHelp) {
        c.prefs.seenHelp = true;
        unawaited(showHelpSheet(context));
      }
    });
  }

  @override
  void dispose() {
    _name.dispose();
    _focus.dispose();
    super.dispose();
  }

  bool _ensureName() {
    if (_name.text.trim().isNotEmpty) return true;
    _focus.requestFocus();
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(
        content: Text('Digite seu nome para os outros saberem quem está falando.'),
      ));
    return false;
  }

  Future<void> _start(Role role) async {
    if (_opening || !_ensureName()) return;
    _opening = true;
    FocusScope.of(context).unfocus();
    if (role == Role.host) {
      unawaited(c.startHost(_name.text));
    } else {
      unawaited(c.joinRoom(_name.text));
    }
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => RoomScreen(controller: c),
    ));
    _opening = false;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: AppBackground(
        child: SafeArea(
          child: LayoutBuilder(
            builder: (context, box) => SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(22, 14, 22, 24),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                    minHeight: (box.maxHeight - 38).clamp(0.0, double.infinity)),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        const ComboioLogo(size: 50),
                        const SizedBox(width: 14),
                        const Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Comboio',
                                style: TextStyle(
                                  fontSize: 26,
                                  fontWeight: FontWeight.w900,
                                  letterSpacing: -0.5,
                                ),
                              ),
                              Text(
                                'Intercom de viagem',
                                style: TextStyle(color: AppColors.textDim),
                              ),
                            ],
                          ),
                        ),
                        IconButton(
                          tooltip: 'Como funciona',
                          onPressed: () => showHelpSheet(context),
                          icon: const Icon(Icons.help_outline_rounded),
                        ),
                      ],
                    ),
                    const SizedBox(height: 34),
                    const Text(
                      'Converse com quem está no seu comboio, sem internet.',
                      style: TextStyle(
                        fontSize: 27,
                        fontWeight: FontWeight.w900,
                        height: 1.15,
                        letterSpacing: -0.4,
                      ),
                    ),
                    const SizedBox(height: 10),
                    const Text(
                      'Um celular liga o hotspot e cria a sala. Os outros '
                      'entram no Wi-Fi dele e o áudio começa sozinho. Até 4 '
                      'pessoas.',
                      style: TextStyle(
                        color: AppColors.textDim,
                        fontSize: 15,
                        height: 1.4,
                      ),
                    ),
                    const SizedBox(height: 28),
                    const Text(
                      'Seu nome',
                      style: TextStyle(
                        color: AppColors.textDim,
                        fontWeight: FontWeight.w700,
                        fontSize: 13,
                        letterSpacing: 0.3,
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _name,
                      focusNode: _focus,
                      maxLength: 24,
                      textCapitalization: TextCapitalization.words,
                      textInputAction: TextInputAction.done,
                      onChanged: (v) => c.prefs.name = v.trim(),
                      decoration: const InputDecoration(
                        hintText: 'Como vão te chamar na sala',
                        prefixIcon: Icon(Icons.person_rounded),
                        counterText: '',
                      ),
                    ),
                    const SizedBox(height: 22),
                    ActionCard(
                      primary: true,
                      icon: Icons.wifi_tethering_rounded,
                      title: 'Criar sala',
                      subtitle: 'Meu celular é o hotspot',
                      onTap: () => _start(Role.host),
                    ),
                    const SizedBox(height: 14),
                    ActionCard(
                      icon: Icons.login_rounded,
                      title: 'Entrar na sala',
                      subtitle: 'Já estou no Wi-Fi de quem criou',
                      onTap: () => _start(Role.guest),
                    ),
                    const SizedBox(height: 26),
                    Container(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                      decoration: BoxDecoration(
                        color: AppColors.surface.withValues(alpha: 0.7),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: AppColors.outline),
                      ),
                      child: const Column(
                        children: [
                          StepLine(
                            number: 1,
                            text: 'O host liga o hotspot e toca em "Criar sala".',
                          ),
                          StepLine(
                            number: 2,
                            text: 'Os outros entram no Wi-Fi do host e tocam em '
                                '"Entrar na sala".',
                          ),
                          StepLine(
                            number: 3,
                            text: 'É só falar. Funciona com a tela apagada.',
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    const Center(
                      child: Text(
                        'Dica: com fones o som fica mais limpo e sem eco.',
                        style: TextStyle(color: AppColors.textFaint, fontSize: 12.5),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
