// Testes da parte de rede (sinalização, hub, túnel e descoberta), rodando
// tudo em loopback. O WebRTC em si só roda nos aparelhos.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:comboio/core/protocol.dart';
import 'package:comboio/net/discovery.dart';
import 'package:comboio/net/media_hub.dart';
import 'package:comboio/net/media_tunnel.dart';
import 'package:comboio/net/net_info.dart';
import 'package:comboio/net/room_server.dart';
import 'package:comboio/net/signaling_client.dart';
import 'package:flutter_test/flutter_test.dart';

typedef Msg = Map<String, dynamic>;

class _Peer {
  _Peer(this.id);

  final String id;
  late SignalingClient client;
  final List<Msg> messages = [];
  final List<(bool Function(Msg), Completer<Msg>)> _waiters = [];

  Future<void> connect(int port) async {
    client = SignalingClient('127.0.0.1', port);
    client.onMessage = (m) {
      messages.add(m);
      for (final w in _waiters.toList()) {
        if (w.$1(m) && !w.$2.isCompleted) {
          w.$2.complete(m);
          _waiters.remove(w);
        }
      }
    };
    await client.connect();
    client.send({'t': 'hello', 'id': id, 'name': id.toUpperCase(), 'muted': false});
  }

  Future<Msg> waitFor(bool Function(Msg) test,
      {Duration timeout = const Duration(seconds: 4)}) {
    for (final m in messages) {
      if (test(m)) return Future.value(m);
    }
    final c = Completer<Msg>();
    _waiters.add((test, c));
    return c.future.timeout(timeout);
  }

  Future<Msg> welcome() => waitFor((m) => m['t'] == 'welcome');
}

Future<void> _until(bool Function() cond,
    {Duration timeout = const Duration(seconds: 4),
    String Function()? what}) async {
  final end = DateTime.now().add(timeout);
  while (!cond()) {
    if (DateTime.now().isAfter(end)) {
      throw TimeoutException('condição: ${what?.call() ?? ''}');
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

Future<Uint8List> _receiveOne(RawDatagramSocket s,
    {Duration timeout = const Duration(seconds: 3)}) {
  final c = Completer<Uint8List>();
  late StreamSubscription<RawSocketEvent> sub;
  sub = s.listen((ev) {
    if (ev != RawSocketEvent.read) return;
    final dg = s.receive();
    if (dg != null && !c.isCompleted) {
      c.complete(dg.data);
      unawaited(sub.cancel());
    }
  });
  return c.future.timeout(timeout);
}

void main() {
  setUpAll(() => HttpOverrides.global = null);

  group('protocolo', () {
    test('DATA preserva origem, destino e conteúdo', () {
      final payload = Uint8List.fromList([1, 2, 3, 250]);
      final pkt = Packets.data(2, 3, payload);
      final h = PacketHeader.parse(pkt)!;
      expect(h.type, Proto.typeData);
      expect(h.a, 2);
      expect(h.b, 3);
      expect(Packets.payloadOf(pkt), payload);
    });

    test('HELLO carrega token e horário', () {
      final token = randomBytes(Proto.tokenLength);
      final parsed = Packets.parseHello(Packets.hello(4, token, 123456789))!;
      expect(parsed.$1, token);
      expect(parsed.$2, 123456789);
      expect(Packets.parseAckTimestamp(Packets.helloAck(4, 99)), 99);
    });

    test('OFFER carrega as informações da sala', () {
      final pkt = Packets.offer(77, {'room': 'Sala de Ana', 'ws': 1234});
      expect(Packets.parseNonce(pkt), 77);
      expect(Packets.parseOfferInfo(pkt)!['room'], 'Sala de Ana');
    });

    test('pacotes estranhos são ignorados', () {
      expect(PacketHeader.parse(Uint8List.fromList([1, 2, 3])), isNull);
      expect(PacketHeader.parse(Uint8List.fromList([9, 9, 1, 1, 1])), isNull);
    });

    test('alvos da varredura (/24 e /28 do iPhone)', () {
      const n = LocalNet(wifiIp: '192.168.43.57', prefix: 24, gateway: '192.168.43.1');
      expect(n.subnetTargets().length, 253);
      expect(n.priorityTargets(null).first.address, '192.168.43.1');
      const iphone = LocalNet(wifiIp: '172.20.10.2', prefix: 28);
      expect(iphone.subnetTargets().length, 13);
      expect(iphone.priorityTargets('172.20.10.1').first.address, '172.20.10.1');
    });
  });

  group('sala', () {
    late RoomServer server;
    late MediaHub hub;

    setUp(() async {
      server = RoomServer(
        hostId: 'host',
        hostName: 'Pedro',
        port: 0,
        bindAddress: InternetAddress.loopbackIPv4,
        grace: const Duration(milliseconds: 1200),
      );
      hub = MediaHub(
        keyForSlot: server.keyForSlot,
        discoveryInfo: server.discoveryInfo,
        port: 0,
        bindAddress: InternetAddress.loopbackIPv4,
      );
      await hub.start();
      server.hubPort = hub.boundPort;
      await server.start();
    });

    tearDown(() async {
      await server.stop();
      await hub.stop();
    });

    test('quatro entram e o quinto recebe "sala cheia"', () async {
      final peers = [for (final id in ['host', 'b', 'c', 'd']) _Peer(id)];
      final slots = <int>{};
      for (final p in peers) {
        await p.connect(server.boundPort);
        final w = await p.welcome();
        slots.add(w['you']['slot'] as int);
      }
      expect(slots, {1, 2, 3, 4});
      final last = await peers.last.welcome();
      expect((last['peers'] as List).length, 3);
      await peers.first.waitFor(
          (m) => m['t'] == 'peer-joined' && m['peer']['id'] == 'd');

      final extra = _Peer('e');
      await extra.connect(server.boundPort);
      final full = await extra.waitFor((m) => m['t'] == 'full');
      expect(full['max'], 4);
      for (final p in peers) {
        await p.client.close();
      }
    });

    test('repassa sinais, avisa saídas e segura quem cai por um tempo', () async {
      final a = _Peer('a');
      final b = _Peer('b');
      final c = _Peer('c');
      for (final p in [a, b, c]) {
        await p.connect(server.boundPort);
        await p.welcome();
      }

      a.client.send({
        't': 'signal',
        'to': 'b',
        'data': {'kind': 'offer', 'session': 7, 'sdp': 'v=0'},
      });
      final sig = await b.waitFor((m) => m['t'] == 'signal');
      expect(sig['from'], 'a');
      expect(sig['data']['session'], 7);

      b.client.send({'t': 'bye'});
      await a.waitFor((m) => m['t'] == 'peer-left' && m['id'] == 'b');

      // Queda brusca: primeiro fica offline, depois sai.
      await c.client.close();
      await a.waitFor((m) =>
          m['t'] == 'peer-updated' &&
          m['peer']['id'] == 'c' &&
          m['peer']['online'] == false);
      await a.waitFor((m) => m['t'] == 'peer-left' && m['id'] == 'c',
          timeout: const Duration(seconds: 6));
      await a.client.close();
    });

    test('volta dentro da tolerância mantém o mesmo lugar', () async {
      final a = _Peer('a');
      final b = _Peer('b');
      await a.connect(server.boundPort);
      await a.welcome();
      await b.connect(server.boundPort);
      final first = await b.welcome();
      await b.client.close();

      final again = _Peer('b');
      await again.connect(server.boundPort);
      final second = await again.welcome();
      expect(second['you']['slot'], first['you']['slot']);
      await a.waitFor((m) =>
          m['t'] == 'peer-updated' &&
          m['peer']['id'] == 'b' &&
          m['peer']['online'] == true);
      expect(a.messages.where((m) => m['t'] == 'peer-left'), isEmpty);
      await a.client.close();
      await again.client.close();
    });

    test('túnel leva os pacotes de um celular ao outro', () async {
      final a = _Peer('a');
      final b = _Peer('b');
      await a.connect(server.boundPort);
      final wa = await a.welcome();
      await b.connect(server.boundPort);
      final wb = await b.welcome();
      final slotA = wa['you']['slot'] as int;
      final slotB = wb['you']['slot'] as int;
      final keyA = base64Decode(wa['you']['key'] as String);
      final keyB = base64Decode(wb['you']['key'] as String);
      expect(keyA, isNot(equals(keyB)));
      final hubPort = wa['room']['hubPort'] as int;

      final t1 = MediaTunnel(
        mySlot: slotA,
        token: keyA,
        hubAddress: InternetAddress.loopbackIPv4,
        hubPort: hubPort,
      );
      final t2 = MediaTunnel(
        mySlot: slotB,
        token: keyB,
        hubAddress: InternetAddress.loopbackIPv4,
        hubPort: hubPort,
      );
      await t1.start();
      await t2.start();
      await _until(() => t1.hubAlive && t2.hubAlive);

      final toB = await t1.openPipe(slotB);
      final toA = await t2.openPipe(slotA);
      final pc1 = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
      final pc2 = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);

      String diag() => 'toA=$toA toB=$toB pc1=${pc1.port} pc2=${pc2.port} '
          'slotA=$slotA slotB=$slotB hub[${hub.debugStats}] '
          't1[pipes=${t1.pipeStats} notMine=${t1.droppedNotMine} '
          'noPipe=${t1.droppedNoPipe} noPort=${t1.droppedNoPort} '
          'foreign=${t1.droppedForeign}] '
          't2[pipes=${t2.pipeStats} notMine=${t2.droppedNotMine} '
          'noPipe=${t2.droppedNoPipe} noPort=${t2.droppedNoPort} '
          'foreign=${t2.droppedForeign}]';

      // O "WebRTC" do lado B se apresenta primeiro (o túnel aprende a porta).
      pc2.send(utf8.encode('init'), InternetAddress.loopbackIPv4, toA);
      await _until(() => (t2.pipeStats[slotA]?.$1 ?? 0) >= 1,
          what: () => 'init não saiu de t2: ${diag()}');
      await _until(() => hub.forwarded >= 1,
          what: () => 'hub não repassou init: ${diag()}');
      await _until(() => t1.droppedNoPort >= 1,
          what: () => 'init não chegou em t1: ${diag()}');

      pc1.send(utf8.encode('ola de A'), InternetAddress.loopbackIPv4, toB);
      await _until(() => (t1.pipeStats[slotB]?.$1 ?? 0) >= 1,
          what: () => 'ola não saiu de t1: ${diag()}');
      await _until(() => hub.forwarded >= 2,
          what: () => 'hub não repassou ola: ${diag()}');
      await _until(() => (t2.pipeStats[slotA]?.$2 ?? 0) >= 1,
          what: () => 'ola não foi entregue por t2: ${diag()}');
      // O datagrama fica na fila do socket até alguém ler.
      expect(utf8.decode(await _receiveOne(pc2)), 'ola de A', reason: diag());

      pc2.send(utf8.encode('oi de B'), InternetAddress.loopbackIPv4, toA);
      await _until(() => (t1.pipeStats[slotB]?.$2 ?? 0) >= 1,
          what: () => 'oi não foi entregue por t1: ${diag()}');
      expect(utf8.decode(await _receiveOne(pc1)), 'oi de B', reason: diag());
      expect(hub.forwarded, greaterThanOrEqualTo(2));

      pc1.close();
      pc2.close();
      await t1.close();
      await t2.close();
      await a.client.close();
      await b.client.close();
    });

    test('hub ignora quem não tem a chave do lugar', () async {
      final a = _Peer('a');
      await a.connect(server.boundPort);
      final wa = await a.welcome();
      final intruder = MediaTunnel(
        mySlot: wa['you']['slot'] as int,
        token: randomBytes(Proto.tokenLength),
        hubAddress: InternetAddress.loopbackIPv4,
        hubPort: hub.boundPort,
      );
      await intruder.start();
      await Future<void>.delayed(const Duration(milliseconds: 600));
      expect(intruder.hubAlive, isFalse);
      await intruder.close();
      await a.client.close();
    });

    test('descoberta encontra a sala', () async {
      final rooms = await RoomFinder.probe(
        [InternetAddress.loopbackIPv4],
        port: hub.boundPort,
        wait: const Duration(milliseconds: 600),
      );
      expect(rooms, hasLength(1));
      expect(rooms.single.roomName, 'Sala de Pedro');
      expect(rooms.single.wsPort, server.boundPort);
      expect(rooms.single.isFull, isFalse);
    });
  });
}
