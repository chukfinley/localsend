import 'dart:async';

import 'package:collection/collection.dart';
import 'package:common/isolate.dart';
import 'package:common/model/device.dart';
import 'package:localsend_app/model/persistence/favorite_device.dart';
import 'package:localsend_app/model/state/nearby_devices_state.dart';
import 'package:localsend_app/provider/favorites_provider.dart';
import 'package:localsend_app/provider/logging/discovery_logs_provider.dart';
import 'package:localsend_app/provider/network/tailscale_provider.dart';
import 'package:localsend_app/provider/security_provider.dart';
import 'package:logging/logging.dart';
import 'package:refena_flutter/refena_flutter.dart';

final _tsLogger = Logger('TailscaleScan');

/// This provider is responsible for:
/// - Scanning the network for other LocalSend instances
/// - Keeping track of all found devices (they are only stored in RAM)
///
/// Use [scanProvider] to have a high-level API to perform discovery operations.
final nearbyDevicesProvider = ReduxProvider<NearbyDevicesService, NearbyDevicesState>((ref) {
  return NearbyDevicesService(
    isolateController: ref.notifier(parentIsolateProvider),
    favoriteService: ref.notifier(favoritesProvider),
    discoveryLogs: ref.notifier(discoveryLoggerProvider),
    ownFingerprint: ref.read(securityProvider).certificateHash,
  );
});

class NearbyDevicesService extends ReduxNotifier<NearbyDevicesState> {
  final IsolateController _isolateController;
  final FavoritesService _favoriteService;
  final DiscoveryLogger _discoveryLogger;
  final String _ownFingerprint;

  NearbyDevicesService({
    required IsolateController isolateController,
    required FavoritesService favoriteService,
    required DiscoveryLogger discoveryLogs,
    required String ownFingerprint,
  }) : _discoveryLogger = discoveryLogs,
       _isolateController = isolateController,
       _favoriteService = favoriteService,
       _ownFingerprint = ownFingerprint;

  @override
  NearbyDevicesState init() => const NearbyDevicesState(
    runningFavoriteScan: false,
    runningIps: {},
    devices: {},
    signalingDevices: {},
  );
}

/// Binds the UDP port and listens for incoming announcements.
/// This should run forever as long as the app is running.
class StartMulticastListener extends AsyncReduxAction<NearbyDevicesService, NearbyDevicesState> {
  @override
  Future<NearbyDevicesState> reduce() async {
    await for (final device in notifier._isolateController.state.multicastDiscovery!.receiveFromIsolate) {
      await dispatchAsync(RegisterDeviceAction(device));
      notifier._discoveryLogger.addLog('[DISCOVER/UDP] ${device.alias} (${device.ip}, model: ${device.deviceModel})');
    }
    return state;
  }
}

/// Removes all found devices from the state.
class ClearFoundDevicesAction extends ReduxAction<NearbyDevicesService, NearbyDevicesState> {
  @override
  NearbyDevicesState reduce() {
    return state.copyWith(
      devices: {},
    );
  }
}

/// Registers a device in the state.
/// It will override any existing device with the same IP.
class RegisterDeviceAction extends AsyncReduxAction<NearbyDevicesService, NearbyDevicesState> {
  final Device device;

  RegisterDeviceAction(this.device);

  @override
  bool get trackOrigin => false;

  @override
  Future<NearbyDevicesState> reduce() async {
    assert(device.ip?.isNotEmpty ?? false, 'IP must not be empty');

    // Never list ourselves (e.g. when discovered via a leftover announcement).
    if (device.fingerprint == notifier._ownFingerprint) {
      return state;
    }

    final favoriteDevice = notifier._favoriteService.state.firstWhereOrNull((e) => e.fingerprint == device.fingerprint);
    if (favoriteDevice != null && !favoriteDevice.customAlias) {
      // Update existing favorite with new alias
      await external(notifier._favoriteService).dispatchAsync(UpdateFavoriteAction(favoriteDevice.copyWith(alias: device.alias)));
    } else {
      await Future.microtask(() {});
    }
    return state.copyWith(
      devices: {...state.devices}..update(device.ip!, (_) => device, ifAbsent: () => device),
    );
  }
}

/// Registers a new device found via signaling.
class RegisterSignalingDeviceAction extends ReduxAction<NearbyDevicesService, NearbyDevicesState> {
  final Device device;

  RegisterSignalingDeviceAction(this.device);

  @override
  NearbyDevicesState reduce() {
    final Set<Device> existingDevices = state.signalingDevices[device.fingerprint]?.toSet() ?? {};
    final existingDevice = existingDevices.firstWhereOrNull((e) => e.signalingId == device.signalingId);
    if (existingDevice != null) {
      existingDevices.remove(existingDevice);
    }
    existingDevices.add(device);

    return state.copyWith(
      signalingDevices: {
        ...state.signalingDevices,
        device.fingerprint: existingDevices,
      },
    );
  }
}

class UnregisterSignalingDeviceAction extends ReduxAction<NearbyDevicesService, NearbyDevicesState> {
  final String signalingId;

  UnregisterSignalingDeviceAction(this.signalingId);

  @override
  NearbyDevicesState reduce() {
    return state.copyWith(
      signalingDevices: {
        for (final entry in state.signalingDevices.entries) entry.key: entry.value.where((e) => e.signalingId != signalingId).toSet(),
      },
    );
  }
}

/// It does not really "scan".
/// It just sends an announcement which will cause a response on every other LocalSend member of the network.
class StartMulticastScan extends ReduxAction<NearbyDevicesService, NearbyDevicesState> {
  @override
  NearbyDevicesState reduce() {
    external(notifier._isolateController).dispatch(IsolateSendMulticastAnnouncementAction());
    return state;
  }
}

/// Scans one particular subnet with traditional HTTP/TCP discovery.
/// This method awaits until the scan is finished.
class StartLegacyScan extends AsyncReduxAction<NearbyDevicesService, NearbyDevicesState> {
  final int port;
  final String localIp;
  final bool https;

  StartLegacyScan({
    required this.port,
    required this.localIp,
    required this.https,
  });

  @override
  Future<NearbyDevicesState> reduce() async {
    if (state.runningIps.contains(localIp)) {
      // already running for the same localIp
      await Future.microtask(() {});
      return state;
    }

    dispatch(_SetRunningIpsAction({...state.runningIps, localIp}));

    final stream = external(notifier._isolateController).dispatchTakeResult(
      IsolateInterfaceHttpDiscoveryAction(
        networkInterface: localIp,
        port: port,
        https: https,
      ),
    );

    await for (final device in stream) {
      notifier._discoveryLogger.addLog('[DISCOVER/TCP] ${device.alias} (${device.ip}, model: ${device.deviceModel})');
      await dispatchAsync(RegisterDeviceAction(device));
    }

    return state.copyWith(
      runningIps: state.runningIps.where((ip) => ip != localIp).toSet(),
    );
  }
}

class StartFavoriteScan extends AsyncReduxAction<NearbyDevicesService, NearbyDevicesState> {
  final List<FavoriteDevice> devices;
  final bool https;

  StartFavoriteScan({
    required this.devices,
    required this.https,
  });

  @override
  Future<NearbyDevicesState> reduce() async {
    if (devices.isEmpty) {
      return state;
    }
    dispatch(_SetRunningFavoriteScanAction(true));

    final stream = external(notifier._isolateController).dispatchTakeResult(
      IsolateFavoriteHttpDiscoveryAction(
        // Probe every known address of each favorite (LAN IP, Tailscale 100.x,
        // MagicDNS name, ...). Results are deduplicated by fingerprint.
        favorites: devices.expand((e) => e.allAddresses.map((a) => (a, e.port))).toList(),
        https: https,
      ),
    );

    await for (final device in stream) {
      notifier._discoveryLogger.addLog('[DISCOVER/TCP] ${device.alias} (${device.ip}, model: ${device.deviceModel})');
      await dispatchAsync(RegisterDeviceAction(device));
    }

    return state.copyWith(
      runningFavoriteScan: false,
    );
  }
}

/// Discovers LocalSend instances among the Tailscale tailnet peers.
///
/// Every online peer is probed over its Tailscale IP. Peers that answer are
/// registered as nearby devices and additionally saved as favorites, keyed by
/// their stable fingerprint, with both the MagicDNS name and the Tailscale IP
/// recorded as known addresses. This realizes device-based discovery: open the
/// app and every tailnet device running LocalSend shows up automatically.
class StartTailscaleScan extends AsyncReduxAction<NearbyDevicesService, NearbyDevicesState> {
  final List<TailscaleNode> nodes;
  final int port;
  final bool https;

  StartTailscaleScan({
    required this.nodes,
    required this.port,
    required this.https,
  });

  @override
  Future<NearbyDevicesState> reduce() async {
    _tsLogger.info('[TS-DEBUG] StartTailscaleScan reduce: ${nodes.length} nodes, port=$port https=$https');
    if (nodes.isEmpty) {
      return state;
    }

    final nodeByIp = {for (final n in nodes) n.ip: n};

    final stream = external(notifier._isolateController).dispatchTakeResult(
      IsolateFavoriteHttpDiscoveryAction(
        favorites: nodes.map((n) => (n.ip, port)).toList(),
        https: https,
      ),
    );

    var found = 0;
    await for (final device in stream) {
      found++;
      _tsLogger.info('[TS-DEBUG] found device ${device.alias} @ ${device.ip}:${device.port}');
      final node = nodeByIp[device.ip];
      notifier._discoveryLogger.addLog('[DISCOVER/TS] ${node?.dnsName ?? device.alias} (${device.ip})');
      await dispatchAsync(RegisterDeviceAction(device));
      if (node != null) {
        await dispatchAsync(_UpsertTailscaleFavoriteAction(device: device, node: node));
      }
    }

    _tsLogger.info('[TS-DEBUG] StartTailscaleScan done: probed ${nodes.length} peers, found $found LocalSend devices');
    return state;
  }
}

/// Creates or updates the favorite for a Tailscale-discovered device, making
/// sure its MagicDNS name and Tailscale IP are both stored as known addresses.
class _UpsertTailscaleFavoriteAction extends AsyncReduxAction<NearbyDevicesService, NearbyDevicesState> {
  final Device device;
  final TailscaleNode node;

  _UpsertTailscaleFavoriteAction({required this.device, required this.node});

  @override
  bool get trackOrigin => false;

  @override
  Future<NearbyDevicesState> reduce() async {
    final existing = notifier._favoriteService.state.firstWhereOrNull((e) => e.fingerprint == device.fingerprint);

    if (existing == null) {
      await external(notifier._favoriteService).dispatchAsync(
        AddFavoriteAction(
          FavoriteDevice.fromValues(
            fingerprint: device.fingerprint,
            ip: node.dnsName.isNotEmpty ? node.dnsName : device.ip!,
            port: device.port,
            alias: node.hostName.isNotEmpty ? node.hostName : device.alias,
            addresses: [
              if (node.dnsName.isNotEmpty) device.ip!,
            ],
          ),
        ),
      );
      return state;
    }

    // Merge the MagicDNS name and Tailscale IP into the known addresses.
    final known = existing.allAddresses.toSet();
    final merged = {
      ...known,
      if (node.dnsName.isNotEmpty) node.dnsName,
      if (device.ip != null) device.ip!,
    };
    if (merged.length != known.length) {
      final all = merged.toList();
      await external(notifier._favoriteService).dispatchAsync(
        UpdateFavoriteAction(existing.copyWith(
          ip: all.first,
          addresses: all.skip(1).toList(),
        )),
      );
    }

    return state;
  }
}

class _SetRunningIpsAction extends ReduxAction<NearbyDevicesService, NearbyDevicesState> {
  final Set<String> runningIps;

  _SetRunningIpsAction(this.runningIps);

  @override
  NearbyDevicesState reduce() {
    return state.copyWith(
      runningIps: runningIps,
    );
  }
}

class _SetRunningFavoriteScanAction extends ReduxAction<NearbyDevicesService, NearbyDevicesState> {
  final bool running;

  _SetRunningFavoriteScanAction(this.running);

  @override
  NearbyDevicesState reduce() {
    return state.copyWith(
      runningFavoriteScan: running,
    );
  }
}
