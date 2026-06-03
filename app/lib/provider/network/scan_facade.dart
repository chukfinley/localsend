import 'dart:async';

import 'package:localsend_app/provider/favorites_provider.dart';
import 'package:localsend_app/provider/network/nearby_devices_provider.dart';
import 'package:localsend_app/provider/network/tailscale_provider.dart';
import 'package:localsend_app/provider/settings_provider.dart';
import 'package:refena_flutter/refena_flutter.dart';

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
    final tailscaleStatus = await ref.read(tailscaleProvider).getStatus();
    if (tailscaleStatus.active) {
      unawaited(ref.redux(nearbyDevicesProvider).dispatchAsync(StartTailscaleScan(
        nodes: tailscaleStatus.onlinePeers,
        port: ref.read(settingsProvider).port,
        https: https,
      )));
    }
  }
}
