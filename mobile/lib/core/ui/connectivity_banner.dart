import 'package:flutter/material.dart';

/// Coarse link state for messaging UI. Not a proof of server write success.
enum ConnectivityBannerState {
  /// Hide the banner.
  hidden,

  /// WebSocket/client is attempting to reconnect.
  reconnecting,

  /// Sync or open failed; realtime may also be down.
  unreachable,
}

/// Non-modal strip for degraded connectivity. Never shows a “Connected” success
/// state — only problems.
class ConnectivityBanner extends StatelessWidget {
  const ConnectivityBanner({
    super.key,
    required this.state,
  });

  final ConnectivityBannerState state;

  @override
  Widget build(BuildContext context) {
    final (label, icon) = switch (state) {
      ConnectivityBannerState.hidden => (null, null),
      ConnectivityBannerState.reconnecting => (
          'Reconnecting…',
          Icons.sync,
        ),
      ConnectivityBannerState.unreachable => (
          'Can’t reach Private Messenger right now. '
              'Messages already on this device stay visible.',
          Icons.cloud_off,
        ),
    };
    if (label == null || icon == null) {
      return const SizedBox.shrink();
    }

    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: [
            Icon(icon, size: 20, semanticLabel: label),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                label,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
