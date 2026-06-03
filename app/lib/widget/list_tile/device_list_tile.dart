import 'package:common/model/device.dart';
import 'package:flutter/material.dart';
import 'package:localsend_app/util/device_type_ext.dart';
import 'package:localsend_app/widget/custom_progress_bar.dart';
import 'package:localsend_app/widget/device_bage.dart';
import 'package:localsend_app/widget/list_tile/custom_list_tile.dart';

class DeviceListTile extends StatelessWidget {
  final Device device;
  final bool isFavorite;

  /// If not null, this name is used instead of [Device.alias].
  /// This is the case when the device is marked as favorite.
  final String? nameOverride;

  final String? info;
  final double? progress;
  final VoidCallback? onTap;
  final VoidCallback? onFavoriteTap;

  const DeviceListTile({
    required this.device,
    this.isFavorite = false,
    this.nameOverride,
    this.info,
    this.progress,
    this.onTap,
    this.onFavoriteTap,
  });

  @override
  Widget build(BuildContext context) {
    final badgeColor = Color.lerp(Theme.of(context).colorScheme.secondaryContainer, Colors.white, 0.3)!;
    return CustomListTile(
      icon: Icon(device.deviceType.icon, size: 46),
      title: Text(nameOverride ?? device.alias, style: const TextStyle(fontSize: 20)),
      trailing: onFavoriteTap != null
          ? IconButton(
              icon: Icon(isFavorite ? Icons.favorite : Icons.favorite_border),
              onPressed: onFavoriteTap,
            )
          : null,
      subTitle: Wrap(
        runSpacing: 10,
        spacing: 10,
        children: [
          if (info != null)
            Text(info!, style: const TextStyle(color: Colors.grey))
          else if (progress != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 5),
              child: CustomProgressBar(progress: progress!),
            )
          else ...[
            if (device.ip != null)
              DeviceBadge(
                backgroundColor: badgeColor,
                foregroundColor: Theme.of(context).colorScheme.onSecondaryContainer,
                label: _isTailscaleIp(device.ip!) ? 'Tailscale' : 'LAN • HTTP',
              )
            else
              DeviceBadge(
                backgroundColor: badgeColor,
                foregroundColor: Theme.of(context).colorScheme.onSecondaryContainer,
                label: 'WebRTC',
              ),
            if (device.deviceModel != null)
              DeviceBadge(
                backgroundColor: badgeColor,
                foregroundColor: Theme.of(context).colorScheme.onSecondaryContainer,
                label: device.deviceModel!,
              ),
          ],
        ],
      ),
      onTap: onTap,
    );
  }
}

/// True if [ip] is in the Tailscale CGNAT range (100.64.0.0/10).
bool _isTailscaleIp(String ip) {
  final parts = ip.split('.');
  if (parts.length != 4) return false;
  final a = int.tryParse(parts[0]);
  final b = int.tryParse(parts[1]);
  return a == 100 && b != null && b >= 64 && b <= 127;
}
