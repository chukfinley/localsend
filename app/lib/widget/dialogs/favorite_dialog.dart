import 'dart:async';

import 'package:common/model/device.dart';
import 'package:flutter/material.dart';
import 'package:localsend_app/config/theme.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/model/persistence/favorite_device.dart';
import 'package:localsend_app/provider/device_info_provider.dart';
import 'package:localsend_app/provider/favorites_provider.dart';
import 'package:localsend_app/provider/http_provider.dart';
import 'package:localsend_app/provider/settings_provider.dart';
import 'package:localsend_app/rust/api/model.dart';
import 'package:localsend_app/util/rust.dart';
import 'package:localsend_app/widget/dialogs/error_dialog.dart';
import 'package:localsend_app/widget/dialogs/favorite_edit_dialog.dart';
import 'package:refena_flutter/refena_flutter.dart';
import 'package:routerino/routerino.dart';

/// A dialog showing a list of favorites
class FavoritesDialog extends StatefulWidget {
  const FavoritesDialog();

  @override
  State<FavoritesDialog> createState() => _FavoritesDialogState();
}

class _FavoritesDialogState extends State<FavoritesDialog> with Refena {
  bool _fetching = false;
  String? _error;

  /// Checks if the device is reachable and pops the dialog with the result if it is.
  ///
  /// All known addresses of the favorite (LAN IP, Tailscale 100.x, MagicDNS name,
  /// hotspot IP, ...) are probed in parallel; the first one that answers wins.
  /// The winning address is promoted to primary and the alias is synced from the
  /// device unless the user set a custom one.
  Future<void> _checkConnectionToDevice(FavoriteDevice favorite) async {
    setState(() {
      _fetching = true;
      _error = null;
    });

    final https = ref.read(settingsProvider).https;
    final addresses = favorite.allAddresses;

    if (addresses.isEmpty) {
      setState(() {
        _fetching = false;
        _error = 'No address configured for this favorite.';
      });
      return;
    }

    try {
      final payload = ref.read(deviceFullInfoProvider).toRegisterDto();
      final protocol = https ? ProtocolType.https : ProtocolType.http;
      final v2 = ref.read(httpProvider).v2;

      final (address, body) = await _probeFirstReachable(
        v2: v2,
        protocol: protocol,
        addresses: addresses,
        port: favorite.port,
        payload: payload,
      );

      final device = body.toDevice(address, favorite.port, https, HttpDiscovery(ip: address));

      // Learn: promote the reached address to primary, sync alias from the
      // device unless the user explicitly set a custom one.
      var updated = favorite.withReachedAddress(address);
      if (!favorite.customAlias && body.alias.isNotEmpty) {
        updated = updated.copyWith(alias: body.alias);
      }
      if (updated != favorite) {
        await ref.redux(favoritesProvider).dispatchAsync(UpdateFavoriteAction(updated));
      }

      if (mounted) {
        context.pop(device);
      }
    } catch (e) {
      setState(() {
        _fetching = false;
        _error = e.toString();
      });
    }
  }

  /// Registers against every [addresses] entry concurrently and resolves with
  /// the first reachable one. Rejects only if every address fails.
  Future<(String, dynamic)> _probeFirstReachable({
    required dynamic v2,
    required ProtocolType protocol,
    required List<String> addresses,
    required int port,
    required dynamic payload,
  }) async {
    final completer = Completer<(String, dynamic)>();
    var remaining = addresses.length;
    Object? lastError;

    for (final address in addresses) {
      unawaited(() async {
        try {
          final response = await v2.register(
            protocol: protocol,
            ip: address,
            port: port,
            payload: payload,
          );
          if (!completer.isCompleted) {
            completer.complete((address, response.body));
          }
        } catch (e) {
          lastError = e;
        } finally {
          remaining--;
          if (remaining == 0 && !completer.isCompleted) {
            completer.completeError(lastError ?? Exception('Device unreachable'));
          }
        }
      }());
    }

    return completer.future;
  }

  Future<void> _showDeviceDialog([FavoriteDevice? favorite]) async {
    await showDialog(
      context: context,
      builder: (_) => FavoriteEditDialog(favorite: favorite),
    );
  }

  @override
  Widget build(BuildContext context) {
    final favorites = ref.watch(favoritesProvider);

    return AlertDialog(
      title: Text(t.dialogs.favoriteDialog.title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (favorites.isEmpty)
            Text(
              t.dialogs.favoriteDialog.noFavorites,
              style: const TextStyle(color: Colors.grey),
            ),
          for (final favorite in favorites)
            Row(
              children: [
                Expanded(
                  child: TextButton(
                    style: TextButton.styleFrom(foregroundColor: Theme.of(context).colorScheme.onSurface),
                    onPressed: _fetching ? null : () async => await _checkConnectionToDevice(favorite),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                          '${favorite.alias}\n(${favorite.ip}${favorite.allAddresses.length > 1 ? ' +${favorite.allAddresses.length - 1}' : ''})'),
                    ),
                  ),
                ),
                TextButton(
                  style: TextButton.styleFrom(foregroundColor: Theme.of(context).colorScheme.onSurface),
                  onPressed: _fetching ? null : () async => await _showDeviceDialog(favorite),
                  child: const Icon(Icons.edit),
                ),
              ],
            ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Row(
                children: [
                  Text(t.general.error, style: TextStyle(color: Theme.of(context).colorScheme.warning)),
                  if (_error != null) ...[
                    const SizedBox(width: 5),
                    InkWell(
                      onTap: () async {
                        await showDialog(
                          context: context,
                          builder: (_) => ErrorDialog(error: _error!),
                        );
                      },
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 5),
                        child: Icon(Icons.info, color: Theme.of(context).colorScheme.warning, size: 20),
                      ),
                    ),
                  ],
                ],
              ),
            ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => context.pop(),
          child: Text(t.general.cancel),
        ),
        FilledButton(
          onPressed: _showDeviceDialog,
          child: Text(t.dialogs.favoriteDialog.addFavorite),
        ),
      ],
    );
  }
}
