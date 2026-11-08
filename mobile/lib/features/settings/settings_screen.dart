import 'package:flutter/material.dart';

import '../../core/ui/app_confirm_dialog.dart';
import 'privacy_copy.dart';

/// Consequences verified from logout path in `main.dart` +
/// `MlsSessionManager.clearOnLogout` / `DeviceCryptoStore.clearOnLogout`:
/// session is revoked/cleared and this device's MLS keys are removed from
/// secure storage. Re-sign-in creates a new encryption identity. Encrypted
/// database files may remain on disk but prior chats are not readable with the
/// new identity. Local message-history ciphertext is likewise not promised to
/// remain readable after logout.
const logoutConsequenceMessage =
    'Logging out ends this signed-in session and removes this device’s '
    'encryption keys from secure storage.\n\n'
    'After you sign in again, this app creates a new encryption identity. '
    'Previous chats on this device will not be readable.\n\n'
    'Your friend list on the server is unchanged. Message files may remain on '
    'the device but stay locked without the old keys.';

class SettingsScreen extends StatefulWidget {
  final Future<void> Function()? onLogout;
  const SettingsScreen({super.key, this.onLogout});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool easyMode = false;
  bool _isLoggingOut = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Settings',
          style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold),
        ),
      ),
      body: ListView(
        children: [
          SwitchListTile(
            title: const Text('Easy Mode', style: TextStyle(fontSize: 20)),
            subtitle: const Text(
              'Larger text and simpler controls',
              style: TextStyle(fontSize: 16),
            ),
            value: easyMode,
            onChanged: (value) {
              setState(() => easyMode = value);
            },
          ),
          const Divider(),
          const ListTile(
            leading: Icon(Icons.lock_outline),
            title: Text(PrivacyCopy.title, style: TextStyle(fontSize: 18)),
            subtitle: Text(PrivacyCopy.subtitle),
          ),
          const Divider(),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: FilledButton.tonalIcon(
              onPressed: widget.onLogout == null || _isLoggingOut
                  ? null
                  : _handleLogout,
              icon: _isLoggingOut
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.logout),
              label: Text(_isLoggingOut ? 'Logging out...' : 'Log out'),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _handleLogout() async {
    if (_isLoggingOut || widget.onLogout == null) return;

    final confirmed = await showAppConfirmDialog(
      context: context,
      title: 'Log out?',
      message: logoutConsequenceMessage,
      cancelLabel: 'Stay signed in',
      confirmLabel: 'Log out',
      isDestructive: true,
    );
    if (!confirmed || !mounted) return;
    if (_isLoggingOut || widget.onLogout == null) return;

    setState(() => _isLoggingOut = true);

    try {
      await widget.onLogout!();
    } catch (_) {
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Unable to log out. Check your connection and retry.'),
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _isLoggingOut = false);
      }
    }
  }
}
