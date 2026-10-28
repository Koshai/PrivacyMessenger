import 'package:flutter/material.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool easyMode = false;

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
        ],
      ),
    );
  }
}
