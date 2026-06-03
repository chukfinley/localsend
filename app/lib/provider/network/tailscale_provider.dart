import 'dart:convert';
import 'dart:io';

import 'package:common/api_route_builder.dart';
import 'package:common/constants.dart';
import 'package:logging/logging.dart';
import 'package:refena_flutter/refena_flutter.dart';

final _logger = Logger('Tailscale');

/// A single node in the Tailscale tailnet (self or a peer).
class TailscaleNode {
  /// The Tailscale CGNAT IPv4 address (100.64.0.0/10).
  final String ip;

  /// The full MagicDNS name without the trailing dot, e.g.
  /// `thinkpad.huchen-hake.ts.net`.
  final String dnsName;

  /// The short device name, e.g. `thinkpad`.
  final String hostName;

  final bool online;

  const TailscaleNode({
    required this.ip,
    required this.dnsName,
    required this.hostName,
    required this.online,
  });
}

/// Result of querying the local Tailscale daemon.
class TailscaleStatus {
  /// This device's own node, or null if Tailscale is not running / not reachable.
  final TailscaleNode? self;

  /// All peer nodes that have a Tailscale IPv4 address.
  final List<TailscaleNode> peers;

  const TailscaleStatus({required this.self, required this.peers});

  static const inactive = TailscaleStatus(self: null, peers: []);

  /// True if Tailscale is running and this device is part of a tailnet.
  bool get active => self != null;

  /// Online peers only.
  List<TailscaleNode> get onlinePeers => peers.where((p) => p.online).toList();
}

final tailscaleProvider = Provider((ref) => TailscaleService());

/// This device's own Tailscale MagicDNS name (e.g. `thinkpad.tailnet.ts.net`),
/// or null if Tailscale is not active / not reachable. Cached after first read.
final ownTailscaleNameProvider = FutureProvider<String?>((ref) async {
  final status = await ref.read(tailscaleProvider).getStatus();
  return status.self?.dnsName;
});

/// Reads the local Tailscale state via the `tailscale status --json` CLI.
///
/// This only works on desktop platforms where the CLI is reachable. On mobile
/// the CLI is sandboxed inside the Tailscale app, so [getStatus] returns
/// [TailscaleStatus.inactive] there. Mobile devices instead rely on favorites
/// (which can hold MagicDNS names) and on a desktop peer sharing its map.
class TailscaleService {
  /// True only on platforms where shelling out to the CLI makes sense.
  bool get _cliAvailable => Platform.isLinux || Platform.isMacOS || Platform.isWindows;

  Future<TailscaleStatus> getStatus() async {
    if (!_cliAvailable) {
      return TailscaleStatus.inactive;
    }

    final json = await _runStatusJson();
    if (json == null) {
      return TailscaleStatus.inactive;
    }

    try {
      final self = _parseNode(json['Self']);
      final peersRaw = (json['Peer'] as Map<String, dynamic>?) ?? const {};
      final peers = <TailscaleNode>[];
      for (final entry in peersRaw.values) {
        final node = _parseNode(entry);
        if (node != null) {
          peers.add(node);
        }
      }
      return TailscaleStatus(self: self, peers: peers);
    } catch (e) {
      _logger.warning('Failed to parse tailscale status: $e');
      return TailscaleStatus.inactive;
    }
  }

  /// Fetches another device's tailnet view from its `/tailscale` endpoint.
  ///
  /// This is how a device without CLI access (mobile) learns the tailnet: it
  /// asks a desktop "oracle" peer for its peer map. Returns [TailscaleStatus.inactive]
  /// on any failure.
  Future<TailscaleStatus> fetchFromPeer({
    required String ip,
    required int port,
    required bool https,
  }) async {
    HttpClient? client;
    try {
      final url = ApiRoute.tailscale.targetRaw(ip, port, https, peerProtocolVersion);
      client = HttpClient()..badCertificateCallback = (_, __, ___) => true;
      final request = await client.getUrl(Uri.parse(url)).timeout(const Duration(seconds: 4));
      final response = await request.close().timeout(const Duration(seconds: 4));
      if (response.statusCode != 200) {
        return TailscaleStatus.inactive;
      }
      final body = await response.transform(utf8.decoder).join();
      final json = jsonDecode(body) as Map<String, dynamic>;
      final self = _parseFlatNode(json['self']);
      final peers = ((json['peers'] as List?) ?? const [])
          .map(_parseFlatNode)
          .whereType<TailscaleNode>()
          .toList();
      return TailscaleStatus(self: self, peers: peers);
    } catch (e) {
      _logger.info('Failed to fetch tailscale map from $ip:$port: $e');
      return TailscaleStatus.inactive;
    } finally {
      client?.close();
    }
  }

  /// Parses a node from the flat JSON shape returned by the `/tailscale` endpoint
  /// (`{ip, dnsName, hostName, online}`), as opposed to the raw `tailscale status` shape.
  TailscaleNode? _parseFlatNode(Object? raw) {
    if (raw is! Map) {
      return null;
    }
    final ip = raw['ip'] as String? ?? '';
    if (ip.isEmpty) {
      return null;
    }
    return TailscaleNode(
      ip: ip,
      dnsName: raw['dnsName'] as String? ?? '',
      hostName: raw['hostName'] as String? ?? '',
      online: raw['online'] as bool? ?? false,
    );
  }

  /// Reverse path: try every known binary location until one answers.
  Future<Map<String, dynamic>?> _runStatusJson() async {
    for (final bin in _binaryCandidates()) {
      try {
        final result = await Process.run(bin, ['status', '--json', '--peers']);
        if (result.exitCode == 0 && (result.stdout as String).trim().isNotEmpty) {
          return jsonDecode(result.stdout as String) as Map<String, dynamic>;
        }
      } catch (_) {
        // binary not found at this location, try the next
      }
    }
    _logger.info('Tailscale CLI not found or not running.');
    return null;
  }

  List<String> _binaryCandidates() {
    if (Platform.isMacOS) {
      return [
        'tailscale',
        '/usr/local/bin/tailscale',
        '/opt/homebrew/bin/tailscale',
        '/Applications/Tailscale.app/Contents/MacOS/Tailscale',
      ];
    }
    if (Platform.isWindows) {
      return [
        'tailscale',
        r'C:\Program Files\Tailscale\tailscale.exe',
        r'C:\Program Files (x86)\Tailscale\tailscale.exe',
      ];
    }
    return [
      'tailscale',
      '/usr/bin/tailscale',
      '/usr/local/bin/tailscale',
    ];
  }

  /// Parses one node object, returning null if it has no Tailscale IPv4.
  TailscaleNode? _parseNode(Object? raw) {
    if (raw is! Map<String, dynamic>) {
      return null;
    }
    // Skip exit nodes (e.g. Mullvad infrastructure) — they are never LocalSend
    // devices and would massively inflate the probe set.
    if (raw['ExitNodeOption'] == true) {
      return null;
    }

    final ips = (raw['TailscaleIPs'] as List?)?.cast<String>() ?? const [];
    final ip = ips.firstWhere(_isTailscaleIpv4, orElse: () => '');
    if (ip.isEmpty) {
      return null;
    }
    final dnsName = (raw['DNSName'] as String? ?? '').replaceAll(RegExp(r'\.$'), '');
    final hostName = raw['HostName'] as String? ?? (dnsName.contains('.') ? dnsName.split('.').first : dnsName);
    return TailscaleNode(
      ip: ip,
      dnsName: dnsName,
      hostName: hostName,
      online: raw['Online'] as bool? ?? false,
    );
  }

  /// CGNAT 100.64.0.0/10 is the Tailscale range.
  static bool _isTailscaleIpv4(String ip) {
    final parts = ip.split('.');
    if (parts.length != 4) return false;
    final a = int.tryParse(parts[0]);
    final b = int.tryParse(parts[1]);
    return a == 100 && b != null && b >= 64 && b <= 127;
  }
}
