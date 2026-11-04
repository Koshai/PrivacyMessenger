import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

enum SafetyTrustState { unverified, verified, changed }

/// User-visible fingerprint / safety-number screen (C3).
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

  String _grouped(String hex) {
    final buf = StringBuffer();
    for (var i = 0; i < hex.length; i += 4) {
      if (i > 0) buf.write(' ');
      buf.write(hex.substring(i, i + 4 > hex.length ? hex.length : i + 4));
    }
    return buf.toString().toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    final warning = _trust == SafetyTrustState.changed;

    return Scaffold(
      appBar: AppBar(title: const Text('Safety number')),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Text(
            widget.peerEmail,
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 8),
          Text(
            'Compare these fingerprints with your contact using a trusted channel. '
            'The server can store public keys but cannot prove human identity.',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          if (warning) ...[
            const SizedBox(height: 16),
            MaterialBanner(
              content: const Text(
                'Safety number changed. Verify again before trusting this contact.',
              ),
              leading: const Icon(Icons.warning_amber),
              actions: const [SizedBox.shrink()],
            ),
          ],
          const SizedBox(height: 24),
          Text('Their fingerprint', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          SelectableText(
            _grouped(widget.peerFingerprintHex),
            style: const TextStyle(fontFamily: 'monospace', fontSize: 16),
          ),
          TextButton.icon(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: widget.peerFingerprintHex));
            },
            icon: const Icon(Icons.copy),
            label: const Text('Copy'),
          ),
          const SizedBox(height: 24),
          Text('Your fingerprint', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          SelectableText(
            _grouped(widget.localFingerprintHex),
            style: const TextStyle(fontFamily: 'monospace', fontSize: 16),
          ),
          const SizedBox(height: 32),
          Text(
            'Trust state: ${_trust.name}',
            style: Theme.of(context).textTheme.labelLarge,
          ),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: () {
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
    );
  }
}
