import 'dart:convert';
import 'dart:io';

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
