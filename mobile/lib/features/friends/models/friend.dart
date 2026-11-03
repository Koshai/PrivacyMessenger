class Friend {
  final String userId;
  final String email;
  final DateTime since;

  const Friend({
    required this.userId,
    required this.email,
    required this.since,
  });

  factory Friend.fromJson(Map<String, dynamic> json) {
    final userId = json['user_id'];
    final email = json['email'];
    final since = json['since'];

    if (userId is! String ||
        userId.isEmpty ||
        email is! String ||
        email.isEmpty ||
        since is! String) {
      throw const FormatException('Invalid friend payload');
    }

    final parsed = DateTime.tryParse(since);
    if (parsed == null) {
      throw const FormatException('Invalid friend since timestamp');
    }

    return Friend(userId: userId, email: email, since: parsed.toUtc());
  }
}

class FriendRequest {
  final String id;
  final String userId;
  final String email;
  final DateTime createdAt;
  final bool outgoing;

  const FriendRequest({
    required this.id,
    required this.userId,
    required this.email,
    required this.createdAt,
    required this.outgoing,
  });

  factory FriendRequest.fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final userId = json['user_id'];
    final email = json['email'];
    final createdAt = json['created_at'];
    final outgoing = json['outgoing'];

    if (id is! String ||
        id.isEmpty ||
        userId is! String ||
        userId.isEmpty ||
        email is! String ||
        email.isEmpty ||
        createdAt is! String ||
        outgoing is! bool) {
      throw const FormatException('Invalid friend request payload');
    }

    final parsed = DateTime.tryParse(createdAt);
    if (parsed == null) {
      throw const FormatException('Invalid friend request timestamp');
    }

    return FriendRequest(
      id: id,
      userId: userId,
      email: email,
      createdAt: parsed.toUtc(),
      outgoing: outgoing,
    );
  }
}

class BlockedUser {
  final String userId;
  final String email;
  final DateTime createdAt;

  const BlockedUser({
    required this.userId,
    required this.email,
    required this.createdAt,
  });

  factory BlockedUser.fromJson(Map<String, dynamic> json) {
    final userId = json['user_id'];
    final email = json['email'];
    final createdAt = json['created_at'];

    if (userId is! String ||
        userId.isEmpty ||
        email is! String ||
        email.isEmpty ||
        createdAt is! String) {
      throw const FormatException('Invalid blocked user payload');
    }

    final parsed = DateTime.tryParse(createdAt);
    if (parsed == null) {
      throw const FormatException('Invalid block timestamp');
    }

    return BlockedUser(
      userId: userId,
      email: email,
      createdAt: parsed.toUtc(),
    );
  }
}
