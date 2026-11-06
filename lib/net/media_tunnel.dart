import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../core/protocol.dart';

int _nowMs() => DateTime.now().millisecondsSinceEpoch;

class _Pipe {
  _Pipe(this.slot, this.socket);

  final int slot;
  final RawDatagramSocket socket;

  /// Porta local do WebRTC (aprendida pelo primeiro pacote que ele manda).
  int? pcPort;
  int rx = 0;
  int tx = 0;
  int lastRxMs = 0;
}

/// Túnel de mídia de um participante.
///
/// O WebRTC deste celular só enxerga endereços de loopback: para cada pessoa
/// da sala existe uma porta local (127.0.0.1:porta) que representa essa
/// pessoa. Tudo que o WebRTC manda para essa porta é embrulhado e enviado ao
/// hub do host pelo Wi-Fi; o que chega do hub é entregue de volta ao WebRTC.
///
/// Isso evita a filtragem de interfaces do libwebrtc (o celular que faz o
/// hotspot não é visto como "Wi-Fi" pelo WebRTC) e deixa a reconexão do Wi-Fi
/// transparente para as chamadas.
class MediaTunnel {
  MediaTunnel({
    required int mySlot,
    required Uint8List token,
    required InternetAddress hubAddress,
    required int hubPort,
    this.onHubState,
  })  : _mySlot = mySlot,
        _token = token,
        _hubAddress = hubAddress,
        _hubPort = hubPort;

  int _mySlot;
  Uint8List _token;
  InternetAddress _hubAddress;
  int _hubPort;

  final void Function(bool alive)? onHubState;

  RawDatagramSocket? _lan;
  final Map<int, _Pipe> _pipes = {};
  final Map<int, Future<_Pipe>> _opening = {};
  Timer? _helloTimer;
  int _lastAckMs = 0;
  bool _alive = false;
  bool _closed = false;

  /// Ida e volta até o hub, em ms (último HELLO respondido).
  int? hubRttMs;

  bool get hubAlive => _alive;
  int get mySlot => _mySlot;

  Future<void> start() async {
    await _openLan();
    _sendHello();
    _helloTimer = Timer.periodic(const Duration(milliseconds: 900), (_) {
      _sendHello();
      _checkAlive();
    });
  }

  /// Atualiza o destino (por exemplo, depois de reconectar na sala).
  void update({
    required int mySlot,
    required Uint8List token,
    required InternetAddress hubAddress,
    required int hubPort,
  }) {
    _mySlot = mySlot;
    _token = token;
    _hubAddress = hubAddress;
    _hubPort = hubPort;
    _sendHello();
  }

  /// Recria o socket de rede (a rede Wi-Fi mudou).
  Future<void> rebind() async {
    if (_closed) return;
    await _openLan();
    _sendHello();
  }

  Future<int> openPipe(int slot) async {
    final existing = _pipes[slot];
    if (existing != null) return existing.socket.port;
    final pending = _opening[slot];
    if (pending != null) return (await pending).socket.port;
    final future = _createPipe(slot);
    _opening[slot] = future;
    try {
      final pipe = await future;
      return pipe.socket.port;
    } finally {
      _opening.remove(slot);
    }
  }

  Future<_Pipe> _createPipe(int slot) async {
    final s = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
    s.writeEventsEnabled = false;
    final pipe = _Pipe(slot, s);
    if (_closed) {
      s.close();
      return pipe;
    }
    _pipes[slot] = pipe;
    s.listen(
      (ev) {
        if (ev == RawSocketEvent.read) _drainPipe(pipe);
      },
      onError: (Object _) {},
    );
    return pipe;
  }

  /// Esquece a porta do WebRTC (uma conexão nova vai começar).
  void resetPipe(int slot) {
    _pipes[slot]?.pcPort = null;
  }

  void closePipe(int slot) {
    final p = _pipes.remove(slot);
    p?.socket.close();
  }

  int lastRxMs(int slot) => _pipes[slot]?.lastRxMs ?? 0;

  Future<void> close() async {
    _closed = true;
    _helloTimer?.cancel();
    _helloTimer = null;
    for (final p in _pipes.values) {
      p.socket.close();
    }
    _pipes.clear();
    _lan?.close();
    _lan = null;
  }

  Future<void> _openLan() async {
    final old = _lan;
    _lan = null;
    old?.close();
    final s = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    s.writeEventsEnabled = false;
    if (_closed) {
      s.close();
      return;
    }
    _lan = s;
    s.listen(
      (ev) {
        if (ev == RawSocketEvent.read) _drainLan(s);
      },
      onError: (Object _) {},
    );
  }

  void _sendHello() {
    final s = _lan;
    if (s == null || _closed) return;
    try {
      s.send(Packets.hello(_mySlot, _token, _nowMs()), _hubAddress, _hubPort);
    } catch (_) {}
  }

  void _checkAlive() {
    final alive = _nowMs() - _lastAckMs < 3500;
    if (alive != _alive) {
      _alive = alive;
      onHubState?.call(alive);
    }
  }

  void _drainLan(RawDatagramSocket s) {
    while (true) {
      final dg = s.receive();
      if (dg == null) break;
      if (dg.port != _hubPort || dg.address.address != _hubAddress.address) {
        continue;
      }
      final data = dg.data;
      final h = PacketHeader.parse(data);
      if (h == null) continue;
      if (h.type == Proto.typeData) {
        if (h.b != _mySlot) continue;
        final pipe = _pipes[h.a];
        if (pipe == null) continue;
        final pcPort = pipe.pcPort;
        if (pcPort == null) continue;
        try {
          pipe.socket.send(
              Packets.payloadOf(data), InternetAddress.loopbackIPv4, pcPort);
          pipe.rx++;
          pipe.lastRxMs = _nowMs();
        } catch (_) {}
      } else if (h.type == Proto.typeHelloAck) {
        final now = _nowMs();
        _lastAckMs = now;
        final ts = Packets.parseAckTimestamp(data);
        if (ts != null) hubRttMs = now - ts;
        _checkAlive();
      }
    }
  }

  void _drainPipe(_Pipe pipe) {
    while (true) {
      final dg = pipe.socket.receive();
      if (dg == null) break;
      // Só aceita o WebRTC local (loopback). Outras interfaces do próprio
      // aparelho podem mandar checagens ICE para cá: ignoradas.
      if (!dg.address.isLoopback) continue;
      pipe.pcPort = dg.port;
      final lan = _lan;
      if (lan == null) continue;
      try {
        lan.send(Packets.data(_mySlot, pipe.slot, dg.data), _hubAddress,
            _hubPort);
        pipe.tx++;
      } catch (_) {}
    }
  }
}
