import 'package:shared_preferences/shared_preferences.dart';

import 'protocol.dart';

/// Preferências salvas no aparelho.
class AppPrefs {
  AppPrefs._(this._p);

  final SharedPreferences _p;

  static Future<AppPrefs> load() async {
    final p = await SharedPreferences.getInstance();
    final prefs = AppPrefs._(p);
    if ((p.getString(_kDeviceId) ?? '').isEmpty) {
      await p.setString(_kDeviceId, randomId());
    }
    return prefs;
  }

  static const _kDeviceId = 'deviceId';
  static const _kName = 'name';
  static const _kLastHost = 'lastHost';
  static const _kSpeaker = 'speakerOn';
  static const _kKeepScreen = 'keepScreenOn';
  static const _kSeenHelp = 'seenHelp';

  String get deviceId => _p.getString(_kDeviceId) ?? 'device';

  String get name => _p.getString(_kName) ?? '';
  set name(String v) => _p.setString(_kName, v);

  String? get lastHost => _p.getString(_kLastHost);
  set lastHost(String? v) {
    if (v == null) {
      _p.remove(_kLastHost);
    } else {
      _p.setString(_kLastHost, v);
    }
  }

  bool get speakerOn => _p.getBool(_kSpeaker) ?? true;
  set speakerOn(bool v) => _p.setBool(_kSpeaker, v);

  bool get keepScreenOn => _p.getBool(_kKeepScreen) ?? false;
  set keepScreenOn(bool v) => _p.setBool(_kKeepScreen, v);

  bool get seenHelp => _p.getBool(_kSeenHelp) ?? false;
  set seenHelp(bool v) => _p.setBool(_kSeenHelp, v);
}

/// Normaliza o nome digitado pela pessoa.
String cleanName(String? raw, {String fallback = 'Viajante'}) {
  final v = (raw ?? '').replaceAll(RegExp(r'\s+'), ' ').trim();
  if (v.isEmpty) return fallback;
  return v.length > 24 ? v.substring(0, 24).trim() : v;
}

String initialsOf(String name) {
  final parts = name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty);
  if (parts.isEmpty) return '?';
  final list = parts.toList();
  final first = String.fromCharCode(list.first.runes.first);
  if (list.length == 1) return first.toUpperCase();
  final last = String.fromCharCode(list.last.runes.first);
  return (first + last).toUpperCase();
}
