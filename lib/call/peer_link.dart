import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../core/protocol.dart';
import '../net/media_tunnel.dart';
import 'audio_engine.dart';

enum LinkStatus { connecting, connected, reconnecting }

int _nowMs() => DateTime.now().millisecondsSinceEpoch;

/// Conexão de áudio (WebRTC) com uma outra pessoa da sala.
///
/// Quem tem o id "maior" faz a oferta, então nunca há colisão de ofertas.
/// O ICE só conhece um candidato: a porta de loopback do túnel que representa
/// a outra pessoa. Se a conexão cair, quem oferta recria tudo sozinho.
class PeerLink {
  PeerLink({
    required this.peerId,
    required this.slot,
    required this.isOfferer,
    required this.engine,
    required this.tunnel,
    required this.sendSignal,
    required this.onChanged,
  });

  final String peerId;
  final int slot;
  final bool isOfferer;
  final AudioEngine engine;
  final MediaTunnel tunnel;
  final void Function(Map<String, dynamic> data) sendSignal;
  final VoidCallback onChanged;

  static const Map<String, dynamic> _rtcConfig = <String, dynamic>{
    'iceServers': <dynamic>[],
    'sdpSemantics': 'unified-plan',
    'bundlePolicy': 'max-bundle',
    'rtcpMuxPolicy': 'require',
    'tcpCandidatePolicy': 'disabled',
    'iceCandidatePoolSize': 0,
  };

  RTCPeerConnection? _pc;
  int? _tunnelPort;
  int _session = 0;
  int _attempt = 0;
  bool _disposed = false;
  Timer? _watchdog;
  Future<void> _chain = Future<void>.value();
  MediaStreamTrack? _remoteTrack;

  LinkStatus status = LinkStatus.connecting;

  /// Falso enquanto a sinalização está fora ou a pessoa está offline.
  bool canNegotiate = true;

  double volume = 1.0;
  double level = 0;
  double localLevel = 0;
  double? rttMs;
  double lossPct = 0;
  int _lastReceived = 0;
  int _lastLost = 0;
  int _lastNegotiationMs = 0;

  bool get isConnected => status == LinkStatus.connected;

  void start() {
    _lastNegotiationMs = _nowMs();
    if (isOfferer) {
      _serial(_makeOffer);
    } else {
      // Quem responde espera a oferta; se ela não vier, pede de novo.
      _armWatchdog(const Duration(seconds: 6));
    }
  }

  /// Chamado quando a sala volta ou a pessoa reaparece.
  void nudge() {
    if (_disposed || isConnected) return;
    // Uma negociação acabou de começar: deixa ela terminar.
    if (_nowMs() - _lastNegotiationMs < 5000) return;
    if (_pc == null || status == LinkStatus.reconnecting) {
      _scheduleRestart(quick: true);
    }
  }

  void onSignal(Map<String, dynamic> data) {
    if (_disposed) return;
    final kind = data['kind'];
    final session = asInt(data['session']) ?? 0;
    final sdp = asString(data['sdp']) ?? '';
    switch (kind) {
      case 'offer':
        if (!isOfferer) _serial(() => _acceptOffer(session, sdp));
      case 'answer':
        if (isOfferer) _serial(() => _acceptAnswer(session, sdp));
      case 'restart':
        if (isOfferer) _onRestartRequest(session);
    }
  }

  Future<void> setVolume(double v) async {
    volume = v;
    await _applyVolume();
  }

  Future<void> dispose() async {
    _disposed = true;
    _watchdog?.cancel();
    try {
      await _chain.timeout(const Duration(seconds: 3));
    } catch (_) {}
    await _closePc();
    tunnel.closePipe(slot);
  }

  // ---------------------------------------------------------------- ofertas

  Future<void> _makeOffer() async {
    if (_disposed) return;
    if (!canNegotiate) {
      // Sinalização fora ou pessoa offline: confere de novo daqui a pouco.
      _armWatchdog(const Duration(seconds: 3));
      return;
    }
    _lastNegotiationMs = _nowMs();
    final session = randomInt32() + 1;
    _session = session;
    final pc = await _createPc();
    final offer = await pc.createOffer(<String, dynamic>{});
    if (_disposed || session != _session) return;
    await pc.setLocalDescription(offer);
    sendSignal({'kind': 'offer', 'session': session, 'sdp': offer.sdp});
    _setStatus(_attempt == 0 ? LinkStatus.connecting : LinkStatus.reconnecting);
    _armWatchdog(const Duration(seconds: 12));
  }

  Future<void> _acceptOffer(int session, String sdp) async {
    if (_disposed || sdp.isEmpty) return;
    _lastNegotiationMs = _nowMs();
    _session = session;
    final pc = await _createPc();
    await pc.setRemoteDescription(RTCSessionDescription(sdp, 'offer'));
    await _addTunnelCandidate(pc, sdp);
    final answer = await pc.createAnswer(<String, dynamic>{});
    if (_disposed || session != _session) return;
    await pc.setLocalDescription(answer);
    sendSignal({'kind': 'answer', 'session': session, 'sdp': answer.sdp});
    if (!isConnected) {
      _setStatus(_attempt == 0 ? LinkStatus.connecting : LinkStatus.reconnecting);
    }
    _armWatchdog(const Duration(seconds: 12));
  }

  Future<void> _acceptAnswer(int session, String sdp) async {
    final pc = _pc;
    if (_disposed || pc == null || session != _session || sdp.isEmpty) return;
    await pc.setRemoteDescription(RTCSessionDescription(sdp, 'answer'));
    await _addTunnelCandidate(pc, sdp);
  }

  void _onRestartRequest(int session) {
    if (_disposed) return;
    // Pedido antigo (de uma sessão que já foi substituída): ignora.
    if (isConnected && session != 0 && session != _session) return;
    _serial(_makeOffer);
  }

  // ----------------------------------------------------------- conexão RTC

  Future<RTCPeerConnection> _createPc() async {
    await _closePc();
    final port = await tunnel.openPipe(slot);
    tunnel.resetPipe(slot);
    _tunnelPort = port;
    final pc =
        await createPeerConnection(Map<String, dynamic>.from(_rtcConfig));
    _pc = pc;
    pc.onConnectionState = (state) => _onConnectionState(pc, state);
    pc.onTrack = (event) {
      if (!identical(_pc, pc)) return;
      if (event.track.kind == 'audio') {
        _remoteTrack = event.track;
        unawaited(_applyVolume());
      }
    };
    final track = engine.track;
    final stream = engine.stream;
    if (track != null && stream != null) {
      await pc.addTrack(track, stream);
    }
    return pc;
  }

  Future<void> _addTunnelCandidate(RTCPeerConnection pc, String remoteSdp) async {
    final port = _tunnelPort;
    if (port == null) return;
    final mid = _firstMid(remoteSdp) ?? '0';
    await pc.addCandidate(RTCIceCandidate(
      'candidate:1 1 udp 2122260223 127.0.0.1 $port typ host generation 0',
      mid,
      0,
    ));
  }

  static String? _firstMid(String sdp) {
    for (final line in sdp.split('\n')) {
      final l = line.trim();
      if (l.startsWith('a=mid:')) return l.substring(6).trim();
    }
    return null;
  }

  void _onConnectionState(RTCPeerConnection pc, RTCPeerConnectionState state) {
    if (_disposed || !identical(pc, _pc)) return;
    switch (state) {
      case RTCPeerConnectionState.RTCPeerConnectionStateConnected:
        _attempt = 0;
        _watchdog?.cancel();
        _setStatus(LinkStatus.connected);
      case RTCPeerConnectionState.RTCPeerConnectionStateDisconnected:
        // Quase sempre volta sozinho (o túnel aguenta quedas curtas).
        _setStatus(LinkStatus.reconnecting);
        _armWatchdog(const Duration(seconds: 9));
      case RTCPeerConnectionState.RTCPeerConnectionStateFailed:
        _setStatus(LinkStatus.reconnecting);
        _scheduleRestart(quick: true);
      default:
        break;
    }
  }

  Future<void> _closePc() async {
    final pc = _pc;
    _pc = null;
    _remoteTrack = null;
    level = 0;
    if (pc == null) return;
    pc.onConnectionState = null;
    pc.onTrack = null;
    try {
      await pc.close();
    } catch (_) {}
    try {
      await pc.dispose();
    } catch (_) {}
  }

  // ------------------------------------------------------ vigia/reconexão

  void _armWatchdog(Duration d) {
    _watchdog?.cancel();
    _watchdog = Timer(d, () {
      if (_disposed || isConnected) return;
      _scheduleRestart();
    });
  }

  void _scheduleRestart({bool quick = false}) {
    if (_disposed) return;
    _watchdog?.cancel();
    _attempt++;
    final backoff = quick && _attempt <= 2
        ? 250
        : min(8000, 500 * (1 << min(_attempt, 4)));
    _watchdog = Timer(Duration(milliseconds: backoff), () {
      if (_disposed || isConnected) return;
      if (!canNegotiate) {
        // Sem sinalização: tenta de novo daqui a pouco.
        _armWatchdog(const Duration(seconds: 3));
        return;
      }
      if (isOfferer) {
        _serial(_makeOffer);
      } else {
        sendSignal({'kind': 'restart', 'session': _session});
        _armWatchdog(const Duration(seconds: 10));
      }
    });
  }

  void _serial(Future<void> Function() op) {
    _chain = _chain.then((_) => op()).catchError((Object e, StackTrace st) {
      debugPrint('PeerLink($peerId): $e');
      if (!_disposed && !isConnected) _scheduleRestart();
    });
  }

  void _setStatus(LinkStatus s) {
    if (status == s) return;
    status = s;
    onChanged();
  }

  // ---------------------------------------------------------- estatísticas

  Future<void> pollStats() async {
    final pc = _pc;
    if (pc == null || !isConnected) {
      level = 0;
      localLevel = 0;
      return;
    }
    final List<StatsReport> reports;
    try {
      reports = await pc.getStats();
    } catch (_) {
      return;
    }
    for (final r in reports) {
      final v = r.values;
      switch (r.type) {
        case 'inbound-rtp':
          if (v['kind'] != 'audio' && v['mediaType'] != 'audio') break;
          final al = v['audioLevel'];
          if (al is num) level = al.toDouble();
          final recv = v['packetsReceived'];
          final lost = v['packetsLost'];
          if (recv is num && lost is num) {
            final dr = recv.toInt() - _lastReceived;
            final dl = max(0, lost.toInt() - _lastLost);
            _lastReceived = recv.toInt();
            _lastLost = lost.toInt();
            if (dr + dl > 0 && dr >= 0) lossPct = dl * 100.0 / (dr + dl);
          }
        case 'candidate-pair':
          final rtt = v['currentRoundTripTime'];
          if (rtt is num && (v['nominated'] == true || v['state'] == 'succeeded')) {
            rttMs = rtt.toDouble() * 1000.0;
          }
        case 'media-source':
          if (v['kind'] != 'audio') break;
          final source = v['audioLevel'];
          if (source is num) localLevel = source.toDouble();
      }
    }
  }

  Future<void> _applyVolume() async {
    final t = _remoteTrack;
    if (t == null) return;
    try {
      await Helper.setVolume(volume, t);
    } catch (_) {}
  }
}
