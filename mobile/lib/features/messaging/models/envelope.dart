import 'dart:convert';

class MessageEnvelope {
  final String id;
  final String conversationId;
  final String senderId;
  final String clientMessageId;
  final List<int> ciphertext;
  final String contentType;
  final DateTime createdAt;

  const MessageEnvelope({
    required this.id,
    required this.conversationId,
    required this.senderId,
    required this.clientMessageId,
    required this.ciphertext,
    required this.contentType,
    required this.createdAt,
  });

  factory MessageEnvelope.fromJson(Map<String, dynamic> json) {
    final created = DateTime.tryParse(json['created_at'] as String? ?? '');
    final b64 = json['ciphertext_b64'] as String? ?? '';
    if (created == null) {
      throw const FormatException('Invalid envelope timestamp');
    }
    return MessageEnvelope(
      id: json['id'] as String,
      conversationId: json['conversation_id'] as String,
      senderId: json['sender_id'] as String,
      clientMessageId: json['client_message_id'] as String,
      ciphertext: base64Decode(b64),
      contentType: json['content_type'] as String? ?? 'application/opaque',
      createdAt: created.toUtc(),
    );
  }
}

class ConversationInfo {
  final String conversationId;
  final DateTime createdAt;
  final String? mlsGroupIdHex;

  const ConversationInfo({
    required this.conversationId,
    required this.createdAt,
    this.mlsGroupIdHex,
  });

  factory ConversationInfo.fromJson(Map<String, dynamic> json) {
    final created = DateTime.tryParse(json['created_at'] as String? ?? '');
    if (created == null) {
      throw const FormatException('Invalid conversation timestamp');
    }
    return ConversationInfo(
      conversationId: json['conversation_id'] as String,
      createdAt: created.toUtc(),
      mlsGroupIdHex: json['mls_group_id_hex'] as String?,
    );
  }
}

enum ChatDeliveryState { sending, sent, failed }

class ChatMessageView {
  final String clientMessageId;
  final String? serverEnvelopeId;
  final String senderId;
  final String plaintext;
  final DateTime createdAt;
  final ChatDeliveryState delivery;
  final bool isMine;
  final String? error;

  const ChatMessageView({
    required this.clientMessageId,
    required this.senderId,
    required this.plaintext,
    required this.createdAt,
    required this.delivery,
    required this.isMine,
    this.serverEnvelopeId,
    this.error,
  });

  ChatMessageView copyWith({
    ChatDeliveryState? delivery,
    String? serverEnvelopeId,
    String? error,
  }) {
    return ChatMessageView(
      clientMessageId: clientMessageId,
      serverEnvelopeId: serverEnvelopeId ?? this.serverEnvelopeId,
      senderId: senderId,
      plaintext: plaintext,
      createdAt: createdAt,
      delivery: delivery ?? this.delivery,
      isMine: isMine,
      error: error,
    );
  }
}
