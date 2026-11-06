import 'dart:io';

import 'package:flutter/services.dart';

class PermissionResult {
  const PermissionResult({
    required this.microphone,
    this.bluetooth = true,
    this.notifications = true,
  });

  final bool microphone;
  final bool bluetooth;
  final bool notifications;
}

/// Ponte com o código nativo (Kotlin em MainActivity / Swift em AppDelegate).
///
/// Tudo aqui é tolerante a falhas: se o lado nativo não responder, o app
/// segue com um comportamento padrão razoável.
class NativeBridge {
  static const MethodChannel _ch = MethodChannel('comboio/native');

  bool get _mobile => Platform.isAndroid || Platform.isIOS;

  void setActionHandler(void Function(String action) handler) {
    if (!_mobile) return;
    _ch.setMethodCallHandler((call) async {
      if (call.method == 'notificationAction') {
        final a = call.arguments;
        handler(a is String ? a : '');
      }
      return null;
    });
  }

  Future<PermissionResult> requestPermissions() async {
    if (!_mobile) return const PermissionResult(microphone: true);
    try {
      final r = await _ch.invokeMapMethod<String, dynamic>('requestPermissions');
      if (r == null) return const PermissionResult(microphone: true);
      return PermissionResult(
        microphone: r['microphone'] == true,
        bluetooth: r['bluetooth'] != false,
        notifications: r['notifications'] != false,
      );
    } on MissingPluginException {
      return const PermissionResult(microphone: true);
    } on PlatformException {
      return const PermissionResult(microphone: true);
    }
  }

  Future<void> openAppSettings() => _call('openAppSettings');

  Future<void> openHotspotSettings() =>
      Platform.isAndroid ? _call('openHotspotSettings') : Future.value();

  Future<void> startService({
    required String title,
    required String text,
    required bool muted,
  }) =>
      Platform.isAndroid
          ? _call('startService', {'title': title, 'text': text, 'muted': muted})
          : Future.value();

  Future<void> updateService({
    required String title,
    required String text,
    required bool muted,
  }) =>
      Platform.isAndroid
          ? _call('updateService', {'title': title, 'text': text, 'muted': muted})
          : Future.value();

  Future<void> stopService() =>
      Platform.isAndroid ? _call('stopService') : Future.value();

  /// Android: informações do Wi-Fi atual e das interfaces de hotspot.
  Future<Map<String, dynamic>?> networkInfo() => _map('networkInfo');

  /// Android: prende o processo na rede Wi-Fi (necessário quando o Wi-Fi do
  /// hotspot não tem internet e o Android prefere os dados móveis).
  Future<Map<String, dynamic>?> bindToWifi() => _map('bindToWifi');

  Future<void> unbindNetwork() =>
      Platform.isAndroid ? _call('unbindNetwork') : Future.value();

  Future<void> setKeepScreenOn(bool on) => _call('setKeepScreenOn', {'on': on});

  Future<bool> isIgnoringBatteryOptimizations() async {
    if (!Platform.isAndroid) return true;
    try {
      return await _ch.invokeMethod<bool>('isIgnoringBatteryOptimizations') ??
          true;
    } catch (_) {
      return true;
    }
  }

  Future<void> requestIgnoreBatteryOptimizations() => Platform.isAndroid
      ? _call('requestIgnoreBatteryOptimizations')
      : Future.value();

  Future<void> _call(String method, [Map<String, dynamic>? args]) async {
    if (!_mobile) return;
    try {
      await _ch.invokeMethod<void>(method, args);
    } catch (_) {
      // Ignorado de propósito: recursos nativos são opcionais.
    }
  }

  Future<Map<String, dynamic>?> _map(String method) async {
    if (!Platform.isAndroid) return null;
    try {
      final r = await _ch.invokeMethod<dynamic>(method);
      return _deepCast(r);
    } catch (_) {
      return null;
    }
  }

  static Map<String, dynamic>? _deepCast(dynamic v) {
    if (v is! Map) return null;
    final out = <String, dynamic>{};
    v.forEach((key, value) {
      out[key.toString()] = _castValue(value);
    });
    return out;
  }

  static dynamic _castValue(dynamic v) {
    if (v is Map) return _deepCast(v);
    if (v is List) return v.map(_castValue).toList();
    return v;
  }
}
