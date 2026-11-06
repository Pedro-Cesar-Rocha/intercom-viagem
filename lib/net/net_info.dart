import 'dart:io';
import 'dart:typed_data';

import 'package:network_info_plus/network_info_plus.dart';

import '../core/native_bridge.dart';

class NetIface {
  const NetIface(this.name, this.ip, [this.prefix = 24]);

  final String name;
  final String ip;
  final int prefix;
}

/// Retrato da rede local deste celular.
class LocalNet {
  const LocalNet({
    this.wifiIp,
    this.prefix = 24,
    this.gateway,
    this.dhcp,
    this.hotspot = const [],
    this.handle = 0,
    this.bound = false,
  });

  /// IP deste celular no Wi-Fi (como cliente). Null se não está em Wi-Fi.
  final String? wifiIp;
  final int prefix;
  final String? gateway;
  final String? dhcp;

  /// Interfaces que parecem ser um hotspot servido por este celular.
  final List<NetIface> hotspot;

  /// Identificador da rede Wi-Fi no Android (muda quando reconecta).
  final int handle;
  final bool bound;

  bool get hasWifi => wifiIp != null;

  /// Endereços para tentar primeiro (último host, gateway, DHCP, .1).
  List<InternetAddress> priorityTargets(String? lastHost) {
    final out = <String>[];
    void add(String? ip) {
      if (ip == null || ip.isEmpty || ip == wifiIp || out.contains(ip)) return;
      final parsed = InternetAddress.tryParse(ip);
      if (parsed == null || parsed.type != InternetAddressType.IPv4) return;
      if (parsed.isLoopback) return;
      out.add(ip);
    }

    add(lastHost);
    add(gateway);
    add(dhcp);
    final ip = wifiIp;
    if (ip != null) {
      final parts = ip.split('.');
      if (parts.length == 4) add('${parts[0]}.${parts[1]}.${parts[2]}.1');
    }
    return [for (final s in out) InternetAddress(s)];
  }

  /// Todos os endereços da sub-rede (limitada a /24) para a varredura.
  List<InternetAddress> subnetTargets() {
    final ip = InternetAddress.tryParse(wifiIp ?? '');
    if (ip == null || ip.type != InternetAddressType.IPv4) return const [];
    final raw = ip.rawAddress;
    final value = (raw[0] << 24) | (raw[1] << 16) | (raw[2] << 8) | raw[3];
    var p = prefix;
    if (p < 24) p = 24;
    if (p > 30) p = 30;
    final mask = (0xffffffff << (32 - p)) & 0xffffffff;
    final net = value & mask;
    final count = 1 << (32 - p);
    final out = <InternetAddress>[];
    for (var i = 1; i < count - 1; i++) {
      final a = net + i;
      if (a == value) continue;
      out.add(InternetAddress.fromRawAddress(Uint8List.fromList(
          [(a >> 24) & 255, (a >> 16) & 255, (a >> 8) & 255, a & 255])));
    }
    return out;
  }
}

class NetInfo {
  /// Lê a rede atual. No Android, [bind] prende o processo ao Wi-Fi.
  static Future<LocalNet> read(NativeBridge native, {bool bind = false}) async {
    if (Platform.isAndroid) {
      final m = bind ? await native.bindToWifi() : await native.networkInfo();
      if (m != null) return _fromAndroid(m);
      final ifs = await interfaceScan();
      return LocalNet(hotspot: ifs);
    }
    if (Platform.isIOS) {
      final info = NetworkInfo();
      String? ip;
      String? mask;
      String? gw;
      try {
        ip = await info.getWifiIP();
      } catch (_) {}
      try {
        mask = await info.getWifiSubmask();
      } catch (_) {}
      try {
        gw = await info.getWifiGatewayIP();
      } catch (_) {}
      final wifi = _validIp(ip);
      final hotspot = await interfaceScan(exclude: wifi);
      return LocalNet(
        wifiIp: wifi,
        prefix: _prefixFromMask(mask) ?? 24,
        gateway: _validIp(gw),
        hotspot: hotspot,
      );
    }
    // Desktop / testes.
    final ifs = await interfaceScan();
    return LocalNet(wifiIp: ifs.isEmpty ? null : ifs.first.ip);
  }

  static LocalNet _fromAndroid(Map<String, dynamic> m) {
    final wifi = m['wifi'];
    final hotspotRaw = m['hotspot'];
    final hotspot = <NetIface>[];
    if (hotspotRaw is List) {
      for (final h in hotspotRaw) {
        if (h is Map) {
          final ip = _validIp(h['ip']?.toString());
          if (ip == null) continue;
          hotspot.add(NetIface(h['iface']?.toString() ?? '?', ip,
              (h['prefix'] is int) ? h['prefix'] as int : 24));
        }
      }
    }
    if (wifi is Map) {
      return LocalNet(
        wifiIp: _validIp(wifi['ip']?.toString()),
        prefix: (wifi['prefix'] is int) ? wifi['prefix'] as int : 24,
        gateway: _validIp(wifi['gateway']?.toString()),
        dhcp: _validIp(wifi['dhcp']?.toString()),
        handle: (wifi['handle'] is int) ? wifi['handle'] as int : 0,
        hotspot: hotspot,
        bound: m['bound'] == true,
      );
    }
    return LocalNet(hotspot: hotspot, bound: m['bound'] == true);
  }

  /// Interfaces IPv4 privadas que não são de dados móveis/VPN.
  static Future<List<NetIface>> interfaceScan({String? exclude}) async {
    try {
      final list = await NetworkInterface.list(
          includeLoopback: false, type: InternetAddressType.IPv4);
      final out = <NetIface>[];
      for (final ni in list) {
        if (_isCellularOrVirtual(ni.name)) continue;
        for (final a in ni.addresses) {
          if (a.address == exclude) continue;
          if (!isPrivateIPv4(a.address)) continue;
          out.add(NetIface(ni.name, a.address));
        }
      }
      return out;
    } catch (_) {
      return const [];
    }
  }

  static bool _isCellularOrVirtual(String name) {
    const prefixes = [
      'rmnet', 'ccmni', 'clat', 'v4-', 'pdp_ip', 'utun', 'ipsec', 'tun',
      'ppp', 'dummy', 'lo', 'ip6tnl', 'radio', 'seth', 'awdl', 'llw',
      'anpi', 'gif', 'stf', 'p2p',
    ];
    return prefixes.any(name.startsWith);
  }

  static bool isPrivateIPv4(String ip) {
    final p = ip.split('.');
    if (p.length != 4) return false;
    final a = int.tryParse(p[0]) ?? -1;
    final b = int.tryParse(p[1]) ?? -1;
    if (a == 10) return true;
    if (a == 192 && b == 168) return true;
    if (a == 172 && b >= 16 && b <= 31) return true;
    return false;
  }

  static String? _validIp(String? ip) {
    if (ip == null) return null;
    final v = ip.trim();
    final parsed = InternetAddress.tryParse(v);
    if (parsed == null || parsed.type != InternetAddressType.IPv4) return null;
    if (v == '0.0.0.0' || parsed.isLoopback) return null;
    return v;
  }

  static int? _prefixFromMask(String? mask) {
    if (mask == null) return null;
    final parts = mask.split('.');
    if (parts.length != 4) return null;
    var bits = 0;
    for (final s in parts) {
      var v = int.tryParse(s) ?? 0;
      while (v > 0) {
        bits += v & 1;
        v >>= 1;
      }
    }
    return bits == 0 ? null : bits;
  }
}
