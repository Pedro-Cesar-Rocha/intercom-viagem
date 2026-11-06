import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../core/prefs.dart';
import '../core/protocol.dart';

class RoomMember {
  RoomMember({
    required this.id,
    required this.name,
    required this.slot,
    required this.isHost,
  });

  final String id;
  String name;
  final int slot;
  final bool isHost;

  /// Chave de mídia desta pessoa (vale enquanto ela ocupa o lugar).
  final Uint8List key = randomBytes(Proto.tokenLength);
  bool muted = false;
  WebSocket? socket;
  Timer? graceTimer;

  bool get online => socket != null;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'slot': slot,
        'muted': muted,
        'host': isHost,
        'online': online,
      };
}

/// Servidor de sinalização que roda no celular do host.
///
/// Mantém a lista de pessoas (até [maxPeers]), distribui um "slot" curto para
/// cada uma (usado no túnel de mídia) e repassa as ofertas/respostas SDP.
/// Quem cai fica reservado por [grace] para poder voltar sem derrubar o áudio.
class RoomServer {
  RoomServer({
    required this.hostId,
    required this.hostName,
    this.port = Proto.wsPort,
    this.hubPort = Proto.hubPort,
    this.maxPeers = Proto.maxPeers,
    this.grace = const Duration(seconds: 20),
    InternetAddress? bindAddress,
  }) : bindAddress = bindAddress ?? InternetAddress.anyIPv4;

  final String hostId;
  final String hostName;
  final int port;
  int hubPort;
  final int maxPeers;
  final Duration grace;
  final InternetAddress bindAddress;

  final Map<String, RoomMember> _members = {};
  HttpServer? _http;
  bool _closing = false;

  String get roomName => 'Sala de $hostName';
  int get boundPort => _http?.port ?? port;
  int get memberCount => _members.length;
  Iterable<RoomMember> get members => _members.values;
  bool get isRunning => _http != null && !_closing;

  /// Chave de quem ocupa o lugar [slot], ou null se o lugar está livre.
  Uint8List? keyForSlot(int slot) {
    for (final m in _members.values) {
      if (m.slot == slot) return m.key;
    }
    return null;
  }

  Map<String, dynamic> discoveryInfo() => {
        'v': Proto.version,
        'room': roomName,
        'host': hostName,
        'count': _members.length,
        'max': maxPeers,
        'ws': boundPort,
      };

  Future<void> start() async {
    final server = await HttpServer.bind(bindAddress, port);
    server.idleTimeout = const Duration(seconds: 30);
    _http = server;
    server.listen(
      (req) => unawaited(_onRequest(req)),
      onError: (Object _) {},
    );
  }

  Future<void> stop() async {
    if (_closing) return;
    _closing = true;
    for (final m in _members.values) {
      m.graceTimer?.cancel();
      final s = m.socket;
      if (s != null) _send(s, {'t': 'closing'});
    }
    await Future<void>.delayed(const Duration(milliseconds: 200));
    for (final m in _members.values) {
      final s = m.socket;
      m.socket = null;
      if (s != null) unawaited(_closeSocket(s, 1001, 'room closed'));
    }
    _members.clear();
    final http = _http;
    _http = null;
    await http?.close(force: true);
  }

  Future<void> _onRequest(HttpRequest req) async {
    try {
      if (_closing) {
        req.response.statusCode = HttpStatus.serviceUnavailable;
        await req.response.close();
        return;
      }
      if (req.uri.path == '/ws' && WebSocketTransformer.isUpgradeRequest(req)) {
        final ws = await WebSocketTransformer.upgrade(req);
        ws.pingInterval = const Duration(seconds: 3);
        _attach(ws);
        return;
      }
      if (req.uri.path == '/info') {
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode(discoveryInfo()));
        await req.response.close();
        return;
      }
      req.response.statusCode = HttpStatus.notFound;
      await req.response.close();
    } catch (_) {
      // Conexão quebrada no meio do caminho; nada a fazer.
    }
  }

  void _attach(WebSocket ws) {
    RoomMember? member;
    var rejected = false;
    final helloTimer = Timer(const Duration(seconds: 8), () {
      if (member == null) unawaited(_closeSocket(ws, 4000, 'no hello'));
    });
    ws.listen(
      (raw) {
        if (rejected) return;
        final msg = decodeMessage(raw);
        if (msg == null) return;
        final current = member;
        if (current == null) {
          if (msg['t'] != 'hello') return;
          helloTimer.cancel();
          member = _join(ws, msg);
          if (member == null) rejected = true;
          return;
        }
        _handle(current, ws, msg);
      },
      onDone: () {
        helloTimer.cancel();
        final m = member;
        if (m != null) _detach(m, ws);
      },
      onError: (Object _) {},
      cancelOnError: false,
    );
  }

  RoomMember? _join(WebSocket ws, Map<String, dynamic> msg) {
    final id = asString(msg['id']);
    if (id == null || id.isEmpty || id.length > 64) {
      _send(ws, {'t': 'error', 'reason': 'bad-hello'});
      unawaited(_closeSocket(ws, 4001, 'bad hello'));
      return null;
    }
    final name = cleanName(asString(msg['name']));
    var m = _members[id];
    if (m == null) {
      final slot = _freeSlot();
      if (slot == null) {
        _send(ws, {'t': 'full', 'max': maxPeers, 'room': roomName});
        unawaited(_closeSocket(ws, 4002, 'full'));
        return null;
      }
      m = RoomMember(id: id, name: name, slot: slot, isHost: id == hostId);
      m.muted = asBool(msg['muted']);
      m.socket = ws;
      _members[id] = m;
      _send(ws, _welcome(m));
      _broadcast({'t': 'peer-joined', 'peer': m.toJson()}, except: id);
    } else {
      // Voltou dentro do período de tolerância (ou abriu um socket novo).
      m.graceTimer?.cancel();
      m.graceTimer = null;
      final old = m.socket;
      m.socket = ws;
      m.name = name;
      m.muted = asBool(msg['muted'], m.muted);
      if (old != null && !identical(old, ws)) {
        unawaited(_closeSocket(old, 4003, 'replaced'));
      }
      _send(ws, _welcome(m));
      _broadcast({'t': 'peer-updated', 'peer': m.toJson()}, except: id);
    }
    return m;
  }

  Map<String, dynamic> _welcome(RoomMember m) => {
        't': 'welcome',
        'v': Proto.version,
        'you': {'id': m.id, 'slot': m.slot, 'key': base64Encode(m.key)},
        'room': {
          'name': roomName,
          'hostId': hostId,
          'hubPort': hubPort,
          'max': maxPeers,
        },
        'peers': [
          for (final o in _members.values)
            if (o.id != m.id) o.toJson(),
        ],
      };

  void _handle(RoomMember m, WebSocket ws, Map<String, dynamic> msg) {
    if (!identical(m.socket, ws)) return; // socket antigo
    switch (msg['t']) {
      case 'signal':
        final to = asString(msg['to']);
        final target = to == null ? null : _members[to];
        final socket = target?.socket;
        if (socket != null) {
          _send(socket, {'t': 'signal', 'from': m.id, 'data': msg['data']});
        }
      case 'state':
        if (msg.containsKey('muted')) m.muted = asBool(msg['muted'], m.muted);
        final n = asString(msg['name']);
        if (n != null) m.name = cleanName(n);
        _broadcast({'t': 'peer-updated', 'peer': m.toJson()}, except: m.id);
      case 'bye':
        _remove(m);
        unawaited(_closeSocket(ws, 1000, 'bye'));
      case 'ping':
        _send(ws, {'t': 'pong', 'ts': msg['ts']});
    }
  }

  void _detach(RoomMember m, WebSocket ws) {
    if (!identical(m.socket, ws)) return;
    m.socket = null;
    if (_closing || !_members.containsKey(m.id)) return;
    _broadcast({'t': 'peer-updated', 'peer': m.toJson()}, except: m.id);
    m.graceTimer?.cancel();
    m.graceTimer = Timer(grace, () {
      if (!m.online) _remove(m);
    });
  }

  void _remove(RoomMember m) {
    m.graceTimer?.cancel();
    m.graceTimer = null;
    if (_members.remove(m.id) == null) return;
    m.socket = null;
    _broadcast({'t': 'peer-left', 'id': m.id});
  }

  int? _freeSlot() {
    final used = {for (final m in _members.values) m.slot};
    for (var s = 1; s <= maxPeers; s++) {
      if (!used.contains(s)) return s;
    }
    return null;
  }

  void _broadcast(Map<String, dynamic> msg, {String? except}) {
    final text = jsonEncode(msg);
    for (final m in _members.values) {
      if (m.id == except) continue;
      final s = m.socket;
      if (s == null) continue;
      try {
        s.add(text);
      } catch (_) {}
    }
  }

  void _send(WebSocket ws, Map<String, dynamic> msg) {
    try {
      ws.add(jsonEncode(msg));
    } catch (_) {}
  }

  Future<void> _closeSocket(WebSocket ws, int code, String reason) async {
    try {
      await ws.close(code, reason).timeout(const Duration(seconds: 2));
    } catch (_) {}
  }
}
