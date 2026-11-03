import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/features/friends/models/friend.dart';

void main() {
  test('Friend parses JSON', () {
    final friend = Friend.fromJson({
      'user_id': 'user-1',
      'email': 'a@example.com',
      'since': '2026-01-02T03:04:05Z',
    });

    expect(friend.userId, 'user-1');
    expect(friend.email, 'a@example.com');
    expect(friend.since.isUtc, isTrue);
  });

  test('FriendRequest parses JSON', () {
    final request = FriendRequest.fromJson({
      'id': 'req-1',
      'user_id': 'user-2',
      'email': 'b@example.com',
      'created_at': '2026-02-03T04:05:06Z',
      'outgoing': false,
    });

    expect(request.id, 'req-1');
    expect(request.outgoing, isFalse);
  });
}
