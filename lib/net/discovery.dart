import 'dart:async';
import 'dart:io';

import '../core/protocol.dart';

class FoundRoom {
  FoundRoom({
    required this.address,
    required this.wsPort,
    required this.roomName,
    required this.hostName,
    required this.count,
    required this.max,
  });

  factory FoundRoom.fromInfo(InternetAddress address, Map<String, dynamic> m) =>
      FoundRoom(
        address: address,
        wsPort: asInt(m['ws']) ?? Proto.wsPort,
        roomName: asString(m['room']) ?? 'Sala',
        hostName: asString(m['host']) ?? '',
        count: asInt(m['count']) ?? 0,
        max: asInt(m['max']) ?? Proto.maxPeers,
      );

  final InternetAddress address;
  final int wsPort;
  final String roomName;
  final String hostName;
  final int count;
  final int max;

  bool get isFull => count >= max;
}

/// Procura salas mandando um DISCOVER (UDP unicast) para cada endereço.
class RoomFinder {
  static Future<List<FoundRoom>> probe(
    Iterable<InternetAddress> targets, {
    int port = Proto.hubPort,
    Duration wait = const Duration(milliseconds: 700),
  }) async {
    final list = targets.toList();
    if (list.isEmpty) return const [];
    final RawDatagramSocket socket;
    try {
      socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    } catch (_) {
      return const [];
    }
    final nonce = randomInt32();
    final found = <String, FoundRoom>{};
    final sub = socket.listen(
      (ev) {
        if (ev != RawSocketEvent.read) return;
        while (true) {
          final dg = socket.receive();
          if (dg == null) break;
          final h = PacketHeader.parse(dg.data);
          if (h == null || h.type != Proto.typeOffer) continue;
          if (Packets.parseNonce(dg.data) != nonce) continue;
          final info = Packets.parseOfferInfo(dg.data);
          if (info == null) continue;
          found[dg.address.address] = FoundRoom.fromInfo(dg.address, info);
        }
      },
      onError: (Object _) {},
    );
    try {
      final packet = Packets.discover(nonce);
      for (var i = 0; i < list.length; i++) {
        try {
          socket.send(packet, list[i], port);
        } catch (_) {}
        if (i % 48 == 47) {
          await Future<void>.delayed(const Duration(milliseconds: 4));
        }
      }
      // Encerra cedo se já achou algo e passou um tempinho.
      final deadline = DateTime.now().add(wait);
      while (DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 60));
        if (found.isNotEmpty &&
            DateTime.now().isAfter(deadline.subtract(wait ~/ 2))) {
          break;
        }
      }
    } finally {
      await sub.cancel();
      socket.close();
    }
    return found.values.toList();
  }
}
