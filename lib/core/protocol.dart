import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

/// Constantes e codificação dos pacotes trocados entre os celulares.
///
/// Dois canais existem:
///  * Sinalização (TCP/WebSocket no host): JSON com entrada/saída de pessoas
///    e ofertas/respostas SDP do WebRTC.
///  * Mídia (UDP no host, "hub"): pacotes binários pequenos. Todo o tráfego
///    WebRTC de cada celular vai por loopback até o túnel local, que o embrulha
///    com um cabeçalho de 5 bytes e envia ao hub, que repassa ao destino.
class Proto {
  static const int version = 1;

  /// Porta TCP do servidor de sinalização (WebSocket) no host.
  static const int wsPort = 47800;

  /// Porta UDP do hub de mídia e da descoberta no host.
  static const int hubPort = 47801;

  /// Limite de pessoas na sala (host incluído).
  static const int maxPeers = 4;

  static const int magic0 = 0x43; // 'C'
  static const int magic1 = 0x42; // 'B'

  static const int typeData = 0x01;
  static const int typeHello = 0x02;
  static const int typeHelloAck = 0x03;
  static const int typeDiscover = 0x10;
  static const int typeOffer = 0x11;

  static const int headerLength = 5;
  static const int tokenLength = 16;
}

/// Cabeçalho binário comum: [magic0, magic1, type, a, b].
class PacketHeader {
  const PacketHeader(this.type, this.a, this.b);

  final int type;
  final int a;
  final int b;

  static PacketHeader? parse(Uint8List data) {
    if (data.length < Proto.headerLength) return null;
    if (data[0] != Proto.magic0 || data[1] != Proto.magic1) return null;
    return PacketHeader(data[2], data[3], data[4]);
  }
}

class Packets {
  static Uint8List data(int fromSlot, int toSlot, Uint8List payload) {
    final out = Uint8List(Proto.headerLength + payload.length);
    out[0] = Proto.magic0;
    out[1] = Proto.magic1;
    out[2] = Proto.typeData;
    out[3] = fromSlot & 0xff;
    out[4] = toSlot & 0xff;
    out.setRange(Proto.headerLength, out.length, payload);
    return out;
  }

  static Uint8List hello(int slot, Uint8List token, int timestampMs) {
    final out = Uint8List(Proto.headerLength + Proto.tokenLength + 8);
    out[0] = Proto.magic0;
    out[1] = Proto.magic1;
    out[2] = Proto.typeHello;
    out[3] = slot & 0xff;
    out[4] = 0;
    out.setRange(Proto.headerLength, Proto.headerLength + Proto.tokenLength, token);
    ByteData.sublistView(out).setInt64(Proto.headerLength + Proto.tokenLength, timestampMs);
    return out;
  }

  static Uint8List helloAck(int slot, int echoTimestampMs) {
    final out = Uint8List(Proto.headerLength + 8);
    out[0] = Proto.magic0;
    out[1] = Proto.magic1;
    out[2] = Proto.typeHelloAck;
    out[3] = 0;
    out[4] = slot & 0xff;
    ByteData.sublistView(out).setInt64(Proto.headerLength, echoTimestampMs);
    return out;
  }

  static Uint8List discover(int nonce) {
    final out = Uint8List(Proto.headerLength + 4);
    out[0] = Proto.magic0;
    out[1] = Proto.magic1;
    out[2] = Proto.typeDiscover;
    ByteData.sublistView(out).setUint32(Proto.headerLength, nonce);
    return out;
  }

  static Uint8List offer(int nonce, Map<String, dynamic> info) {
    final json = utf8.encode(jsonEncode(info));
    final out = Uint8List(Proto.headerLength + 4 + json.length);
    out[0] = Proto.magic0;
    out[1] = Proto.magic1;
    out[2] = Proto.typeOffer;
    ByteData.sublistView(out).setUint32(Proto.headerLength, nonce);
    out.setRange(Proto.headerLength + 4, out.length, json);
    return out;
  }

  /// Lê o token e o timestamp de um HELLO. Retorna null se malformado.
  static (Uint8List token, int ts)? parseHello(Uint8List data) {
    if (data.length < Proto.headerLength + Proto.tokenLength + 8) return null;
    final token = Uint8List.sublistView(
        data, Proto.headerLength, Proto.headerLength + Proto.tokenLength);
    final ts = ByteData.sublistView(data)
        .getInt64(Proto.headerLength + Proto.tokenLength);
    return (token, ts);
  }

  static int? parseAckTimestamp(Uint8List data) {
    if (data.length < Proto.headerLength + 8) return null;
    return ByteData.sublistView(data).getInt64(Proto.headerLength);
  }

  static int? parseNonce(Uint8List data) {
    if (data.length < Proto.headerLength + 4) return null;
    return ByteData.sublistView(data).getUint32(Proto.headerLength);
  }

  static Map<String, dynamic>? parseOfferInfo(Uint8List data) {
    if (data.length <= Proto.headerLength + 4) return null;
    try {
      final decoded = jsonDecode(
          utf8.decode(Uint8List.sublistView(data, Proto.headerLength + 4)));
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (_) {
      return null;
    }
  }

  static Uint8List payloadOf(Uint8List data) =>
      Uint8List.sublistView(data, Proto.headerLength);
}

final Random _secure = Random.secure();

Uint8List randomBytes(int length) {
  final out = Uint8List(length);
  for (var i = 0; i < length; i++) {
    out[i] = _secure.nextInt(256);
  }
  return out;
}

String randomId([int bytes = 12]) {
  final b = randomBytes(bytes);
  final sb = StringBuffer();
  for (final v in b) {
    sb.write(v.toRadixString(16).padLeft(2, '0'));
  }
  return sb.toString();
}

int randomInt32() => _secure.nextInt(0x7fffffff);

bool bytesEqual(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}

/// Decodifica uma mensagem JSON de sinalização com segurança.
Map<String, dynamic>? decodeMessage(dynamic raw) {
  if (raw is! String) return null;
  try {
    final v = jsonDecode(raw);
    return v is Map<String, dynamic> ? v : null;
  } catch (_) {
    return null;
  }
}

int? asInt(dynamic v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v);
  return null;
}

String? asString(dynamic v) => v is String ? v : null;

bool asBool(dynamic v, [bool fallback = false]) => v is bool ? v : fallback;
