import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../core/protocol.dart';

/// Cliente WebSocket da sinalização.
class SignalingClient {
  SignalingClient(this.host, this.port);

  final String host;
  final int port;

  WebSocket? _ws;

  void Function(Map<String, dynamic> msg)? onMessage;
  void Function(int? code, String? reason)? onClosed;

  bool get isOpen => _ws?.readyState == WebSocket.open;

  Future<void> connect({Duration timeout = const Duration(seconds: 4)}) async {
    final client = HttpClient()..connectionTimeout = timeout;
    final WebSocket ws;
    try {
      ws = await WebSocket.connect('ws://$host:$port/ws', customClient: client)
          .timeout(timeout + const Duration(seconds: 1));
    } catch (_) {
      client.close(force: true);
      rethrow;
    }
    ws.pingInterval = const Duration(seconds: 3);
    _ws = ws;
    ws.listen(
      (raw) {
        final m = decodeMessage(raw);
        if (m != null) onMessage?.call(m);
      },
      onDone: () {
        if (identical(_ws, ws)) {
          _ws = null;
          onClosed?.call(ws.closeCode, ws.closeReason);
        }
      },
      onError: (Object _) {},
      cancelOnError: false,
    );
  }

  void send(Map<String, dynamic> msg) {
    final ws = _ws;
    if (ws == null) return;
    try {
      ws.add(jsonEncode(msg));
    } catch (_) {}
  }

  Future<void> close() async {
    final ws = _ws;
    _ws = null;
    if (ws == null) return;
    try {
      await ws.close(1000).timeout(const Duration(seconds: 1));
    } catch (_) {}
  }
}
