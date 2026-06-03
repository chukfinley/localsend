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
import 'package:localsend_app/widget/dialogs/favorite_delete_dialog.dart';
import 'package:refena_flutter/refena_flutter.dart';
import 'package:routerino/routerino.dart';

/// A dialog to add or edit a favorite device.
class FavoriteEditDialog extends StatefulWidget {
  final FavoriteDevice? favorite;
  final Device? prefilledDevice;

  const FavoriteEditDialog({
    this.favorite,
    this.prefilledDevice,
  });

  @override
  State<FavoriteEditDialog> createState() => _FavoriteEditDialogState();
}

class _FavoriteEditDialogState extends State<FavoriteEditDialog> with Refena {
  final _ipController = TextEditingController();
  final _portController = TextEditingController();
  final _aliasController = TextEditingController();
  final _addressesController = TextEditingController();
  bool _fetching = false;
  String? _error;

  @override
  void initState() {
    super.initState();

    _ipController.text = widget.prefilledDevice?.ip ?? widget.favorite?.ip ?? '';
    _aliasController.text = widget.prefilledDevice?.alias ?? widget.favorite?.alias ?? '';

    // Extra addresses (Tailscale MagicDNS name, other IPs) shown one per line,
    // excluding the primary address which already lives in the IP field.
    final favorite = widget.favorite;
    if (favorite != null) {
      final extra = favorite.allAddresses.where((a) => a != favorite.ip).toList();
      _addressesController.text = extra.join('\n');
    }

    ensureRef((ref) {
      _portController.text =
          widget.prefilledDevice?.port.toString() ?? widget.favorite?.port.toString() ?? ref.read(settingsProvider).port.toString();
    });
  }

  /// Splits the extra-addresses field by newline/comma into a clean list.
  List<String> _parseExtraAddresses() {
    return _addressesController.text
        .split(RegExp(r'[\n,]'))
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty && e != _ipController.text.trim())
        .toList();
  }

  @override
  void dispose() {
    _ipController.dispose();
    _portController.dispose();
    _aliasController.dispose();
    _addressesController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.favorite != null ? t.dialogs.favoriteEditDialog.titleEdit : t.dialogs.favoriteEditDialog.titleAdd),
      content: SingleChildScrollView(
        scrollDirection: Axis.vertical,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(t.dialogs.favoriteEditDialog.name),
            const SizedBox(height: 5),
            TextFormField(
              controller: _aliasController,
              decoration: InputDecoration(
                hintText: t.dialogs.favoriteEditDialog.auto,
              ),
              enabled: !_fetching,
            ),
            const SizedBox(height: 16),
            Text(t.dialogs.favoriteEditDialog.ip),
            const SizedBox(height: 5),
            TextFormField(
              controller: _ipController,
              autofocus: widget.favorite == null && widget.prefilledDevice == null,
              enabled: !_fetching,
            ),
            const SizedBox(height: 16),
            Text(t.dialogs.favoriteEditDialog.port),
            const SizedBox(height: 5),
            TextFormField(
              controller: _portController,
              enabled: !_fetching,
              keyboardType: TextInputType.number,
            ),
            const SizedBox(height: 16),
            const Text('Additional addresses'),
            const SizedBox(height: 5),
            TextFormField(
              controller: _addressesController,
              enabled: !_fetching,
              minLines: 1,
              maxLines: 4,
              decoration: const InputDecoration(
                hintText: 'Tailscale name / extra IPs\n(one per line, optional)',
              ),
            ),
            if (widget.favorite != null) ...[
              const SizedBox(height: 16),
              TextButton.icon(
                style: TextButton.styleFrom(
                  foregroundColor: Theme.of(context).colorScheme.warning,
                ),
                onPressed: () async {
                  final result = await showDialog<bool>(
                    context: context,
                    builder: (_) => FavoriteDeleteDialog(widget.favorite!),
                  );

                  if (context.mounted && result == true) {
                    await context.ref.redux(favoritesProvider).dispatchAsync(RemoveFavoriteAction(deviceFingerprint: widget.favorite!.fingerprint));
                    if (context.mounted) {
                      context.pop();
                    }
                  }
                },
                icon: const Icon(Icons.delete),
                label: Text(t.general.delete),
              ),
            ],
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
      ),
      actions: [
        TextButton(
          onPressed: () => context.pop(),
          child: Text(t.general.cancel),
        ),
        FilledButton(
          onPressed: _fetching
              ? null
              : () async {
                  if (_ipController.text.isEmpty) {
                    return;
                  }

                  if (_portController.text.isEmpty) {
                    return;
                  }

                  if (widget.favorite != null) {
                    // Update existing favorite
                    final existingFavorite = widget.favorite!;
                    final trimmedNewAlias = _aliasController.text.trim();
                    if (trimmedNewAlias.isEmpty) {
                      return;
                    }

                    await ref
                        .redux(favoritesProvider)
                        .dispatchAsync(
                          UpdateFavoriteAction(
                            existingFavorite.copyWith(
                              ip: _ipController.text,
                              port: int.parse(_portController.text),
                              alias: trimmedNewAlias,
                              customAlias: existingFavorite.customAlias || trimmedNewAlias != existingFavorite.alias,
                              addresses: _parseExtraAddresses(),
                            ),
                          ),
                        );
                  } else {
                    // Add new favorite
                    final ip = _ipController.text;
                    final port = int.parse(_portController.text);
                    final https = ref.read(settingsProvider).https;
                    setState(() {
                      _fetching = true;
                    });

                    try {
                      final payload = ref.read(deviceFullInfoProvider).toRegisterDto();
                      final response = await ref
                          .read(httpProvider)
                          .v2
                          .register(
                        protocol: https ? ProtocolType.https : ProtocolType.http,
                        ip: ip,
                        port: port,
                        payload: payload,
                      );

                      final name = _aliasController.text.trim();

                      await ref
                          .redux(favoritesProvider)
                          .dispatchAsync(
                            AddFavoriteAction(
                              FavoriteDevice.fromValues(
                                fingerprint: response.body.token,
                                ip: _ipController.text,
                                port: int.parse(_portController.text),
                                alias: name.isEmpty ? response.body.alias : name,
                                addresses: _parseExtraAddresses(),
                              ),
                            ),
                          );

                      if (context.mounted) {
                        context.pop();
                      }
                    } catch (e) {
                      setState(() {
                        _fetching = false;
                        _error = e.toString();
                      });
                    }
                  }
                },
          child: Text(t.general.confirm),
        ),
      ],
    );
  }
}
