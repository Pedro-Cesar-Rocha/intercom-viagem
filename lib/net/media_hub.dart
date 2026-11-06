import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../core/protocol.dart';

class _Endpoint {
  _Endpoint(this.address, this.port, this.key) : lastSeenMs = _now();

  final InternetAddress address;
  final int port;

  /// Chave com que este endereço se registrou.
  final Uint8List key;
  int lastSeenMs;

  bool matches(Datagram dg) =>
      dg.port == port && dg.address.address == address.address;
}

int _now() => DateTime.now().millisecondsSinceEpoch;

/// Hub UDP que roda no host.
///
/// * Responde à descoberta (DISCOVER → OFFER) para quem procura a sala.
/// * Registra o endereço de cada participante (HELLO com a chave dele).
/// * Repassa os pacotes de mídia (DATA) entre os participantes.
class MediaHub {
  MediaHub({
    required this.keyForSlot,
    required this.discoveryInfo,
    this.port = Proto.hubPort,
    InternetAddress? bindAddress,
  }) : bindAddress = bindAddress ?? InternetAddress.anyIPv4;

  final Uint8List? Function(int slot) keyForSlot;
  final Map<String, dynamic> Function() discoveryInfo;
  final int port;
  final InternetAddress bindAddress;

  RawDatagramSocket? _socket;
  final Map<int, _Endpoint> _endpoints = {};
  Timer? _sweep;

  int forwarded = 0;

  String get debugStats => 'fwd=$forwarded unknown=$droppedUnknownSender '
      'stale=$droppedStaleSender noTarget=$droppedNoTarget '
      'endpoints=${{for (final e in _endpoints.entries) e.key: '${e.value.address.address}:${e.value.port}'}}';

  /// Diagnóstico de pacotes de mídia descartados.
  int droppedUnknownSender = 0;
  int droppedStaleSender = 0;
  int droppedNoTarget = 0;

  int get boundPort => _socket?.port ?? port;

  Future<void> start() async {
    final s = await RawDatagramSocket.bind(bindAddress, port);
    s.writeEventsEnabled = false;
    _socket = s;
    s.listen(
      (ev) {
        if (ev == RawSocketEvent.read) _drain(s);
      },
      onError: (Object _) {},
    );
    _sweep = Timer.periodic(const Duration(seconds: 5), (_) => _purge());
  }

  Future<void> stop() async {
    _sweep?.cancel();
    _sweep = null;
    _socket?.close();
    _socket = null;
    _endpoints.clear();
  }

  void _drain(RawDatagramSocket s) {
    while (true) {
      final dg = s.receive();
      if (dg == null) break;
      _handle(s, dg);
    }
  }

  void _handle(RawDatagramSocket s, Datagram dg) {
    final data = dg.data;
    final h = PacketHeader.parse(data);
    if (h == null) return;
    switch (h.type) {
      case Proto.typeData:
        final from = _endpoints[h.a];
        if (from == null || !from.matches(dg)) {
          droppedUnknownSender++;
          return;
        }
        // O lugar pode ter mudado de dono: só vale a chave atual.
        if (!identical(keyForSlot(h.a), from.key)) {
          droppedStaleSender++;
          return;
        }
        from.lastSeenMs = _now();
        final to = _endpoints[h.b];
        if (to == null || !identical(keyForSlot(h.b), to.key)) {
          droppedNoTarget++;
          return;
        }
        _send(s, data, to.address, to.port);
        forwarded++;
      case Proto.typeHello:
        final parsed = Packets.parseHello(data);
        if (parsed == null) return;
        final key = keyForSlot(h.a);
        if (key == null || !bytesEqual(parsed.$1, key)) return;
        final ep = _endpoints[h.a];
        if (ep == null || !ep.matches(dg) || !identical(ep.key, key)) {
          _endpoints[h.a] = _Endpoint(dg.address, dg.port, key);
        } else {
          ep.lastSeenMs = _now();
        }
        _send(s, Packets.helloAck(h.a, parsed.$2), dg.address, dg.port);
      case Proto.typeDiscover:
        final nonce = Packets.parseNonce(data);
        if (nonce == null) return;
        _send(s, Packets.offer(nonce, discoveryInfo()), dg.address, dg.port);
    }
  }

  void _send(RawDatagramSocket s, List<int> data, InternetAddress a, int p) {
    try {
      s.send(data, a, p);
    } catch (_) {
      // Rede indisponível momentaneamente; o WebRTC retransmite.
    }
  }

  void _purge() {
    final now = _now();
    _endpoints.removeWhere((slot, ep) =>
        !identical(keyForSlot(slot), ep.key) || now - ep.lastSeenMs > 30000);
  }
}
