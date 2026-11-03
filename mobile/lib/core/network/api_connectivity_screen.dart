import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'api_client.dart';
import 'api_config.dart';

class ApiConnectivityScreen extends StatefulWidget {
  const ApiConnectivityScreen({super.key});

  @override
  State<ApiConnectivityScreen> createState() => _ApiConnectivityScreenState();
}

class _ApiConnectivityScreenState extends State<ApiConnectivityScreen> {
  late final http.Client _httpClient;
  late final ApiClient _apiClient;

  bool _loading = false;
  String _status = 'Not tested';

  @override
  void initState() {
    super.initState();

    _httpClient = http.Client();

    _apiClient = ApiClient(client: _httpClient, baseUri: ApiConfig.baseUri);
  }

  @override
  void dispose() {
    _httpClient.close();
    super.dispose();
  }

  Future<void> _checkConnection() async {
    setState(() {
      _loading = true;
      _status = 'Connecting...';
    });

    try {
      final healthy = await _apiClient.checkHealth();

      if (!mounted) return;

      setState(() {
        _status = healthy
            ? 'Connected to Go backend'
            : 'Unexpected health response';
      });
    } catch (error) {
      if (!mounted) return;

      setState(() {
        _status = 'Connection failed: $error';
      });
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('API Connectivity')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.cloud_outlined, size: 64),
              const SizedBox(height: 20),
              Text(_status, textAlign: TextAlign.center),
              const SizedBox(height: 24),
              FilledButton(
                onPressed: _loading ? null : _checkConnection,
                child: Text(_loading ? 'Checking...' : 'Test connection'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
