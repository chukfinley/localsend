import 'dart:async';

import 'package:localsend_app/provider/favorites_provider.dart';
import 'package:localsend_app/provider/network/nearby_devices_provider.dart';
import 'package:localsend_app/provider/network/tailscale_provider.dart';
import 'package:localsend_app/provider/settings_provider.dart';
import 'package:logging/logging.dart';
import 'package:refena_flutter/refena_flutter.dart';

final _logger = Logger('SmartScan');

/// Pure Tailscale discovery.
///
/// LocalSend is now Tailscale-only: the tailnet is the only relevant network,
/// so there is no multicast/UDP announcement and no LAN subnet scanning. We
/// probe the known favorites and every online tailnet peer; whatever runs
/// LocalSend answers and shows up (and auto-saves as a favorite).
class StartSmartScan extends AsyncGlobalAction {
  StartSmartScan();

  @override
  Future<void> reduce() async {
    final https = ref.read(settingsProvider).https;

    // Probe known favorites (reachable via their stored Tailscale/LAN addresses).
    final favorites = ref.read(favoritesProvider);
    unawaited(ref.redux(nearbyDevicesProvider).dispatchAsync(StartFavoriteScan(devices: favorites, https: https)));

    // Discover LocalSend instances among the Tailscale tailnet peers.
    final port = ref.read(settingsProvider).port;
    final tailscale = ref.read(tailscaleProvider);
    final localStatus = await tailscale.getStatus();
    _logger.info('[TS-DEBUG] getStatus active=${localStatus.active} self=${localStatus.self?.dnsName} onlinePeers=${localStatus.onlinePeers.length} port=$port https=$https');
    if (localStatus.active) {
      _logger.info('[TS-DEBUG] dispatching StartTailscaleScan with ${localStatus.onlinePeers.length} peers: ${localStatus.onlinePeers.map((p) => '${p.hostName}@${p.ip}').take(20).join(', ')}');
      // Desktop: we have CLI access to the full tailnet.
      unawaited(ref.redux(nearbyDevicesProvider).dispatchAsync(StartTailscaleScan(
        nodes: localStatus.onlinePeers,
        port: port,
        https: https,
      )));
    } else {
      // No CLI access (mobile): ask a favorite "oracle" peer for its tailnet map.
      for (final favorite in favorites) {
        final remote = await tailscale.fetchFromPeer(ip: favorite.ip, port: favorite.port, https: https);
        if (remote.onlinePeers.isNotEmpty) {
          unawaited(ref.redux(nearbyDevicesProvider).dispatchAsync(StartTailscaleScan(
            nodes: remote.onlinePeers,
            port: port,
            https: https,
          )));
          break;
        }
      }
    }
  }
}
