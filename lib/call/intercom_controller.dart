import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../core/native_bridge.dart';
import '../core/prefs.dart';
import '../core/protocol.dart';
import '../net/discovery.dart';
import '../net/media_hub.dart';
import '../net/media_tunnel.dart';
import '../net/net_info.dart';
import '../net/room_server.dart';
import '../net/signaling_client.dart';
import 'audio_engine.dart';
import 'peer_link.dart';

enum Role { host, guest }

enum Phase {
  idle,
  preparing,
  searching,
  connecting,
  live,
  reconnecting,
  ended,
  error,
}

class Participant {
  Participant({
    required this.id,
    required this.name,
    required this.slot,
    this.isHost = false,
    this.isMe = false,
  });

  final String id;
  String name;
  int slot;
  bool isHost;
  final bool isMe;
  bool muted = false;
  bool online = true;
  double level = 0;
  double? rttMs;
  double lossPct = 0;
  LinkStatus link = LinkStatus.connecting;
  double volume = 1.0;

  bool get isConnected => isMe || (online && link == LinkStatus.connected);
}

/// Orquestra a sala: servidor (no host), descoberta, sinalização, túnel de
/// mídia e as conexões WebRTC com cada pessoa. A interface só observa.
class IntercomController extends ChangeNotifier {
  IntercomController({required this.prefs, NativeBridge? native})
      : native = native ?? NativeBridge() {
    this.native.setActionHandler(_onNotificationAction);
  }

  final AppPrefs prefs;
  final NativeBridge native;

  // ------------------------------------------------------- estado público
  Role? role;
  Phase phase = Phase.idle;
  String? errorTitle;
  String? errorMessage;
  bool errorNeedsSettings = false;
  String roomName = '';
  String statusDetail = '';
  String? hostAddress;
  List<NetIface> hostInterfaces = const [];
  bool muted = false;
  bool speakerOn = true;
  bool keepScreenOn = false;
  bool hubAlive = true;
  double myLevel = 0;
  DateTime? searchStartedAt;
  String? fullRoomNotice;
  String myName = '';
  int mySlot = 0;

  String get myId => prefs.deviceId;
  bool get isActive => phase != Phase.idle;
  bool get isHost => role == Role.host;
  bool get signalingUp => _signaling?.isOpen ?? false;
  int? get hubRttMs => _tunnel?.hubRttMs;
  int get peopleCount => 1 + _peers.length;
  Stream<String> get toasts => _toasts.stream;

  Participant? peer(String id) => _peers[id];

  List<Participant> get participants {
    final me = Participant(
      id: myId,
      name: myName,
      slot: mySlot,
      isHost: isHost,
      isMe: true,
    )
      ..muted = muted
      ..level = muted ? 0 : myLevel
      ..link = LinkStatus.connected;
    final others = _peers.values.toList()
      ..sort((a, b) => a.slot.compareTo(b.slot));
    return [me, ...others];
  }

  // ------------------------------------------------------ estado interno
  final Map<String, Participant> _peers = {};
  final Map<String, PeerLink> _links = {};
  final AudioEngine _audio = AudioEngine();
  final StreamController<String> _toasts = StreamController<String>.broadcast();

  RoomServer? _server;
  MediaHub? _hub;
  SignalingClient? _signaling;
  MediaTunnel? _tunnel;
  Completer<bool>? _welcome;
  Future<void> _inbox = Future<void>.value();
  Timer? _statsTimer;
  Timer? _reconnectTimer;
  Timer? _hostInfoTimer;
  int _gen = 0;
  bool _leaving = false;
  bool _everConnected = false;
  bool _roomClosed = false;
  bool _searching = false;
  bool _polling = false;
  bool _anyLinkConnected = false;
  int _netHandle = 0;
  String? _manualHost;
  final Set<String> _primed = {};

  // ============================================================== ações

  /// Cria a sala neste celular (que deve estar com o hotspot ligado).
  Future<void> startHost(String name) async {
    final gen = await _begin(Role.host, name);
    if (gen == null) return;
    try {
      final net = await NetInfo.read(native);
      if (gen != _gen) return;
      // Host num Wi-Fi comum (sem hotspot próprio): prende o app nesse Wi-Fi.
      if (Platform.isAndroid && net.hotspot.isEmpty && net.hasWifi) {
        await native.bindToWifi();
      }
      final server = RoomServer(hostId: myId, hostName: myName);
      final hub = MediaHub(
        keyForSlot: server.keyForSlot,
        discoveryInfo: server.discoveryInfo,
      );
      await hub.start();
      try {
        await server.start();
      } catch (_) {
        await hub.stop();
        rethrow;
      }
      server.hubPort = hub.boundPort;
      if (gen != _gen) {
        await server.stop();
        await hub.stop();
        return;
      }
      _server = server;
      _hub = hub;
      roomName = server.roomName;
      await _refreshHostInfo();
      _hostInfoTimer = Timer.periodic(
          const Duration(seconds: 4), (_) => unawaited(_refreshHostInfo()));
      statusDetail = 'Abrindo a sala…';
      _setPhase(Phase.connecting);
      final ok = await _connectSignaling('127.0.0.1', server.boundPort, gen);
      if (!ok && gen == _gen) _scheduleReconnect(gen);
    } on SocketException catch (e) {
      if (gen != _gen) return;
      await _teardown();
      _fail(
        'Não deu para abrir a sala',
        'As portas de rede do Comboio estão ocupadas. Feche o app por '
            'completo e abra de novo.\n\nDetalhe: ${e.message}',
      );
    }
  }

  /// Procura a sala na rede Wi-Fi atual e entra nela.
  Future<void> joinRoom(String name, {String? manualHost}) async {
    final gen = await _begin(Role.guest, name);
    if (gen == null) return;
    _manualHost = manualHost;
    searchStartedAt = DateTime.now();
    unawaited(_searchLoop(gen));
  }

  /// Usa um endereço digitado pela pessoa.
  void connectTo(String ip) {
    final v = ip.trim();
    if (InternetAddress.tryParse(v) == null) return;
    _manualHost = v;
    statusDetail = 'Tentando $v…';
    notifyListeners();
    if (role == Role.guest && !_searching && !signalingUp) {
      unawaited(_searchLoop(_gen));
    }
  }

  Future<void> retry() async {
    final r = role ?? Role.guest;
    final name = myName.isEmpty ? prefs.name : myName;
    if (r == Role.host) {
      await startHost(name);
    } else {
      await joinRoom(name);
    }
  }

  Future<void> leave() async {
    if (_leaving || phase == Phase.idle) return;
    _leaving = true;
    try {
      await _stopSession(sayBye: true);
    } finally {
      role = null;
      phase = Phase.idle;
      statusDetail = '';
      _leaving = false;
      notifyListeners();
    }
  }

  /// Encerra a sessão atual sem mudar a fase da tela.
  Future<void> _stopSession({bool sayBye = false}) async {
    _gen++;
    final sig = _signaling;
    if (sayBye && sig != null && role == Role.guest) {
      sig.send({'t': 'bye'});
      await Future<void>.delayed(const Duration(milliseconds: 120));
    }
    await _teardown();
  }

  /// Uma sessão antiga terminou de abrir algo depois que a pessoa saiu.
  Future<void> _abandon() async {
    if (phase == Phase.idle) await _teardown();
  }

  Future<void> toggleMute() async {
    if (!isActive) return;
    muted = !muted;
    await _audio.setMuted(muted);
    _signaling?.send({'t': 'state', 'muted': muted});
    unawaited(HapticFeedback.mediumImpact());
    _updateNotification();
    notifyListeners();
  }

  Future<void> setSpeaker(bool on) async {
    speakerOn = on;
    prefs.speakerOn = on;
    notifyListeners();
    await _audio.setSpeaker(on);
  }

  Future<void> setPeerVolume(String id, double v) async {
    final p = _peers[id];
    if (p != null) p.volume = v;
    notifyListeners();
    await _links[id]?.setVolume(v);
  }

  Future<void> setKeepScreenOn(bool v) async {
    keepScreenOn = v;
    prefs.keepScreenOn = v;
    notifyListeners();
    if (isActive) await native.setKeepScreenOn(v);
  }

  @override
  void dispose() {
    _statsTimer?.cancel();
    _reconnectTimer?.cancel();
    _hostInfoTimer?.cancel();
    unawaited(_toasts.close());
    super.dispose();
  }

  // ==================================================== início da sessão

  Future<int?> _begin(Role r, String name) async {
    if (phase != Phase.idle) await _stopSession(sayBye: true);
    final gen = ++_gen;
    _leaving = false;
    _everConnected = false;
    _roomClosed = false;
    _anyLinkConnected = false;
    role = r;
    myName = cleanName(name);
    prefs.name = myName;
    muted = false;
    speakerOn = prefs.speakerOn;
    keepScreenOn = prefs.keepScreenOn;
    errorTitle = null;
    errorMessage = null;
    errorNeedsSettings = false;
    fullRoomNotice = null;
    roomName = r == Role.host ? 'Sala de $myName' : '';
    hostAddress = null;
    hostInterfaces = const [];
    mySlot = 0;
    myLevel = 0;
    hubAlive = true;
    _peers.clear();
    statusDetail = 'Preparando o microfone…';
    phase = Phase.preparing;
    notifyListeners();

    final perm = await native.requestPermissions();
    if (gen != _gen) return null;
    if (!perm.microphone) {
      _fail(
        'Permita o microfone',
        'O Comboio precisa do microfone para você conversar. Toque em '
            '"Abrir ajustes" e permita o acesso ao microfone.',
        needsSettings: true,
      );
      return null;
    }
    await native.startService(
      title: r == Role.host ? 'Sala aberta' : 'Comboio',
      text: 'Conectando…',
      muted: false,
    );
    if (gen != _gen) {
      await _abandon();
      return null;
    }
    if (keepScreenOn) await native.setKeepScreenOn(true);
    try {
      await _audio.start(speaker: speakerOn);
    } catch (e) {
      if (gen != _gen) {
        await _abandon();
        return null;
      }
      await _teardown();
      _fail(
        'Não consegui abrir o microfone',
        'Confira se outro app (ligação, gravador) está usando o microfone e '
            'tente de novo.\n\nDetalhe: $e',
      );
      return null;
    }
    if (gen != _gen) {
      await _abandon();
      return null;
    }
    return gen;
  }

  // ======================================================== descoberta

  Future<void> _searchLoop(int gen) async {
    if (_searching) return;
    _searching = true;
    try {
      var round = 0;
      while (gen == _gen && !_leaving && !signalingUp && !_roomClosed) {
        round++;
        _setPhase(_everConnected ? Phase.reconnecting : Phase.searching);
        final net = await NetInfo.read(native, bind: Platform.isAndroid);
        if (gen != _gen) return;
        if (net.handle != 0 && net.handle != _netHandle) {
          final changed = _netHandle != 0;
          _netHandle = net.handle;
          if (changed) await _tunnel?.rebind();
        }

        final found = <FoundRoom>[];
        final manual = _manualHost;
        if (manual != null) {
          statusDetail = 'Procurando a sala em $manual…';
          notifyListeners();
          found.addAll(await RoomFinder.probe([InternetAddress(manual)],
              wait: const Duration(milliseconds: 900)));
          if (found.isEmpty && gen == _gen) {
            // O UDP pode estar bloqueado: tenta a sinalização direto.
            if (await _connectSignaling(manual, Proto.wsPort, gen)) return;
          }
        } else if (!net.hasWifi) {
          statusDetail = 'Conecte este celular ao Wi-Fi do hotspot do host.';
          notifyListeners();
        } else {
          statusDetail = 'Procurando a sala na rede ${net.wifiIp}…';
          notifyListeners();
          found.addAll(await RoomFinder.probe(
              net.priorityTargets(prefs.lastHost),
              wait: const Duration(milliseconds: 500)));
          if (found.isEmpty && gen == _gen) {
            found.addAll(await RoomFinder.probe(net.subnetTargets(),
                wait: const Duration(milliseconds: 1100)));
          }
        }
        if (gen != _gen) return;

        found.sort((a, b) => _score(b, net).compareTo(_score(a, net)));
        for (final room in found) {
          if (room.isFull && !_everConnected) {
            fullRoomNotice =
                '${room.roomName} está cheia (${room.count}/${room.max}).';
            notifyListeners();
            continue;
          }
          statusDetail = 'Entrando na ${room.roomName}…';
          _setPhase(_everConnected ? Phase.reconnecting : Phase.connecting);
          if (await _connectSignaling(room.address.address, room.wsPort, gen)) {
            return;
          }
          if (gen != _gen) return;
        }
        await Future<void>.delayed(
            Duration(milliseconds: round < 6 ? 1200 : 2500));
      }
    } finally {
      _searching = false;
    }
  }

  int _score(FoundRoom r, LocalNet net) {
    var s = 0;
    final ip = r.address.address;
    if (ip == hostAddress || ip == prefs.lastHost) s += 4;
    if (ip == net.gateway || ip == net.dhcp) s += 2;
    if (!r.isFull) s += 1;
    return s;
  }

  // ======================================================= sinalização

  Future<bool> _connectSignaling(String host, int port, int gen) async {
    final client = SignalingClient(host, port);
    try {
      await client.connect();
    } catch (_) {
      return false;
    }
    if (gen != _gen || _leaving) {
      unawaited(client.close());
      return false;
    }
    final waiter = Completer<bool>();
    _welcome = waiter;
    client.onMessage = (m) => _onMessage(client, m, gen);
    client.onClosed = (code, reason) => _onClosed(client, gen);
    final previous = _signaling;
    _signaling = client;
    hostAddress = host;
    if (previous != null && !identical(previous, client)) {
      previous.onClosed = null;
      unawaited(previous.close());
    }
    client.send({
      't': 'hello',
      'v': Proto.version,
      'id': myId,
      'name': myName,
      'muted': muted,
      'platform': Platform.operatingSystem,
    });
    var ok = false;
    try {
      ok = await waiter.future.timeout(const Duration(seconds: 6));
    } catch (_) {
      ok = false;
    }
    if (!ok || gen != _gen) {
      if (identical(_signaling, client)) _signaling = null;
      client.onClosed = null;
      unawaited(client.close());
      return false;
    }
    return true;
  }

  void _completeWelcome(bool ok) {
    final w = _welcome;
    _welcome = null;
    if (w != null && !w.isCompleted) w.complete(ok);
  }

  void _onMessage(SignalingClient client, Map<String, dynamic> m, int gen) {
    _inbox = _inbox.then((_) async {
      if (gen != _gen || !identical(client, _signaling)) return;
      await _handleMessage(m, gen);
    }).catchError((Object e) {
      debugPrint('mensagem: $e');
    });
  }

  Future<void> _handleMessage(Map<String, dynamic> m, int gen) async {
    switch (m['t']) {
      case 'welcome':
        await _onWelcome(m, gen).timeout(
          const Duration(seconds: 5),
          onTimeout: () => _completeWelcome(false),
        );
      case 'full':
        fullRoomNotice = 'A sala está cheia (máximo de '
            '${asInt(m['max']) ?? Proto.maxPeers} pessoas).';
        _completeWelcome(false);
        notifyListeners();
      case 'error':
        _completeWelcome(false);
      case 'peer-joined':
        _upsertPeer(m['peer'], announce: true);
      case 'peer-updated':
        _upsertPeer(m['peer']);
      case 'peer-left':
        _removePeer(asString(m['id']), announce: true);
      case 'signal':
        final from = asString(m['from']);
        final data = m['data'];
        if (from != null && data is Map<String, dynamic>) {
          _links[from]?.onSignal(data);
        }
      case 'closing':
        if (role == Role.guest) _onRoomClosed();
    }
  }

  Future<void> _onWelcome(Map<String, dynamic> m, int gen) async {
    try {
      final you = m['you'];
      final room = m['room'];
      if (you is! Map || room is! Map) {
        _completeWelcome(false);
        return;
      }
      final slot = asInt(you['slot']) ?? 0;
      final token = base64Decode(asString(you['key']) ?? '');
      final hubPort = asInt(room['hubPort']) ?? Proto.hubPort;
      if (slot <= 0 || token.length != Proto.tokenLength) {
        _completeWelcome(false);
        return;
      }
      roomName = asString(room['name']) ?? roomName;
      final hubAddr = InternetAddress(
          role == Role.host ? '127.0.0.1' : (hostAddress ?? '127.0.0.1'));
      final slotChanged = mySlot != 0 && mySlot != slot;
      mySlot = slot;

      final existing = _tunnel;
      if (existing == null) {
        final t = MediaTunnel(
          mySlot: slot,
          token: token,
          hubAddress: hubAddr,
          hubPort: hubPort,
          onHubState: _onHubState,
        );
        await t.start();
        if (gen != _gen) {
          await t.close();
          return;
        }
        _tunnel = t;
      } else {
        existing.update(
            mySlot: slot, token: token, hubAddress: hubAddr, hubPort: hubPort);
      }
      if (slotChanged) {
        for (final id in _links.keys.toList()) {
          _disposeLink(id);
        }
      }

      final seen = <String>{};
      final peers = m['peers'];
      if (peers is List) {
        for (final p in peers) {
          final id = _upsertPeer(p);
          if (id != null) seen.add(id);
        }
      }
      for (final id in _peers.keys.toList()) {
        if (!seen.contains(id)) _removePeer(id);
      }

      _everConnected = true;
      fullRoomNotice = null;
      if (role == Role.guest) prefs.lastHost = hostAddress;
      for (final l in _links.values) {
        l.canNegotiate = _peers[l.peerId]?.online ?? false;
        l.nudge();
      }
      _startStats();
      statusDetail = '';
      _setPhase(Phase.live);
      _updateNotification();
      _completeWelcome(true);
    } catch (e) {
      debugPrint('welcome: $e');
      _completeWelcome(false);
    }
  }

  void _onClosed(SignalingClient client, int gen) {
    if (gen != _gen || _leaving || !identical(client, _signaling)) return;
    _signaling = null;
    _completeWelcome(false);
    for (final l in _links.values) {
      l.canNegotiate = false;
    }
    if (_roomClosed) return;
    if (_everConnected) {
      statusDetail = 'A conexão com a sala caiu. Reconectando…';
      _setPhase(Phase.reconnecting);
    }
    _scheduleReconnect(gen);
  }

  void _scheduleReconnect(int gen) {
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(const Duration(milliseconds: 700), () {
      if (gen != _gen || _leaving || signalingUp || _roomClosed) return;
      if (role == Role.host) {
        unawaited(() async {
          final server = _server;
          if (server == null) return;
          final ok =
              await _connectSignaling('127.0.0.1', server.boundPort, gen);
          if (!ok && gen == _gen) _scheduleReconnect(gen);
        }());
      } else {
        unawaited(_searchLoop(gen));
      }
    });
  }

  void _onRoomClosed() {
    _roomClosed = true;
    final gen = _gen;
    unawaited(() async {
      await _teardown();
      if (gen != _gen) return;
      statusDetail = '';
      _setPhase(Phase.ended);
    }());
  }

  // ====================================================== participantes

  String? _upsertPeer(dynamic json, {bool announce = false}) {
    if (json is! Map) return null;
    final id = asString(json['id']);
    if (id == null || id == myId) return null;
    final slot = asInt(json['slot']) ?? 0;
    if (slot <= 0) return null;
    var p = _peers[id];
    final isNew = p == null;
    if (p == null) {
      p = Participant(
          id: id, name: asString(json['name']) ?? 'Viajante', slot: slot);
      _peers[id] = p;
    } else if (p.slot != slot) {
      _disposeLink(id);
      p.slot = slot;
    }
    p.name = asString(json['name']) ?? p.name;
    p.muted = asBool(json['muted'], p.muted);
    p.isHost = asBool(json['host'], p.isHost);
    final wasOnline = p.online;
    p.online = asBool(json['online'], true);

    final link = _ensureLink(p);
    if (link != null) {
      link.canNegotiate = p.online && signalingUp;
      if (p.online && !wasOnline && !isNew) link.nudge();
    }
    if (isNew && announce) {
      _toasts.add('${p.name} entrou na sala');
      unawaited(HapticFeedback.lightImpact());
    }
    _updateNotification();
    notifyListeners();
    return id;
  }

  void _removePeer(String? id, {bool announce = false}) {
    if (id == null) return;
    final p = _peers.remove(id);
    _disposeLink(id);
    if (p != null && announce) _toasts.add('${p.name} saiu da sala');
    _updateNotification();
    notifyListeners();
  }

  PeerLink? _ensureLink(Participant p) {
    final existing = _links[p.id];
    if (existing != null) return existing;
    final tunnel = _tunnel;
    if (tunnel == null) return null;
    final id = p.id;
    final link = PeerLink(
      peerId: id,
      slot: p.slot,
      isOfferer: myId.compareTo(id) > 0,
      engine: _audio,
      tunnel: tunnel,
      sendSignal: (data) =>
          _signaling?.send({'t': 'signal', 'to': id, 'data': data}),
      onChanged: () => _onLinkChanged(id),
    );
    link.volume = p.volume;
    _links[id] = link;
    link.start();
    return link;
  }

  void _disposeLink(String id) {
    final l = _links.remove(id);
    if (l != null) unawaited(l.dispose());
  }

  void _onLinkChanged(String id) {
    final link = _links[id];
    final p = _peers[id];
    if (link == null || p == null) return;
    p.link = link.status;
    final anyConnected = _links.values.any((l) => l.isConnected);
    if (anyConnected && !_anyLinkConnected) {
      // A saída de áudio começa agora: reaplica viva-voz/Bluetooth.
      unawaited(_audio.setSpeaker(speakerOn));
    }
    _anyLinkConnected = anyConnected;
    notifyListeners();
  }

  void _onHubState(bool alive) {
    hubAlive = alive;
    notifyListeners();
  }

  // ====================================================== estatísticas

  void _startStats() {
    _statsTimer ??= Timer.periodic(
        const Duration(milliseconds: 350), (_) => unawaited(_pollStats()));
  }

  Future<void> _pollStats() async {
    if (_polling) return;
    _polling = true;
    try {
      var local = 0.0;
      for (final entry in _links.entries.toList()) {
        final link = entry.value;
        await link.pollStats();
        final p = _peers[entry.key];
        if (p == null) continue;
        final target = p.muted ? 0.0 : link.level;
        p.level = target > p.level ? target : p.level * 0.55 + target * 0.45;
        p.rttMs = link.rttMs;
        p.lossPct = link.lossPct;
        p.link = link.status;
        if (link.localLevel > local) local = link.localLevel;
      }
      final target = muted ? 0.0 : local;
      myLevel = target > myLevel ? target : myLevel * 0.55 + target * 0.45;
      if (phase == Phase.live || phase == Phase.reconnecting) {
        notifyListeners();
      }
    } finally {
      _polling = false;
    }
  }

  // ============================================================ diversos

  Future<void> _refreshHostInfo() async {
    if (role != Role.host) return;
    final net = await NetInfo.read(native);
    final list = <NetIface>[...net.hotspot];
    final w = net.wifiIp;
    if (w != null && list.every((i) => i.ip != w)) {
      list.add(NetIface('wifi', w, net.prefix));
    }
    hostInterfaces = list;
    notifyListeners();
    await _primeLocalNetwork(list);
  }

  /// No iPhone, o aviso de "Rede Local" só aparece quando o app manda algo
  /// para a rede. Sem essa permissão ninguém consegue entrar na sala, então o
  /// host manda um pacote inofensivo assim que o hotspot aparece.
  Future<void> _primeLocalNetwork(List<NetIface> ifaces) async {
    if (!Platform.isIOS) return;
    final targets = <InternetAddress>[];
    for (final i in ifaces) {
      if (!_primed.add(i.ip)) continue;
      final p = i.ip.split('.');
      if (p.length != 4) continue;
      final last = int.tryParse(p[3]) ?? 0;
      targets.add(InternetAddress('${p[0]}.${p[1]}.${p[2]}.${last == 2 ? 3 : 2}'));
    }
    if (targets.isEmpty) return;
    await RoomFinder.probe(targets, wait: const Duration(milliseconds: 150));
  }

  void _updateNotification() {
    if (!isActive || phase == Phase.preparing || phase == Phase.error) return;
    final n = peopleCount;
    final title = roomName.isEmpty ? 'Comboio' : roomName;
    final who = n == 1 ? 'Só você na sala' : '$n pessoas na sala';
    final mic = muted ? 'microfone mudo' : 'microfone ligado';
    unawaited(native.updateService(title: title, text: '$who • $mic', muted: muted));
  }

  void _onNotificationAction(String action) {
    switch (action) {
      case 'toggleMute':
        unawaited(toggleMute());
      case 'leave':
        unawaited(leave());
    }
  }

  void _setPhase(Phase p) {
    phase = p;
    notifyListeners();
  }

  void _fail(String title, String message, {bool needsSettings = false}) {
    errorTitle = title;
    errorMessage = message;
    errorNeedsSettings = needsSettings;
    _setPhase(Phase.error);
  }

  Future<void> _teardown() async {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _statsTimer?.cancel();
    _statsTimer = null;
    _hostInfoTimer?.cancel();
    _hostInfoTimer = null;
    _completeWelcome(false);

    final server = _server;
    _server = null;
    if (server != null) await server.stop();

    final sig = _signaling;
    _signaling = null;
    if (sig != null) {
      sig.onClosed = null;
      sig.onMessage = null;
      await sig.close();
    }

    final links = _links.values.toList();
    _links.clear();
    for (final l in links) {
      await l.dispose();
    }
    _peers.clear();

    final tunnel = _tunnel;
    _tunnel = null;
    await tunnel?.close();
    final hub = _hub;
    _hub = null;
    await hub?.stop();

    await _audio.stop();
    await native.stopService();
    await native.unbindNetwork();
    await native.setKeepScreenOn(false);

    _everConnected = false;
    _anyLinkConnected = false;
    mySlot = 0;
    myLevel = 0;
    hostAddress = null;
    _manualHost = null;
    _netHandle = 0;
    _primed.clear();
    searchStartedAt = null;
  }
}
