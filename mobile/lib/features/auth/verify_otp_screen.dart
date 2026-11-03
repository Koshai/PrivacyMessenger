import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/network/api_client.dart';
import '../../core/auth/auth_controller.dart';
import '../../core/auth/auth_state.dart';

class VerifyOtpScreen extends StatefulWidget {
  final String email;
  final String challengeId;
  final DateTime expiresAt;
  final ApiClient apiClient;
  final AuthController authController;

  const VerifyOtpScreen({
    super.key,
    required this.email,
    required this.challengeId,
    required this.expiresAt,
    required this.apiClient,
    required this.authController,
  });

  @override
  State<VerifyOtpScreen> createState() => _VerifyOtpScreenState();
}

class _VerifyOtpScreenState extends State<VerifyOtpScreen> {
  final _formKey = GlobalKey<FormState>();
  final _codeController = TextEditingController();

  bool _isLoading = false;
  bool _isVerified = false;

  @override
  void dispose() {
    _codeController.dispose();
    super.dispose();
  }

  Future<void> _verify() async {
    if (_isLoading || _isVerified) return;
    if (!_formKey.currentState!.validate()) return;

    if (!DateTime.now().toUtc().isBefore(widget.expiresAt.toUtc())) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Code expired. Request a new code.')),
      );
      return;
    }

    setState(() => _isLoading = true);

    try {
      final session = await widget.apiClient.verifyOtp(
        challengeId: widget.challengeId,
        code: _codeController.text,
        deviceName: 'Android',
      );

      if (!mounted) return;

      if (session.isExpired) {
        throw ApiException('Session has already expired');
      }

      await widget.authController.signIn(session);

      if (!mounted) return;

      debugPrint(
        'Authentication status: ${widget.authController.state.status}',
      );

      final status = widget.authController.state.status;

      if (status == AuthStatus.authenticated) {
        return;
      }

      if (status == AuthStatus.unavailable) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Session saved, but validation is unavailable. '
              'Please retry when connected.',
            ),
          ),
        );
        return;
      }

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Unable to establish an authenticated session'),
        ),
      );
    } on ApiException catch (e) {
      if (!mounted) return;

      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.message)));
    } catch (_) {
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Authentication could not be completed')),
      );
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Verify email')),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Form(
              key: _formKey,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Icon(Icons.mark_email_read_outlined, size: 64),
                  const SizedBox(height: 24),
                  const Text(
                    'Enter your verification code',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'We sent a six-digit code to ${widget.email}',
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 32),
                  TextFormField(
                    controller: _codeController,
                    enabled: !_isLoading && !_isVerified,
                    keyboardType: TextInputType.number,
                    textAlign: TextAlign.center,
                    maxLength: 6,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    decoration: const InputDecoration(
                      labelText: 'Verification code',
                      border: OutlineInputBorder(),
                      counterText: '',
                    ),
                    validator: (value) {
                      if (value == null ||
                          !RegExp(r'^[0-9]{6}$').hasMatch(value)) {
                        return 'Enter a valid six-digit code';
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: 20),
                  FilledButton(
                    onPressed: _isLoading || _isVerified ? null : _verify,
                    child: _isLoading
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Text(_isVerified ? 'Verified' : 'Verify code'),
                  ),
                  const SizedBox(height: 16),
                  TextButton(
                    onPressed: _isLoading || _isVerified
                        ? null
                        : () => Navigator.of(context).pop(),
                    child: const Text('Use a different email'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
