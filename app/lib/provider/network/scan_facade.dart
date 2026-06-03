import 'dart:async';

import 'package:common/model/device.dart';
import 'package:localsend_app/provider/device_info_provider.dart';
import 'package:localsend_app/provider/favorites_provider.dart';
import 'package:localsend_app/provider/http_provider.dart';
import 'package:localsend_app/provider/network/nearby_devices_provider.dart';
import 'package:localsend_app/provider/network/tailscale_provider.dart';
import 'package:localsend_app/provider/settings_provider.dart';
import 'package:localsend_app/rust/api/model.dart';
import 'package:localsend_app/util/rust.dart';
import 'package:logging/logging.dart';
import 'package:refena_flutter/refena_flutter.dart';

final _logger = Logger('SmartScan');

/// Pure Tailscale discovery.
///
/// LocalSend is Tailscale-only: the tailnet is the only relevant network. We
/// enumerate the online tailnet peers and actively *register* with each one
/// (mutual handshake) — so the peer learns about us and we learn about it. This
/// makes discovery symmetric even for devices that cannot enumerate the tailnet
/// themselves (mobile, no CLI): being registered-to is enough to be discovered.
class StartSmartScan extends AsyncGlobalAction {
  StartSmartScan();

  @override
  Future<void> reduce() async {
    final settings = ref.read(settingsProvider);
    final https = settings.https;
    final port = settings.port;

    // Probe known favorites (reachable via their stored Tailscale addresses).
    final favorites = ref.read(favoritesProvider);
    unawaited(ref.redux(nearbyDevicesProvider).dispatchAsync(StartFavoriteScan(devices: favorites, https: https)));

    final tailscale = ref.read(tailscaleProvider);
    final localStatus = await tailscale.getStatus();
    _logger.info('Tailscale active=${localStatus.active} onlinePeers=${localStatus.onlinePeers.length}');

    if (localStatus.active) {
      // Desktop: we have CLI access to the full tailnet.
      await dispatchAsync(RegisterWithTailscalePeers(nodes: localStatus.onlinePeers, port: port, https: https));
    } else {
      // No CLI access (mobile): ask a favorite "oracle" peer for its tailnet map,
      // then register with everyone it reports.
      for (final favorite in favorites) {
        final remote = await tailscale.fetchFromPeer(ip: favorite.ip, port: favorite.port, https: https);
        if (remote.onlinePeers.isNotEmpty) {
          await dispatchAsync(RegisterWithTailscalePeers(nodes: remote.onlinePeers, port: port, https: https));
          break;
        }
      }
    }
  }
}

/// Registers (mutual handshake) with every given Tailscale peer in parallel.
///
/// POSTing `/register` makes the peer add us to its device list *and* returns the
/// peer's info, which we add to ours. This is what lets both sides see each other.
class RegisterWithTailscalePeers extends AsyncGlobalAction {
  final List<TailscaleNode> nodes;
  final int port;
  final bool https;

  RegisterWithTailscalePeers({
    required this.nodes,
    required this.port,
    required this.https,
  });

  @override
  Future<void> reduce() async {
    if (nodes.isEmpty) {
      return;
    }

    final payload = ref.read(deviceFullInfoProvider).toRegisterDto();
    final protocol = https ? ProtocolType.https : ProtocolType.http;
    final client = ref.read(httpProvider).v2;

    await Future.wait(nodes.map((node) async {
      try {
        final response = await client.register(
          protocol: protocol,
          ip: node.ip,
          port: port,
          payload: payload,
        );
        final device = response.body.toDevice(node.ip, port, https, HttpDiscovery(ip: node.ip));
        await ref.redux(nearbyDevicesProvider).dispatchAsync(RegisterDeviceAction(device));
        await ref.redux(nearbyDevicesProvider).dispatchAsync(UpsertTailscaleFavoriteAction(device: device, node: node));
      } catch (_) {
        // peer not reachable or not running LocalSend — skip
      }
    }));
  }
}
