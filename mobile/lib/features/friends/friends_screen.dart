import 'package:flutter/material.dart';

import '../../core/auth/auth_controller.dart';
import '../../core/network/api_client.dart';
import 'friends_controller.dart';

class FriendsScreen extends StatefulWidget {
  final ApiClient? apiClient;
  final AuthController? authController;

  const FriendsScreen({
    super.key,
    this.apiClient,
    this.authController,
  });

  @override
  State<FriendsScreen> createState() => _FriendsScreenState();
}

class _FriendsScreenState extends State<FriendsScreen> {
  FriendsController? _controller;
  final _emailController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _maybeCreateController();
  }

  @override
  void didUpdateWidget(covariant FriendsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.apiClient != widget.apiClient ||
        oldWidget.authController != widget.authController) {
      _controller?.dispose();
      _controller = null;
      _maybeCreateController();
    }
  }

  void _maybeCreateController() {
    final api = widget.apiClient;
    final auth = widget.authController;
    if (api == null || auth == null) {
      return;
    }

    _controller = FriendsController(apiClient: api, authController: auth)
      ..addListener(_onControllerChanged);
    _controller!.refresh();
  }

  void _onControllerChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  @override
  void dispose() {
    _controller?.removeListener(_onControllerChanged);
    _controller?.dispose();
    _emailController.dispose();
    super.dispose();
  }

  Future<void> _sendRequest() async {
    final controller = _controller;
    if (controller == null) return;

    final email = _emailController.text.trim();
    if (email.isEmpty) {
      _showMessage('Enter an email address');
      return;
    }

    try {
      await controller.sendRequest(email);
      if (!mounted) return;
      _emailController.clear();
      _showMessage(
        'If that account exists, a friend request was submitted.',
      );
    } on ApiException catch (e) {
      if (!mounted) return;
      _showMessage(e.message);
    } catch (_) {
      if (!mounted) return;
      _showMessage('Unable to send friend request');
    }
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;

    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Friends',
          style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold),
        ),
        actions: [
          if (controller != null)
            IconButton(
              tooltip: 'Refresh',
              onPressed: controller.mutating ? null : controller.refresh,
              icon: const Icon(Icons.refresh),
            ),
        ],
      ),
      body: controller == null
          ? const _PrivacyEmptyState()
          : RefreshIndicator(
              onRefresh: controller.refresh,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  const Text(
                    'Your friends are private',
                    style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Only you can see your friends and friend count.',
                    style: TextStyle(fontSize: 16),
                  ),
                  const SizedBox(height: 20),
                  TextField(
                    controller: _emailController,
                    keyboardType: TextInputType.emailAddress,
                    enabled: !controller.mutating,
                    decoration: const InputDecoration(
                      labelText: 'Add friend by email',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  FilledButton(
                    onPressed: controller.mutating ? null : _sendRequest,
                    child: Text(
                      controller.mutating ? 'Working...' : 'Send request',
                    ),
                  ),
                  const SizedBox(height: 24),
                  if (controller.loadState == FriendsLoadState.loading &&
                      controller.friends.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 32),
                      child: Center(child: CircularProgressIndicator()),
                    )
                  else if (controller.loadState == FriendsLoadState.error)
                    Column(
                      children: [
                        Text(
                          controller.errorMessage ?? 'Unable to load friends',
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                        const SizedBox(height: 12),
                        OutlinedButton(
                          onPressed: controller.refresh,
                          child: const Text('Try again'),
                        ),
                      ],
                    )
                  else ...[
                    Text(
                      'Friends (${controller.friendCount})',
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 8),
                    if (controller.friends.isEmpty)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 16),
                        child: Text('No friends yet. Send a request above.'),
                      )
                    else
                      ...controller.friends.map(
                        (friend) => ListTile(
                          contentPadding: EdgeInsets.zero,
                          title: Text(friend.email),
                          subtitle: const Text('Private friend'),
                          trailing: Wrap(
                            spacing: 8,
                            children: [
                              IconButton(
                                tooltip: 'Remove friend',
                                onPressed: controller.mutating
                                    ? null
                                    : () async {
                                        try {
                                          await controller.remove(friend.userId);
                                        } on ApiException catch (e) {
                                          _showMessage(e.message);
                                        }
                                      },
                                icon: const Icon(Icons.person_remove_outlined),
                              ),
                              IconButton(
                                tooltip: 'Block',
                                onPressed: controller.mutating
                                    ? null
                                    : () async {
                                        try {
                                          await controller.block(friend.userId);
                                          _showMessage('User blocked');
                                        } on ApiException catch (e) {
                                          _showMessage(e.message);
                                        }
                                      },
                                icon: const Icon(Icons.block),
                              ),
                            ],
                          ),
                        ),
                      ),
                    const SizedBox(height: 20),
                    const Text(
                      'Incoming requests',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (controller.incoming.isEmpty)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 12),
                        child: Text('No incoming requests'),
                      )
                    else
                      ...controller.incoming.map(
                        (request) => ListTile(
                          contentPadding: EdgeInsets.zero,
                          title: Text(request.email),
                          trailing: Wrap(
                            children: [
                              TextButton(
                                onPressed: controller.mutating
                                    ? null
                                    : () async {
                                        try {
                                          await controller.accept(request.id);
                                        } on ApiException catch (e) {
                                          _showMessage(e.message);
                                        }
                                      },
                                child: const Text('Accept'),
                              ),
                              TextButton(
                                onPressed: controller.mutating
                                    ? null
                                    : () async {
                                        try {
                                          await controller.reject(request.id);
                                        } on ApiException catch (e) {
                                          _showMessage(e.message);
                                        }
                                      },
                                child: const Text('Reject'),
                              ),
                            ],
                          ),
                        ),
                      ),
                    const SizedBox(height: 20),
                    const Text(
                      'Blocked',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (controller.blocked.isEmpty)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 12),
                        child: Text('No blocked users'),
                      )
                    else
                      ...controller.blocked.map(
                        (user) => ListTile(
                          contentPadding: EdgeInsets.zero,
                          title: Text(user.email),
                          trailing: TextButton(
                            onPressed: controller.mutating
                                ? null
                                : () async {
                                    try {
                                      await controller.unblock(user.userId);
                                    } on ApiException catch (e) {
                                      _showMessage(e.message);
                                    }
                                  },
                            child: const Text('Unblock'),
                          ),
                        ),
                      ),
                  ],
                ],
              ),
            ),
    );
  }
}

class _PrivacyEmptyState extends StatelessWidget {
  const _PrivacyEmptyState();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.people_outline, size: 72),
            SizedBox(height: 20),
            Text(
              'Your friends are private',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
              textAlign: TextAlign.center,
            ),
            SizedBox(height: 12),
            Text(
              'Only you can see your friends and friend count.',
              style: TextStyle(fontSize: 18),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
