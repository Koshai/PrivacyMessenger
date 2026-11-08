import 'models/envelope.dart';

/// Safe user action for an outgoing bubble. Presentation only.
enum MessageStatusAction {
  /// No button.
  none,

  /// Resubmit the durable outbox ciphertext under the same client message id.
  resubmitSame,

  /// User must type a new message; never call retry for this bubble.
  composeNew,
}

/// User-facing status for one [ChatDeliveryState].
///
/// Durable outbox states stay in [LocalMessageDelivery]; this only maps the
/// already-collapsed [ChatDeliveryState] values shown in the UI.
class MessageStatusPresentation {
  const MessageStatusPresentation({
    required this.label,
    this.detail,
    this.action = MessageStatusAction.none,
    this.actionLabel,
  });

  final String label;
  final String? detail;
  final MessageStatusAction action;
  final String? actionLabel;
}

/// Honest labels — never claim peer-device delivery or read receipts.
MessageStatusPresentation? messageStatusFor({
  required ChatDeliveryState delivery,
  required bool isMine,
}) {
  if (!isMine) {
    if (delivery == ChatDeliveryState.received) {
      return const MessageStatusPresentation(label: 'Received');
    }
    return null;
  }

  switch (delivery) {
    case ChatDeliveryState.sending:
      return const MessageStatusPresentation(label: 'Sending…');
    case ChatDeliveryState.sent:
      return const MessageStatusPresentation(
        label: 'Sent to server',
        detail: 'Delivered to Private Messenger’s servers. '
            'This does not confirm the other person’s device has it yet.',
      );
    case ChatDeliveryState.failed:
      return const MessageStatusPresentation(
        label: 'Couldn’t send',
        detail: 'This copy is still saved on your device. '
            'You can try sending the same encrypted message again.',
        action: MessageStatusAction.resubmitSame,
        actionLabel: 'Try again',
      );
    case ChatDeliveryState.uncertain:
      return const MessageStatusPresentation(
        label: 'Not confirmed',
        detail:
            'We couldn’t confirm whether this message reached the server. '
            'PrivacyMessenger will not try again automatically, to avoid '
            'sending it twice. You can resubmit the same encrypted copy.',
        action: MessageStatusAction.resubmitSame,
        actionLabel: 'Resubmit safely',
      );
    case ChatDeliveryState.blocked:
      return const MessageStatusPresentation(
        label: 'Can’t resend this copy',
        detail:
            'This message can’t be resent safely. Type a new message instead. '
            'Starting a new message may create a separate copy if the original '
            'already reached the server.',
        action: MessageStatusAction.composeNew,
      );
    case ChatDeliveryState.received:
      return null;
  }
}

/// Backward-compatible short label used by older call sites/tests.
String? deliveryStatusLabel({
  required ChatDeliveryState delivery,
  required bool isMine,
}) =>
    messageStatusFor(delivery: delivery, isMine: isMine)?.label;
