import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/network/api_config.dart';

void main() {
  test('local builds keep the existing loopback addresses', () {
    expect(
      ApiConfig.resolve(
        appEnv: 'local',
        apiBaseUrl: '',
        isWeb: false,
        isAndroid: true,
      ),
      Uri.parse('http://10.0.2.2:4000'),
    );
    expect(
      ApiConfig.resolve(
        appEnv: 'local',
        apiBaseUrl: '',
        isWeb: false,
        isAndroid: false,
      ),
      Uri.parse('http://127.0.0.1:4000'),
    );
  });

  test('hosted builds require an https API_BASE_URL', () {
    expect(
      () => ApiConfig.resolve(
        appEnv: 'validation',
        apiBaseUrl: '',
        isWeb: false,
        isAndroid: true,
      ),
      throwsStateError,
    );
    expect(
      () => ApiConfig.resolve(
        appEnv: 'production',
        apiBaseUrl: 'http://api.example.com',
        isWeb: false,
        isAndroid: false,
      ),
      throwsStateError,
    );
    expect(
      ApiConfig.resolve(
        appEnv: 'validation',
        apiBaseUrl: 'https://api.example.com',
        isWeb: false,
        isAndroid: true,
      ),
      Uri.parse('https://api.example.com'),
    );
  });
}
