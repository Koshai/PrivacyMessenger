import 'package:flutter/material.dart';

import '../../core/auth/auth_controller.dart';
import '../../core/network/api_client.dart';
import 'login_screen.dart';

class AuthFlow extends StatelessWidget {
  final ApiClient apiClient;
  final AuthController authController;

  const AuthFlow({
    super.key,
    required this.apiClient,
    required this.authController,
  });

  @override
  Widget build(BuildContext context) {
    return Navigator(
      onGenerateRoute: (settings) {
        return MaterialPageRoute<void>(
          settings: settings,
          builder: (_) =>
              LoginScreen(apiClient: apiClient, authController: authController),
        );
      },
    );
  }
}
