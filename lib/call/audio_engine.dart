import 'dart:io';

import 'package:flutter_webrtc/flutter_webrtc.dart';

/// Captura do microfone e configuração de áudio do WebRTC.
class AudioEngine {
  static bool _webrtcReady = false;

  MediaStream? _stream;

  MediaStream? get stream => _stream;

  MediaStreamTrack? get track {
    final tracks = _stream?.getAudioTracks();
    if (tracks == null || tracks.isEmpty) return null;
    return tracks.first;
  }

  bool get isRunning => _stream != null;

  /// Inicializa o WebRTC (uma vez) e abre o microfone.
  Future<void> start({required bool speaker}) async {
    if (!_webrtcReady) {
      await WebRTC.initialize(options: <String, dynamic>{
        // Todo o áudio passa pelo túnel em loopback: as interfaces reais
        // ficam de fora para o ICE não tentar caminhos que não funcionam.
        'networkIgnoreMask': <String>[
          'adapterTypeEthernet',
          'adapterTypeWifi',
          'adapterTypeCellular',
          'adapterTypeVpn',
        ],
        if (Platform.isAndroid)
          'androidAudioConfiguration':
              AndroidAudioConfiguration.communication.toMap(),
      });
      _webrtcReady = true;
    }
    if (Platform.isIOS) {
      await Helper.setAppleAudioConfiguration(AppleAudioConfiguration(
        appleAudioCategory: AppleAudioCategory.playAndRecord,
        appleAudioCategoryOptions: {
          AppleAudioCategoryOption.allowBluetooth,
          AppleAudioCategoryOption.defaultToSpeaker,
          AppleAudioCategoryOption.mixWithOthers,
        },
        appleAudioMode: AppleAudioMode.voiceChat,
      ));
    }
    _stream ??= await navigator.mediaDevices
        .getUserMedia(<String, dynamic>{'audio': true, 'video': false});
    await setSpeaker(speaker);
  }

  Future<void> setMuted(bool muted) async {
    final t = track;
    if (t != null) t.enabled = !muted;
  }

  /// Viva-voz (prefere fone Bluetooth se houver) ou fone/receptor.
  Future<void> setSpeaker(bool on) async {
    if (_stream == null) return;
    try {
      if (on) {
        await Helper.setSpeakerphoneOnButPreferBluetooth();
      } else {
        await Helper.setSpeakerphoneOn(false);
      }
    } catch (_) {}
  }

  Future<void> stop() async {
    final s = _stream;
    _stream = null;
    if (s != null) {
      for (final t in s.getTracks()) {
        try {
          await t.stop();
        } catch (_) {}
      }
      try {
        await s.dispose();
      } catch (_) {}
    }
    if (Platform.isAndroid && _webrtcReady) {
      try {
        await Helper.clearAndroidCommunicationDevice();
      } catch (_) {}
    }
  }
}
