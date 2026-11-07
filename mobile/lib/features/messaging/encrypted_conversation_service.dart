import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../core/crypto/encryption_service.dart';
import '../../core/crypto/mls_session_manager.dart';
import '../../core/crypto/protocol_messages.dart';
import '../../core/network/api_client.dart'
    show ApiClient, ApiErrorKind, ApiException;
import '../calling/call_auth.dart';
import '../calling/call_auth_session.dart';
import '../calling/call_binding_inbox.dart';
import 'delivery_timing.dart';
import 'local_message_store.dart';
import 'models/envelope.dart';

/// Safe MLS failure record. Fields are stage names, exception types, content
/// types, and sequence numbers. Exception messages and stack text are omitted
/// because OpenMLS and user content can embed secrets.
class MlsDiagnosticEvent {
  final String stage;
  final String exceptionType;
  final String? contentType;
  final int? conversationSeq;

  const MlsDiagnosticEvent({
    required this.stage,
    required this.exceptionType,
    this.contentType,
    this.conversationSeq,
  });

  @override
  String toString() =>
      'MlsDiagnosticEvent(stage=$stage, type=$exceptionType, content=${contentType ?? ''}, seq=${conversationSeq ?? ''})';
}

class MlsSendFailure implements Exception {
  final String stage;
  final String exceptionType;
  final StackTrace? stack;

  MlsSendFailure(this.stage, this.exceptionType, [this.stack]);

  @override
  String toString() => 'MlsSendFailure($stage,$exceptionType)';
}

class _MlsIngestSignal implements Exception {
  final String stage;
  final Object cause;

  _MlsIngestSignal(this.stage, this.cause);

  @override
  String toString() => 'MlsIngestSignal';
}

class MlsDiagnostics {
  static const int _maxEvents = 40;
  static final List<MlsDiagnosticEvent> events = [];

  static void reset() => events.clear();

  static String safeType(Object error) {
    if (error is ApiException) {
      final kind = error.kind.name;
      final code = error.statusCode;
      if (code == null) return 'ApiException.$kind';
      return 'ApiException.$kind.$code';
    }
    if (error is MlsSendFailure) return 'MlsSendFailure';
    final raw = error.runtimeType.toString();
    if (RegExp(r'^[A-Za-z_][A-Za-z0-9_]{0,80}$').hasMatch(raw)) return raw;
    return 'Exception';
  }

  static String _label(String value) {
    if (RegExp(r'^[A-Za-z0-9_./+-]{1,80}$').hasMatch(value)) return value;
    return 'redacted';
  }

  static void record({
    required String stage,
    required Object error,
    String? contentType,
    int? conversationSeq,
    StackTrace? stack,
    bool includeStack = false,
  }) {
    final event = MlsDiagnosticEvent(
      stage: _label(stage),
      exceptionType: safeType(error),
      contentType: contentType == null ? null : _label(contentType),
      conversationSeq: conversationSeq,
    );
    events.add(event);
    if (events.length > _maxEvents) events.removeAt(0);
    if (!kDebugMode) return;
    debugPrint(event.toString());
    if (includeStack && stack != null) debugStack(stack);
  }

  /// Prints Dart stack frames only. Lines that are not frames are dropped so
  /// an exception message cannot ride along with the trace.
  static void debugStack(StackTrace stack) {
    if (!kDebugMode) return;
    final frames = stack
        .toString()
        .split('\n')
        .where((line) => line.trimLeft().startsWith('#'))
        .take(12)
        .join('\n');
    if (frames.isNotEmpty) debugPrint(frames);
  }
}

/// Orchestrates MLS session setup and opaque envelope exchange.
///
/// Does not import `package:openmls` — only [MlsSessionManager].
class EncryptedConversationService {
  EncryptedConversationService({
    required this.api,
    required this.mls,
    this.inbox,
    this.engine,
    this.history,
    this.submitTimeout = const Duration(seconds: 15),
  });

  final ApiClient api;
  final MlsSessionManager mls;
  final CallBindingInbox? inbox;
  final MlsGroupEncryptionService? engine;
  final InboundMessageHistory? history;

  /// Bounds only the envelope HTTP submit. MLS encryption is not cancelled
  /// by this timer and is not repeated after it has produced ciphertext.
  final Duration submitTimeout;

  static const String processingWarning = 'A message could not be processed.';

  MlsGroupEncryptionService? get _crypto => engine ?? mls.service;

  final Map<String, String> _groupByConversation = {};
  final Map<String, String> _knownFingerprints = {};
  final Map<String, String> _peerByConversation = {};
  final Set<String> _processedEnvelopeIds = {};
  final Map<String, StoredCallBinding> _heldBindings = {};
  final Set<String> _unresolvedEnvelopeIds = {};
  Future<void> _chain = Future<void>.value();
  bool _deviceEnrolled = false;

  String? keyChangeWarning;

  void rememberGroup(String conversationId, String groupIdHex) {
    _groupByConversation[conversationId] = groupIdHex;
  }

  /// Pulls pending server envelopes through this pipeline only.
  Future<void> pullPending({
    required String token,
    required String myUserId,
  }) async {
    final pending = await api.syncPending(token: token);
    await ingestEnvelopes(token: token, myUserId: myUserId, envelopes: pending);
  }

  Future<T> _exclusive<T>(Future<T> Function() action) {
    final result = _chain.then((_) => action());
    _chain = result.then((_) {}, onError: (_) {});
    return result;
  }

  Future<void> enrollDevice(String token) async {
    if (_deviceEnrolled) {
      DeliveryTiming.record('enroll_skipped', 0);
      return;
    }
    final record = mls.record;
    if (record == null) throw StateError('MLS not ready');
    final span = DeliveryTiming.start();
    await api.registerMlsIdentity(token: token, publicKey: record.publicKey);
    span.lap('enroll_register_identity');

    final packages = <List<int>>[];
    for (var i = 0; i < 5; i++) {
      final kp = await mls.createKeyPackage();
      packages.add(kp.keyPackageBytes);
    }
    span.lap('enroll_key_packages');
    await api.uploadKeyPackages(token: token, packages: packages);
    span.lap('enroll_upload_key_packages');
    span.total('enroll_total');
    _deviceEnrolled = true;
  }

  Future<ConversationInfo> openWithPeer({
    required String token,
    required String myUserId,
    required String peerUserId,
  }) async {
    final conversation = await api.openConversation(
      token: token,
      peerUserId: peerUserId,
    );

    if (conversation.mlsGroupIdHex != null) {
      _groupByConversation[conversation.conversationId] =
          conversation.mlsGroupIdHex!;
      // Joiner: Welcome arrives via pending/history ingest.
      return conversation;
    }

    final svc = mls.service;
    if (svc == null) throw StateError('MLS not ready');

    try {
      final claimed =
          await api.claimKeyPackage(token: token, peerUserId: peerUserId);
      await _trackFingerprint(
        peerUserId,
        claimed.fingerprintHex,
        deviceId: claimed.deviceId,
      );

      final groupId = await svc.createGroup();
      final invite = await svc.addMember(
        groupIdHex: groupId,
        keyPackageBytes: claimed.keyPackage,
      );

      final established = await api.establishMlsGroup(
        token: token,
        conversationId: conversation.conversationId,
        mlsGroupIdHex: groupId,
      );
      _groupByConversation[conversation.conversationId] = groupId;

      await api.sendEnvelope(
        token: token,
        conversationId: conversation.conversationId,
        clientMessageId: 'welcome-${DateTime.now().microsecondsSinceEpoch}',
        ciphertext: invite.welcome.bytes,
        contentType: MlsContentTypes.welcome,
      );
      await api.sendEnvelope(
        token: token,
        conversationId: conversation.conversationId,
        clientMessageId: 'commit-${DateTime.now().microsecondsSinceEpoch}',
        ciphertext: invite.commit.bytes,
        contentType: MlsContentTypes.commit,
      );
      return established;
    } on ApiException catch (e) {
      // Peer has no packages yet, or another device won the race.
      if (e.statusCode == 404 || e.statusCode == 409) {
        return conversation;
      }
      rethrow;
    }
  }

  Future<ChatMessageView> sendText({
    required String token,
    required String conversationId,
    required String myUserId,
    required String plaintext,
    required String clientMessageId,
    DateTime? createdAt,
  }) async {
    final svc = _crypto;
    if (svc == null) throw StateError('MLS not ready');
    final groupId = _groupByConversation[conversationId];
    if (groupId == null) {
      throw StateError('MLS group not ready for conversation');
    }

    final span = DeliveryTiming.start();
    final stamped = (createdAt ?? DateTime.now().toUtc()).toUtc();
    final pending = ChatMessageView(
      clientMessageId: clientMessageId,
      senderId: myUserId,
      plaintext: plaintext,
      createdAt: stamped,
      delivery: ChatDeliveryState.sending,
      isMine: true,
    );

    try {
      await _persistOutgoing(
        conversationId: conversationId,
        myUserId: myUserId,
        clientMessageId: clientMessageId,
        plaintext: plaintext,
        createdAt: stamped,
        delivery: LocalMessageDelivery.preparing,
      );
      span.lap('send_store_preparing');
    } catch (error) {
      span.total('send_store_failed');
      MlsDiagnostics.record(stage: 'send_history', error: error);
      return pending.copyWith(
        delivery: ChatDeliveryState.failed,
        error: 'Message could not be saved.',
      );
    }

    final prepared = await _prepareApplicationCiphertext(
      conversationId: conversationId,
      clientMessageId: clientMessageId,
      plaintext: plaintext,
      groupId: groupId,
      span: span,
    );
    if (prepared.blocked != null) {
      span.total('send_blocked');
      return pending.copyWith(
        delivery: ChatDeliveryState.blocked,
        error: prepared.blocked,
      );
    }
    final ciphertext = prepared.wire!;

    try {
      await _markOutgoing(
        conversationId: conversationId,
        clientMessageId: clientMessageId,
        delivery: LocalMessageDelivery.submitting,
      );
      final envelope = await api
          .sendEnvelope(
            token: token,
            conversationId: conversationId,
            clientMessageId: clientMessageId,
            ciphertext: ciphertext,
            contentType: MlsContentTypes.application,
          )
          .timeout(submitTimeout);
      span.lap('send_submit');
      final stored = await _markOutgoing(
        conversationId: conversationId,
        clientMessageId: clientMessageId,
        delivery: LocalMessageDelivery.sent,
        envelopeId: envelope.id,
        conversationSeq: envelope.conversationSeq,
        preparedCiphertext: null,
        mlsGroupIdHex: null,
      );
      span.lap('send_store_sent');
      span.total('send_total');
      return ChatMessageView(
        clientMessageId: clientMessageId,
        serverEnvelopeId: stored?.envelopeId ?? envelope.id,
        senderId: myUserId,
        plaintext: plaintext,
        createdAt: stamped,
        delivery: ChatDeliveryState.sent,
        isMine: true,
      );
    } on TimeoutException catch (error) {
      span.total('send_submit_timeout');
      await _markOutgoing(
        conversationId: conversationId,
        clientMessageId: clientMessageId,
        delivery: LocalMessageDelivery.uncertain,
      );
      MlsDiagnostics.record(stage: 'send_envelope', error: error);
      return pending.copyWith(
        delivery: ChatDeliveryState.uncertain,
        error: 'Send unconfirmed. Resubmit only with the same ciphertext.',
      );
    } on ApiException catch (error) {
      if (error.kind == ApiErrorKind.timeout) {
        span.total('send_submit_timeout');
        await _markOutgoing(
          conversationId: conversationId,
          clientMessageId: clientMessageId,
          delivery: LocalMessageDelivery.uncertain,
        );
        MlsDiagnostics.record(stage: 'send_envelope', error: error);
        return pending.copyWith(
          delivery: ChatDeliveryState.uncertain,
          error: 'Send unconfirmed. Resubmit only with the same ciphertext.',
        );
      }
      if (error.statusCode == 409) {
        span.total('send_submit_conflict');
        await _markOutgoing(
          conversationId: conversationId,
          clientMessageId: clientMessageId,
          delivery: LocalMessageDelivery.blocked,
          preparedCiphertext: null,
          mlsGroupIdHex: null,
        );
        MlsDiagnostics.record(stage: 'send_envelope', error: error);
        return pending.copyWith(
          delivery: ChatDeliveryState.blocked,
          error: 'Server rejected conflicting ciphertext for this message id.',
        );
      }
      span.total('send_submit_failed');
      await _markOutgoing(
        conversationId: conversationId,
        clientMessageId: clientMessageId,
        delivery: LocalMessageDelivery.failed,
      );
      MlsDiagnostics.record(stage: 'send_envelope', error: error);
      return pending.copyWith(
        delivery: ChatDeliveryState.failed,
        error: 'Send failed',
      );
    } catch (error) {
      span.total('send_submit_failed');
      await _markOutgoing(
        conversationId: conversationId,
        clientMessageId: clientMessageId,
        delivery: LocalMessageDelivery.failed,
      );
      MlsDiagnostics.record(stage: 'send_envelope', error: error);
      return pending.copyWith(
        delivery: ChatDeliveryState.failed,
        error: 'Send failed',
      );
    }
  }

  /// Loads a durable outbox ciphertext or encrypts once under the MLS lock.
  ///
  /// Never re-encrypts when prepared bytes already exist for this client id.
  Future<({List<int>? wire, String? blocked})> _prepareApplicationCiphertext({
    required String conversationId,
    required String clientMessageId,
    required String plaintext,
    required String groupId,
    required DeliverySpan span,
  }) {
    return _exclusive(() async {
      final existing = await history?.lookupByClientMessageId(
        conversationId: conversationId,
        clientMessageId: clientMessageId,
      );
      if (existing != null && existing.hasPreparedOutbox) {
        span.lap('send_encrypt_reused');
        return (
          wire: List<int>.from(existing.preparedCiphertext!),
          blocked: null,
        );
      }
      if (existing != null && !existing.hasPreparedOutbox) {
        // encrypting/submitting/ready/failed/uncertain/blocked without bytes
        // means the ratchet may already have advanced. preparing/sending is
        // the only state that has not entered the MLS encrypt call yet.
        final mayHaveAdvanced =
            existing.delivery == LocalMessageDelivery.encrypting ||
            existing.delivery == LocalMessageDelivery.submitting ||
            existing.delivery == LocalMessageDelivery.ready ||
            existing.delivery == LocalMessageDelivery.failed ||
            existing.delivery == LocalMessageDelivery.uncertain ||
            existing.delivery == LocalMessageDelivery.blocked;
        if (mayHaveAdvanced) {
          await _markOutgoing(
            conversationId: conversationId,
            clientMessageId: clientMessageId,
            delivery: LocalMessageDelivery.blocked,
          );
          return (
            wire: null,
            blocked:
                'Cannot safely retry: prepared ciphertext is missing after an '
                'interrupted send.',
          );
        }
      }

      final crypto = _crypto;
      if (crypto == null) throw StateError('MLS not ready');
      await _markOutgoing(
        conversationId: conversationId,
        clientMessageId: clientMessageId,
        delivery: LocalMessageDelivery.encrypting,
      );
      try {
        final wire = await crypto.encryptApplication(
          groupIdHex: groupId,
          plaintext: utf8.encode(plaintext),
        );
        final ciphertext = List<int>.from(wire.bytes);
        span.lap('send_encrypt');
        final stored = await _markOutgoing(
          conversationId: conversationId,
          clientMessageId: clientMessageId,
          delivery: LocalMessageDelivery.ready,
          preparedCiphertext: ciphertext,
          mlsGroupIdHex: groupId,
        );
        if (stored == null || !stored.hasPreparedOutbox) {
          await _markOutgoing(
            conversationId: conversationId,
            clientMessageId: clientMessageId,
            delivery: LocalMessageDelivery.blocked,
          );
          return (
            wire: null,
            blocked:
                'Cannot safely continue: prepared ciphertext was not persisted.',
          );
        }
        return (wire: ciphertext, blocked: null);
      } catch (error, stack) {
        if (error is MlsSendFailure) rethrow;
        span.total('send_encrypt_failed');
        // Encrypt threw after we entered encrypting. Fail closed: do not mint
        // another generation under this client_message_id.
        await _markOutgoing(
          conversationId: conversationId,
          clientMessageId: clientMessageId,
          delivery: LocalMessageDelivery.blocked,
        );
        MlsDiagnostics.record(stage: 'encrypt_application', error: error);
        throw MlsSendFailure(
          'encrypt_application',
          MlsDiagnostics.safeType(error),
          stack,
        );
      }
    });
  }

  Future<void> _persistOutgoing({
    required String conversationId,
    required String myUserId,
    required String clientMessageId,
    required String plaintext,
    required DateTime createdAt,
    required LocalMessageDelivery delivery,
  }) async {
    final stored = history;
    if (stored == null) {
      throw StateError('history unavailable');
    }
    final existing = await stored.lookupByClientMessageId(
      conversationId: conversationId,
      clientMessageId: clientMessageId,
    );
    if (existing != null) {
      if (existing.plaintext != plaintext || existing.senderId != myUserId) {
        throw const MessageHistoryConflictException();
      }
      if (existing.delivery == LocalMessageDelivery.sent ||
          existing.delivery == LocalMessageDelivery.received) {
        return;
      }
      if (existing.hasPreparedOutbox ||
          existing.delivery == LocalMessageDelivery.blocked ||
          existing.delivery == LocalMessageDelivery.uncertain ||
          existing.delivery == LocalMessageDelivery.ready ||
          existing.delivery == LocalMessageDelivery.failed ||
          existing.delivery == LocalMessageDelivery.submitting ||
          existing.delivery == LocalMessageDelivery.encrypting) {
        return;
      }
      await stored.markInboundState(
        conversationId: conversationId,
        clientMessageId: clientMessageId,
        delivery: delivery,
      );
      return;
    }
    await stored.insert(
      LocalMessageDraft(
        conversationId: conversationId,
        senderId: myUserId,
        clientMessageId: clientMessageId,
        createdAt: createdAt,
        delivery: delivery,
        plaintext: plaintext,
      ),
    );
  }

  Future<LocalMessageRecord?> _markOutgoing({
    required String conversationId,
    required String clientMessageId,
    LocalMessageDelivery? delivery,
    Object? envelopeId = keepHistoryField,
    Object? conversationSeq = keepHistoryField,
    Object? preparedCiphertext = keepHistoryField,
    Object? mlsGroupIdHex = keepHistoryField,
  }) async {
    final stored = history;
    if (stored == null) return null;
    try {
      return await stored.markInboundState(
        conversationId: conversationId,
        clientMessageId: clientMessageId,
        delivery: delivery,
        envelopeId: envelopeId,
        conversationSeq: conversationSeq,
        preparedCiphertext: preparedCiphertext,
        mlsGroupIdHex: mlsGroupIdHex,
      );
    } catch (error) {
      MlsDiagnostics.record(stage: 'send_history', error: error);
      return null;
    }
  }

  void bindConversationPeer(String conversationId, String peerUserId) {
    _peerByConversation[conversationId] = peerUserId;
  }

  Future<List<ChatMessageView>> ingestEnvelopes({
    required String token,
    required String myUserId,
    required List<MessageEnvelope> envelopes,
  }) {
    return _exclusive(() => _ingestEnvelopes(token: token, myUserId: myUserId, envelopes: envelopes));
  }

  Future<List<ChatMessageView>> _ingestEnvelopes({
    required String token,
    required String myUserId,
    required List<MessageEnvelope> envelopes,
  }) async {
    final svc = _crypto;
    if (svc == null) throw StateError('MLS not ready');

    final sorted = [...envelopes]..sort(compareEnvelopesForProcessing);
    final out = <ChatMessageView>[];
    final deferred = <MessageEnvelope>[];

    Future<void> processOne(MessageEnvelope env) async {
      if (_processedEnvelopeIds.contains(env.id)) return;
      if (_unresolvedEnvelopeIds.contains(env.id)) return;

      if (!_isAuthorizedSender(env, myUserId)) {
        // Do not decrypt or display — membership/sender check failed.
        return;
      }

      if (env.senderId == myUserId && _isLocalCopy(env.contentType)) {
        // Our own handshake was merged before it was uploaded. Do not join
        // it, do not process it, and do not acknowledge it: delivery rows
        // belong to the peer.
        _processedEnvelopeIds.add(env.id);
        return;
      }

      if (env.contentType == MlsContentTypes.welcome) {
        final String groupId;
        try {
          groupId = await svc.joinFromWelcome(welcomeBytes: env.ciphertext);
        } catch (error) {
          throw _MlsIngestSignal('welcome_join', error);
        }
        _groupByConversation[env.conversationId] = groupId;
        // Ack only after successful cryptographic processing (C4).
        await _acknowledge(token, env);
        return;
      }

      final groupId = _groupByConversation[env.conversationId];
      if (groupId == null) {
        deferred.add(env);
        return;
      }

      if (env.contentType == MlsContentTypes.commit ||
          env.contentType == MlsContentTypes.proposal) {
        // A Commit is created in epoch N and moves members to N+1. Welcome
        // already installs N+1, so that Commit's epoch is strictly older.
        // Epoch metadata is the only redundancy signal used here. A failure
        // we cannot classify stays unacknowledged for a later attempt.
        if (env.contentType == MlsContentTypes.commit &&
            await _commitEpochAlreadyPassed(svc, groupId, env)) {
          await _acknowledge(token, env);
          return;
        }
        try {
          await svc.processIncoming(
            groupIdHex: groupId,
            messageBytes: env.ciphertext,
          );
        } catch (error) {
          throw _MlsIngestSignal('commit_process', error);
        }
        await _acknowledge(token, env);
        return;
      }

      if (env.contentType == MlsContentTypes.callKeyBinding) {
        try {
          await _acceptCallBinding(
            token: token,
            svc: svc,
            env: env,
            groupId: groupId,
          );
        } catch (error) {
          if (error is _MlsIngestSignal) rethrow;
          throw _MlsIngestSignal('call_binding', error);
        }
        return;
      }

      if (env.contentType == MlsContentTypes.application) {
        await _ingestApplication(
          token: token,
          svc: svc,
          env: env,
          groupId: groupId,
          myUserId: myUserId,
          out: out,
        );
        return;
      }

      try {
        await svc.processIncoming(
          groupIdHex: groupId,
          messageBytes: env.ciphertext,
        );
      } catch (error) {
        throw _MlsIngestSignal('application_decrypt', error);
      }
      await _acknowledge(token, env);
    }

    Future<void> guarded(MessageEnvelope env) async {
      try {
        await processOne(env);
      } catch (error) {
        _noteIngestFailure(error, env);
      }
    }

    for (final env in sorted) {
      await guarded(env);
    }

    // After Welcome, retry envelopes that arrived before local join.
    if (deferred.isNotEmpty) {
      final pending = [...deferred]..sort(compareEnvelopesForProcessing);
      deferred.clear();
      for (final env in pending) {
        await guarded(env);
      }
    }
    return out;
  }

  /// Stored inbound messages for [conversationId], in history order.
  Future<List<ChatMessageView>> localTranscript({
    required String conversationId,
    required String myUserId,
  }) async {
    final stored = history;
    if (stored == null) return const [];
    final rows = await stored.listConversation(conversationId);
    return [
      for (final row in rows) _viewFromRecord(row, myUserId),
    ];
  }

  Future<void> _ingestApplication({
    required String token,
    required MlsGroupEncryptionService svc,
    required MessageEnvelope env,
    required String groupId,
    required String myUserId,
    required List<ChatMessageView> out,
  }) async {
    final stored = history;
    if (stored == null) {
      throw _MlsIngestSignal(
        'application_history',
        StateError('history unavailable'),
      );
    }

    final span = DeliveryTiming.start();
    final existing = await stored.lookupByEnvelopeId(env.id);
    if (existing != null &&
        (existing.conversationId != env.conversationId ||
            existing.clientMessageId != env.clientMessageId ||
            existing.senderId != env.senderId)) {
      throw _MlsIngestSignal(
        'application_history',
        StateError('history conflict'),
      );
    }

    if (existing?.mlsPhase == LocalMlsPhase.committed) {
      await _acknowledge(token, env);
      span.lap('inbound_ack_stored');
      final received = await _markApplication(
        stored,
        conversationId: existing!.conversationId,
        clientMessageId: existing.clientMessageId,
        delivery: LocalMessageDelivery.received,
      );
      span.lap('inbound_store_received');
      span.total('inbound_total');
      out.add(_viewFromRecord(received, myUserId));
      return;
    }

    if (existing == null) {
      final DecryptedApplicationMessage inspected;
      try {
        inspected = await svc.inspectApplication(
          groupIdHex: groupId,
          messageBytes: env.ciphertext,
        );
      } catch (error) {
        span.total('inbound_inspect_failed');
        throw _MlsIngestSignal('application_inspect', error);
      }
      span.lap('inbound_inspect');
      final String plaintext;
      try {
        plaintext = utf8.decode(inspected.plaintext);
      } on FormatException {
        throw _MlsIngestSignal(
          'application_inspect',
          StateError('plaintext is not text'),
        );
      }
      try {
        await stored.insert(
          LocalMessageDraft(
            conversationId: env.conversationId,
            senderId: env.senderId,
            clientMessageId: env.clientMessageId,
            envelopeId: env.id,
            conversationSeq: env.conversationSeq,
            createdAt: env.createdAt,
            delivery: LocalMessageDelivery.sent,
            plaintext: plaintext,
            mlsPhase: LocalMlsPhase.inspected,
          ),
        );
      } catch (error) {
        span.total('inbound_store_failed');
        throw _MlsIngestSignal('application_history', error);
      }
      span.lap('inbound_store_inspected');
    }

    final DecryptedApplicationMessage? decrypted;
    try {
      decrypted = await svc.processIncoming(
        groupIdHex: groupId,
        messageBytes: env.ciphertext,
      );
    } catch (error) {
      span.total('inbound_process_failed');
      throw _MlsIngestSignal('application_decrypt', error);
    }
    span.lap('inbound_process');
    if (decrypted == null) {
      throw _MlsIngestSignal(
        'application_decrypt',
        StateError('no plaintext'),
      );
    }

    final conversationId = existing?.conversationId ?? env.conversationId;
    final clientMessageId = existing?.clientMessageId ?? env.clientMessageId;
    await _markApplication(
      stored,
      conversationId: conversationId,
      clientMessageId: clientMessageId,
      mlsPhase: LocalMlsPhase.committed,
    );
    span.lap('inbound_store_committed');
    await _acknowledge(token, env);
    span.lap('inbound_ack');
    final received = await _markApplication(
      stored,
      conversationId: conversationId,
      clientMessageId: clientMessageId,
      delivery: LocalMessageDelivery.received,
    );
    span.lap('inbound_store_received');
    span.total('inbound_total');
    out.add(_viewFromRecord(received, myUserId));
  }

  Future<LocalMessageRecord> _markApplication(
    InboundMessageHistory stored, {
    required String conversationId,
    required String clientMessageId,
    LocalMlsPhase? mlsPhase,
    LocalMessageDelivery? delivery,
  }) async {
    try {
      return await stored.markInboundState(
        conversationId: conversationId,
        clientMessageId: clientMessageId,
        mlsPhase: mlsPhase,
        delivery: delivery,
      );
    } catch (error) {
      throw _MlsIngestSignal('application_history', error);
    }
  }

  ChatMessageView _viewFromRecord(LocalMessageRecord record, String myUserId) {
    final delivery = _chatDelivery(record);
    return ChatMessageView(
      clientMessageId: record.clientMessageId,
      serverEnvelopeId: record.envelopeId,
      senderId: record.senderId,
      plaintext: record.plaintext,
      createdAt: record.createdAt,
      delivery: delivery,
      isMine: record.senderId == myUserId,
      error: _recoveryError(delivery),
    );
  }

  String? _recoveryError(ChatDeliveryState delivery) {
    switch (delivery) {
      case ChatDeliveryState.uncertain:
        return 'Send unconfirmed. Resubmit only with the same ciphertext.';
      case ChatDeliveryState.blocked:
        return 'Cannot safely retry this message.';
      case ChatDeliveryState.failed:
        return 'Send failed';
      case ChatDeliveryState.sending:
      case ChatDeliveryState.sent:
      case ChatDeliveryState.received:
        return null;
    }
  }

  /// Maps durable outbox state to UI. Missing outbox bytes fail closed.
  ChatDeliveryState _chatDelivery(LocalMessageRecord record) {
    switch (record.delivery) {
      case LocalMessageDelivery.preparing:
      case LocalMessageDelivery.sending:
      case LocalMessageDelivery.encrypting:
        return record.hasPreparedOutbox
            ? ChatDeliveryState.sending
            : (record.delivery == LocalMessageDelivery.encrypting
                ? ChatDeliveryState.blocked
                : ChatDeliveryState.sending);
      case LocalMessageDelivery.ready:
        return record.hasPreparedOutbox
            ? ChatDeliveryState.failed
            : ChatDeliveryState.blocked;
      case LocalMessageDelivery.submitting:
        return record.hasPreparedOutbox
            ? ChatDeliveryState.uncertain
            : ChatDeliveryState.blocked;
      case LocalMessageDelivery.failed:
        return record.hasPreparedOutbox
            ? ChatDeliveryState.failed
            : ChatDeliveryState.blocked;
      case LocalMessageDelivery.uncertain:
        return record.hasPreparedOutbox
            ? ChatDeliveryState.uncertain
            : ChatDeliveryState.blocked;
      case LocalMessageDelivery.blocked:
        return ChatDeliveryState.blocked;
      case LocalMessageDelivery.sent:
        return ChatDeliveryState.sent;
      case LocalMessageDelivery.received:
        return ChatDeliveryState.received;
    }
  }

  Future<void> _acknowledge(String token, MessageEnvelope env) async {
    try {
      await api.acknowledgeEnvelope(token: token, envelopeId: env.id);
    } catch (error) {
      throw _MlsIngestSignal('acknowledge', error);
    }
    _processedEnvelopeIds.add(env.id);
  }

  /// True when [env] is a Commit created in an epoch this group has left.
  ///
  /// Returns false when either epoch cannot be read. Callers must not treat
  /// that as redundancy and must not match exception text.
  Future<bool> _commitEpochAlreadyPassed(
    MlsGroupEncryptionService svc,
    String groupId,
    MessageEnvelope env,
  ) async {
    final sentIn = svc.messageEpoch(messageBytes: env.ciphertext);
    if (sentIn == null) return false;
    final current = await svc.groupEpoch(groupIdHex: groupId);
    if (current == null) return false;
    return sentIn < current;
  }

  bool _isLocalCopy(String contentType) {
    switch (contentType) {
      case MlsContentTypes.application:
      case MlsContentTypes.callKeyBinding:
      case MlsContentTypes.welcome:
      case MlsContentTypes.commit:
      case MlsContentTypes.proposal:
        return true;
      default:
        return false;
    }
  }

  void _noteIngestFailure(Object error, MessageEnvelope env) {
    final stage = error is _MlsIngestSignal ? error.stage : 'ingest';
    final cause = error is _MlsIngestSignal ? error.cause : error;
    MlsDiagnostics.record(
      stage: stage,
      error: cause,
      contentType: env.contentType,
      conversationSeq: env.conversationSeq,
    );
    // Keep the server delivery. Remember the id so a realtime sync cannot
    // spin on the same failure; a new process can try again.
    if (stage != 'acknowledge') {
      _unresolvedEnvelopeIds.add(env.id);
    }
    if (_isSafetyWarning(keyChangeWarning)) return;
    keyChangeWarning = processingWarning;
  }

  bool _isSafetyWarning(String? value) {
    return value ==
            'Safety number changed for this contact. Verify before continuing.' ||
        value ==
            'Identity changed. Compare safety numbers before trusting this device.';
  }

  Future<void> _acceptCallBinding({
    required String token,
    required MlsGroupEncryptionService svc,
    required MessageEnvelope env,
    required String groupId,
  }) async {
    final box = inbox;
    if (box == null) {
      throw StateError('Call binding inbox is not configured');
    }
    if (await box.contains(env.id)) {
      await _acknowledge(token, env);
      return;
    }
    final held = _heldBindings.remove(env.id);
    final StoredCallBinding record;
    if (held != null) {
      record = held;
    } else {
      final decrypted = await svc.processIncoming(
        groupIdHex: groupId,
        messageBytes: env.ciphertext,
      );
      if (decrypted == null) {
        throw _MlsIngestSignal(
          'call_binding',
          StateError('no plaintext'),
        );
      }
      record = _bindingRecord(env, decrypted.plaintext);
    }
    try {
      await box.put(record);
    } catch (e) {
      _heldBindings[env.id] = record;
      rethrow;
    }
    await _acknowledge(token, env);
  }

  StoredCallBinding _bindingRecord(MessageEnvelope env, List<int> plain) {
    final rejected = StoredCallBinding(
      envelopeId: env.id,
      conversationId: env.conversationId,
      senderUserId: env.senderId.toLowerCase(),
      senderDeviceId: '',
      signature: const [],
      statement: const [],
      storedAt: DateTime.now().toUtc(),
      rejected: true,
    );
    if (plain.length <= 64) return rejected;
    final parsed = tryParseBindingStatement(plain.sublist(64));
    if (parsed == null) return rejected;
    if (parsed.userId != env.senderId.toLowerCase()) return rejected;
    return StoredCallBinding(
      envelopeId: env.id,
      conversationId: env.conversationId,
      senderUserId: parsed.userId,
      senderDeviceId: parsed.deviceId,
      signature: List<int>.from(plain.sublist(0, 64)),
      statement: List<int>.from(plain.sublist(64)),
      storedAt: DateTime.now().toUtc(),
      rejected: false,
    );
  }

  bool _isAuthorizedSender(MessageEnvelope env, String myUserId) {
    if (env.senderId == myUserId) return true;
    final peer = _peerByConversation[env.conversationId];
    if (peer != null) return env.senderId == peer;
    // Unknown conversation binding — refuse display until peer is bound.
    return false;
  }

  Future<void> _trackFingerprint(String peerUserId, String fingerprint, {String? deviceId}) async {
    if (deviceId != null) {
      try {
        await persistMessagingDevicePin(deviceId, fingerprint);
      } on IdentityPinConflict catch (e) {
        keyChangeWarning = e.message;
        return;
      }
    }
    final prior = _knownFingerprints[peerUserId];
    if (prior != null && prior != fingerprint) {
      keyChangeWarning =
          'Safety number changed for this contact. Verify before continuing.';
      return;
    }
    _knownFingerprints[peerUserId] = fingerprint;
  }
}
