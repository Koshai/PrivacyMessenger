import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/ui/connectivity_banner.dart';
import 'package:private_messenger/features/messaging/conversation_screen.dart';
import 'package:private_messenger/features/messaging/delivery_timing.dart';
import 'package:private_messenger/features/messaging/message_status.dart';
import 'package:private_messenger/features/messaging/models/envelope.dart';

void main() {
  test('outgoing outbox-facing states map to honest labels', () {
    expect(
      messageStatusFor(delivery: ChatDeliveryState.sending, isMine: true)!.label,
      'Sending…',
    );
    final sent =
        messageStatusFor(delivery: ChatDeliveryState.sent, isMine: true)!;
    expect(sent.label, 'Sent to server');
    expect(sent.detail!.toLowerCase(), isNot(contains('delivered to their')));
    expect(sent.detail!.toLowerCase(), contains('does not confirm'));

    final failed =
        messageStatusFor(delivery: ChatDeliveryState.failed, isMine: true)!;
    expect(failed.label, 'Couldn’t send');
    expect(failed.action, MessageStatusAction.resubmitSame);

    final uncertain =
        messageStatusFor(delivery: ChatDeliveryState.uncertain, isMine: true)!;
    expect(uncertain.label, 'Not confirmed');
    expect(uncertain.detail!.toLowerCase(), contains('will not try again automatically'));
    expect(uncertain.detail!.toLowerCase(), isNot(contains('ciphertext')));
    expect(uncertain.action, MessageStatusAction.resubmitSame);

    final blocked =
        messageStatusFor(delivery: ChatDeliveryState.blocked, isMine: true)!;
    expect(blocked.label, 'Can’t resend this copy');
    expect(blocked.action, MessageStatusAction.composeNew);
    expect(blocked.actionLabel, isNull);
  });

  test('sent does not imply delivered or read', () {
    final sent =
        messageStatusFor(delivery: ChatDeliveryState.sent, isMine: true)!;
    expect(sent.label.toLowerCase(), isNot(contains('delivered')));
    expect(sent.label.toLowerCase(), isNot(contains('read')));
    expect(sent.detail!.toLowerCase(), isNot(contains('read')));
  });

  test('incoming received is labeled Received and never Sent', () {
    expect(
      deliveryStatusLabel(
        delivery: ChatDeliveryState.received,
        isMine: false,
      ),
      'Received',
    );
    expect(
      deliveryStatusLabel(
        delivery: ChatDeliveryState.sent,
        isMine: false,
      ),
      isNull,
    );
    expect(
      deliveryStatusLabel(delivery: ChatDeliveryState.sent, isMine: true),
      'Sent to server',
    );
  });

  testWidgets('a received bubble does not show Sent to server', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              ChatMessageBubble(
                message: ChatMessageView(
                  clientMessageId: 'in',
                  senderId: 'peer',
                  plaintext: 'hello',
                  createdAt: DateTime.utc(2026, 11, 6),
                  delivery: ChatDeliveryState.received,
                  isMine: false,
                ),
                onRetry: () {},
              ),
              ChatMessageBubble(
                message: ChatMessageView(
                  clientMessageId: 'out',
                  senderId: 'me',
                  plaintext: 'outgoing',
                  createdAt: DateTime.utc(2026, 11, 6),
                  delivery: ChatDeliveryState.sent,
                  isMine: true,
                ),
                onRetry: () {},
              ),
            ],
          ),
        ),
      ),
    );

    expect(find.text('Received'), findsOneWidget);
    expect(find.text('Sent to server'), findsOneWidget);
    expect(find.text('Sent'), findsNothing);
  });

  testWidgets('outgoing failed keeps Try again and calls resubmit once', (
    tester,
  ) async {
    var retried = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatMessageBubble(
            message: ChatMessageView(
              clientMessageId: 'out',
              senderId: 'me',
              plaintext: 'pending',
              createdAt: DateTime.utc(2026, 11, 6),
              delivery: ChatDeliveryState.failed,
              isMine: true,
            ),
            onRetry: () => retried++,
          ),
        ),
      ),
    );

    expect(find.text('Couldn’t send'), findsOneWidget);
    await tester.tap(find.text('Try again'));
    expect(retried, 1);
  });

  testWidgets('uncertain shows Resubmit safely and never auto-retries', (
    tester,
  ) async {
    var retried = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatMessageBubble(
            message: ChatMessageView(
              clientMessageId: 'out',
              senderId: 'me',
              plaintext: 'pending',
              createdAt: DateTime.utc(2026, 11, 6),
              delivery: ChatDeliveryState.uncertain,
              isMine: true,
            ),
            onRetry: () => retried++,
          ),
        ),
      ),
    );

    expect(find.text('Not confirmed'), findsOneWidget);
    expect(find.textContaining('ciphertext'), findsNothing);
    expect(find.text('Resubmit safely'), findsOneWidget);
    expect(retried, 0);
    await tester.tap(find.text('Resubmit safely'));
    expect(retried, 1);
  });

  testWidgets('blocked has no resubmit control', (tester) async {
    var retried = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatMessageBubble(
            message: ChatMessageView(
              clientMessageId: 'out',
              senderId: 'me',
              plaintext: 'stuck',
              createdAt: DateTime.utc(2026, 11, 6),
              delivery: ChatDeliveryState.blocked,
              isMine: true,
            ),
            onRetry: () => retried++,
          ),
        ),
      ),
    );

    expect(find.text('Can’t resend this copy'), findsOneWidget);
    expect(find.text('Try again'), findsNothing);
    expect(find.text('Resubmit safely'), findsNothing);
    expect(find.textContaining('Type a new message'), findsOneWidget);
    expect(retried, 0);
  });

  testWidgets('connectivity banner hides when connected', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: ConnectivityBanner(state: ConnectivityBannerState.hidden),
        ),
      ),
    );
    expect(find.textContaining('Reconnecting'), findsNothing);
    expect(find.textContaining('Can’t reach'), findsNothing);
  });

  testWidgets('connectivity banner shows reconnecting and unreachable', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: ConnectivityBanner(state: ConnectivityBannerState.reconnecting),
        ),
      ),
    );
    expect(find.text('Reconnecting…'), findsOneWidget);

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: ConnectivityBanner(state: ConnectivityBannerState.unreachable),
        ),
      ),
    );
    expect(find.textContaining('Can’t reach Private Messenger'), findsOneWidget);
  });

  test('timing records stage and duration only', () {
    DeliveryTiming.reset();
    DeliveryTiming.record(
      'open_enroll',
      1250,
      detail: 'plaintext secret token',
    );
    final event = DeliveryTiming.events.single;
    expect(event.stage, 'open_enroll');
    expect(event.elapsedMs, 1250);
    expect(event.detail, 'redacted');
    expect(event.toString(), isNot(contains('plaintext')));
    expect(event.toString(), isNot(contains('secret')));
    expect(event.toString(), isNot(contains('token')));
  });
}
