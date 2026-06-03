import 'package:dart_mappable/dart_mappable.dart';
import 'package:uuid/uuid.dart';

part 'favorite_device.mapper.dart';

const _uuid = Uuid();

@MappableClass()
class FavoriteDevice with FavoriteDeviceMappable {
  final String id;
  final String fingerprint;

  /// The primary / last-known-good address (IP or Tailscale MagicDNS name).
  /// Kept for backward compatibility and as the default display address.
  final String ip;
  final int port;
  final String alias;

  /// If true, the alias was set by the user.
  /// If false, the alias is derived from the original device alias and
  /// should be updated when the original device alias changes.
  final bool customAlias;

  /// All known addresses of this device (IPs and/or Tailscale MagicDNS names).
  /// A device has a stable identity ([fingerprint]) but may be reachable under
  /// multiple addresses depending on the network (LAN IP, Tailscale 100.x,
  /// MagicDNS name, hotspot IP, ...). When sending, every address is probed in
  /// parallel and the first reachable one wins. New addresses are learned
  /// automatically on each successful connection.
  final List<String> addresses;

  const FavoriteDevice({
    required this.id,
    required this.fingerprint,
    required this.ip,
    required this.port,
    required this.alias,
    this.customAlias = false,
    this.addresses = const [],
  });

  factory FavoriteDevice.fromValues({
    required String fingerprint,
    required String ip,
    required int port,
    required String alias,
    List<String> addresses = const [],
  }) {
    return FavoriteDevice(
      id: _uuid.v1(),
      fingerprint: fingerprint,
      ip: ip,
      port: port,
      alias: alias,
      customAlias: false,
      addresses: addresses,
    );
  }

  /// The deduplicated set of all addresses to probe, primary [ip] first.
  List<String> get allAddresses {
    final seen = <String>{};
    final result = <String>[];
    for (final a in [ip, ...addresses]) {
      final trimmed = a.trim();
      if (trimmed.isEmpty || !seen.add(trimmed)) {
        continue;
      }
      result.add(trimmed);
    }
    return result;
  }

  /// Returns a copy with [address] recorded as a known address and promoted to
  /// the primary [ip] (it was just reached successfully).
  FavoriteDevice withReachedAddress(String address) {
    final others = allAddresses.where((a) => a != address).toList();
    return copyWith(
      ip: address,
      addresses: others,
    );
  }

  static const fromJson = FavoriteDeviceMapper.fromJson;
}
