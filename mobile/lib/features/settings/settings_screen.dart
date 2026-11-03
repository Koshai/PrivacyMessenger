import 'package:flutter/material.dart';

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
            title: Text('Privacy and Security', style: TextStyle(fontSize: 18)),
            subtitle: Text('End-to-end encryption planned'),
          ),
          const Divider(),
          FilledButton.tonalIcon(
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
        ],
      ),
    );
  }

  Future<void> _handleLogout() async {
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
