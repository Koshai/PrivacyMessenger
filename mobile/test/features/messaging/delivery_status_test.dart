import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/features/messaging/conversation_screen.dart';
import 'package:private_messenger/features/messaging/delivery_timing.dart';
import 'package:private_messenger/features/messaging/models/envelope.dart';

void main() {
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
      'Sent',
    );
    expect(
      deliveryStatusLabel(delivery: ChatDeliveryState.sending, isMine: true),
      'Sending',
    );
    expect(
      deliveryStatusLabel(delivery: ChatDeliveryState.failed, isMine: true),
      'Failed',
    );
    expect(
      deliveryStatusLabel(delivery: ChatDeliveryState.uncertain, isMine: true),
      'Unconfirmed',
    );
    expect(
      deliveryStatusLabel(delivery: ChatDeliveryState.blocked, isMine: true),
      'Needs attention',
    );
    expect(
      deliveryStatusLabel(
        delivery: ChatDeliveryState.received,
        isMine: true,
      ),
      isNull,
    );
  });

  testWidgets('a received bubble does not show Sent', (tester) async {
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
    expect(find.text('Sent'), findsOneWidget);
    expect(find.text('hello'), findsOneWidget);
    expect(find.text('outgoing'), findsOneWidget);
  });

  testWidgets('outgoing failed keeps Failed and Retry', (tester) async {
    var retried = false;
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
            onRetry: () => retried = true,
          ),
        ),
      ),
    );

    expect(find.text('Failed'), findsOneWidget);
    expect(find.text('Sent'), findsNothing);
    await tester.tap(find.text('Retry'));
    expect(retried, isTrue);
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
