import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'call/intercom_controller.dart';
import 'core/prefs.dart';
import 'ui/home_screen.dart';
import 'ui/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
    statusBarBrightness: Brightness.dark,
    systemNavigationBarColor: AppColors.bg0,
    systemNavigationBarIconBrightness: Brightness.light,
  ));
  final prefs = await AppPrefs.load();
  final controller = IntercomController(prefs: prefs);
  runApp(ComboioApp(controller: controller));
}

class ComboioApp extends StatelessWidget {
  const ComboioApp({super.key, required this.controller});

  final IntercomController controller;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Comboio',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      home: HomeScreen(controller: controller),
    );
  }
}
