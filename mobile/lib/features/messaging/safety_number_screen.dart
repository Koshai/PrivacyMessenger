import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'safety_number_copy.dart';

export 'safety_number_copy.dart' show SafetyTrustState;

/// User-visible fingerprint / safety-number screen.
class SafetyNumberScreen extends StatefulWidget {
  const SafetyNumberScreen({
    super.key,
    required this.peerEmail,
    required this.peerFingerprintHex,
    required this.localFingerprintHex,
    this.initialTrust = SafetyTrustState.unverified,
    this.onTrustChanged,
  });

  final String peerEmail;
  final String peerFingerprintHex;
  final String localFingerprintHex;
  final SafetyTrustState initialTrust;
  final ValueChanged<SafetyTrustState>? onTrustChanged;

  @override
  State<SafetyNumberScreen> createState() => _SafetyNumberScreenState();
}

class _SafetyNumberScreenState extends State<SafetyNumberScreen> {
  late SafetyTrustState _trust;

  @override
  void initState() {
    super.initState();
    _trust = widget.initialTrust;
  }

  Future<void> _copyExact(String value, String label) async {
    await Clipboard.setData(ClipboardData(text: value));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('$label copied')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final warning = _trust == SafetyTrustState.changed;
    final peerMissing = widget.peerFingerprintHex.trim().isEmpty;
    final localMissing = widget.localFingerprintHex.trim().isEmpty;

    return Scaffold(
      appBar: AppBar(
        title: Text(
          'Safety number',
          style: theme.textTheme.headlineSmall?.copyWith(
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
          Text(
            widget.peerEmail,
            style: theme.textTheme.titleLarge,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 16),
          Text(SafetyNumberCopy.whatItIs, style: theme.textTheme.bodyMedium),
          const SizedBox(height: 12),
          Text(
            SafetyNumberCopy.howToCompare,
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: 12),
          Text(
            SafetyNumberCopy.encryptionVsVerification,
            style: theme.textTheme.bodyMedium,
          ),
          if (warning) ...[
            const SizedBox(height: 16),
            Material(
              color: theme.colorScheme.errorContainer,
              borderRadius: BorderRadius.circular(12),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.warning_amber,
                      color: theme.colorScheme.onErrorContainer,
                      semanticLabel: 'Warning',
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        SafetyNumberCopy.changedWarning,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onErrorContainer,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
          const SizedBox(height: 24),
          Text('Their safety number', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          if (peerMissing)
            Text(
              'Their safety number isn’t available right now.',
              style: theme.textTheme.bodyMedium,
            )
          else ...[
            SelectableText(
              formatSafetyFingerprintHex(widget.peerFingerprintHex),
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 16,
                height: 1.4,
              ),
            ),
            TextButton.icon(
              onPressed: () => _copyExact(
                widget.peerFingerprintHex,
                'Their safety number',
              ),
              icon: const Icon(Icons.copy, semanticLabel: 'Copy'),
              label: const Text('Copy their number'),
            ),
          ],
          const SizedBox(height: 24),
          Text('Your safety number', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          if (localMissing)
            Text(
              'Your safety number isn’t available on this device.',
              style: theme.textTheme.bodyMedium,
            )
          else
            SelectableText(
              formatSafetyFingerprintHex(widget.localFingerprintHex),
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 16,
                height: 1.4,
              ),
            ),
          const SizedBox(height: 32),
          Text(
            'Status: ${safetyTrustLabel(_trust)}',
            key: const Key('safety-trust-status'),
            style: theme.textTheme.titleSmall,
          ),
          const SizedBox(height: 8),
          Text(
            _trust == SafetyTrustState.verified
                ? 'You marked this contact as verified after comparing numbers.'
                : 'Private Messenger never marks a contact verified for you.',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: peerMissing
                ? null
                : () {
                    setState(() => _trust = SafetyTrustState.verified);
                    widget.onTrustChanged?.call(_trust);
                  },
            child: const Text('Mark as verified'),
          ),
          const SizedBox(height: 8),
          OutlinedButton(
            onPressed: () {
              setState(() => _trust = SafetyTrustState.unverified);
              widget.onTrustChanged?.call(_trust);
            },
            child: const Text('Clear verification'),
          ),
        ],
        ),
      ),
    );
  }
}
