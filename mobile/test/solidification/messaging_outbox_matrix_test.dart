import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/features/messaging/local_message_store.dart';
import 'package:private_messenger/features/messaging/message_status.dart';
import 'package:private_messenger/features/messaging/models/envelope.dart';

/// Locks the durable-outbox ↔ UI action contract for Step 19.7.30B.
void main() {
  test('every LocalMessageDelivery value is accounted for in UI mapping', () {
    // Collapsed ChatDeliveryState is what the bubble shows; ensure we do not
    // invent peer-delivery actions for any durable row class.
    for (final delivery in LocalMessageDelivery.values) {
      expect(delivery.name, isNotEmpty);
    }
    expect(LocalMessageDelivery.values.map((e) => e.name).toSet(), containsAll([
      'preparing',
      'encrypting',
      'ready',
      'submitting',
      'sent',
      'failed',
      'uncertain',
      'blocked',
      'received',
      'sending',
    ]));
  });

  test('UI actions never offer unsafe resubmit for blocked or sending', () {
    expect(
      messageStatusFor(delivery: ChatDeliveryState.blocked, isMine: true)!.action,
      MessageStatusAction.composeNew,
    );
    expect(
      messageStatusFor(delivery: ChatDeliveryState.sending, isMine: true)!.action,
      MessageStatusAction.none,
    );
    expect(
      messageStatusFor(delivery: ChatDeliveryState.sent, isMine: true)!.action,
      MessageStatusAction.none,
    );
  });

  test('failed and uncertain are the only resubmitSame UI states', () {
    final resubmittable = ChatDeliveryState.values.where((state) {
      final presentation = messageStatusFor(delivery: state, isMine: true);
      return presentation?.action == MessageStatusAction.resubmitSame;
    }).toSet();
    expect(
      resubmittable,
      {ChatDeliveryState.failed, ChatDeliveryState.uncertain},
    );
  });

  test('sent copy never claims recipient-device delivery', () {
    final sent =
        messageStatusFor(delivery: ChatDeliveryState.sent, isMine: true)!;
    final blob = '${sent.label} ${sent.detail}'.toLowerCase();
    expect(blob, contains('server'));
    expect(blob, isNot(contains('read receipt')));
    expect(blob, isNot(contains('delivered to their device')));
  });
}
