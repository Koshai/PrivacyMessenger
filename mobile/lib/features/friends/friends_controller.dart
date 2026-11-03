import 'package:flutter/foundation.dart';

import '../../core/auth/auth_controller.dart';
import '../../core/network/api_client.dart';
import 'models/friend.dart';

enum FriendsLoadState { idle, loading, ready, error }

class FriendsController extends ChangeNotifier {
  final ApiClient apiClient;
  final AuthController authController;

  FriendsLoadState loadState = FriendsLoadState.idle;
  String? errorMessage;
  int friendCount = 0;
  List<Friend> friends = const [];
  List<FriendRequest> incoming = const [];
  List<FriendRequest> outgoing = const [];
  List<BlockedUser> blocked = const [];
  bool mutating = false;

  FriendsController({
    required this.apiClient,
    required this.authController,
  });

  Future<String> _requireToken() async {
    final token = await authController.sessionToken();
    if (token == null || token.isEmpty) {
      throw const ApiException(
        'Authentication required',
        kind: ApiErrorKind.unauthorized,
      );
    }
    return token;
  }

  Future<void> refresh() async {
    loadState = FriendsLoadState.loading;
    errorMessage = null;
    notifyListeners();

    try {
      final token = await _requireToken();
      final results = await Future.wait([
        apiClient.listFriends(token),
        apiClient.friendCount(token),
        apiClient.listIncomingFriendRequests(token),
        apiClient.listOutgoingFriendRequests(token),
        apiClient.listBlockedUsers(token),
      ]);

      friends = results[0] as List<Friend>;
      friendCount = results[1] as int;
      incoming = results[2] as List<FriendRequest>;
      outgoing = results[3] as List<FriendRequest>;
      blocked = results[4] as List<BlockedUser>;
      loadState = FriendsLoadState.ready;
    } on ApiException catch (e) {
      errorMessage = e.message;
      loadState = FriendsLoadState.error;
    } catch (_) {
      errorMessage = 'Unable to load friends';
      loadState = FriendsLoadState.error;
    }

    notifyListeners();
  }

  Future<void> sendRequest(String email) async {
    mutating = true;
    notifyListeners();
    try {
      final token = await _requireToken();
      await apiClient.sendFriendRequest(token: token, email: email);
      await refresh();
    } finally {
      mutating = false;
      notifyListeners();
    }
  }

  Future<void> accept(String requestId) async {
    mutating = true;
    notifyListeners();
    try {
      final token = await _requireToken();
      await apiClient.acceptFriendRequest(token: token, requestId: requestId);
      await refresh();
    } finally {
      mutating = false;
      notifyListeners();
    }
  }

  Future<void> reject(String requestId) async {
    mutating = true;
    notifyListeners();
    try {
      final token = await _requireToken();
      await apiClient.rejectFriendRequest(token: token, requestId: requestId);
      await refresh();
    } finally {
      mutating = false;
      notifyListeners();
    }
  }

  Future<void> remove(String userId) async {
    mutating = true;
    notifyListeners();
    try {
      final token = await _requireToken();
      await apiClient.removeFriend(token: token, userId: userId);
      await refresh();
    } finally {
      mutating = false;
      notifyListeners();
    }
  }

  Future<void> block(String userId) async {
    mutating = true;
    notifyListeners();
    try {
      final token = await _requireToken();
      await apiClient.blockUser(token: token, userId: userId);
      await refresh();
    } finally {
      mutating = false;
      notifyListeners();
    }
  }

  Future<void> unblock(String userId) async {
    mutating = true;
    notifyListeners();
    try {
      final token = await _requireToken();
      await apiClient.unblockUser(token: token, userId: userId);
      await refresh();
    } finally {
      mutating = false;
      notifyListeners();
    }
  }
}
