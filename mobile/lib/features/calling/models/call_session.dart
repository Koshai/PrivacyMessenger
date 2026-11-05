enum CallMediaType { audio, video }

enum CallRemoteState {
  ringing,
  accepted,
  connected,
  ended,
}

class CallSession {
  const CallSession({
    required this.id,
    required this.callerUserId,
    required this.calleeUserId,
    required this.callerDeviceId,
    required this.mediaType,
    required this.state,
    required this.clientCallId,
    required this.ringExpiresAt,
    required this.createdAt,
    required this.updatedAt,
    required this.version,
    this.calleeDeviceId,
    this.endReason,
    this.sdpOffer,
    this.sdpAnswer,
    this.acceptedAt,
    this.endedAt,
  });

  final String id;
  final String callerUserId;
  final String calleeUserId;
  final String callerDeviceId;
  final String? calleeDeviceId;
  final CallMediaType mediaType;
  final CallRemoteState state;
  final String? endReason;
  final String clientCallId;
  final String? sdpOffer;
  final String? sdpAnswer;
  final DateTime ringExpiresAt;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? acceptedAt;
  final DateTime? endedAt;
  final int version;

  bool get isEnded => state == CallRemoteState.ended;

  factory CallSession.fromJson(Map<String, dynamic> json) {
    final media = json['media_type'] as String? ?? 'audio';
    final stateRaw = json['state'] as String? ?? 'ended';
    return CallSession(
      id: json['id'] as String,
      callerUserId: json['caller_user_id'] as String,
      calleeUserId: json['callee_user_id'] as String,
      callerDeviceId: json['caller_device_id'] as String,
      calleeDeviceId: json['callee_device_id'] as String?,
      mediaType: media == 'video' ? CallMediaType.video : CallMediaType.audio,
      state: switch (stateRaw) {
        'ringing' => CallRemoteState.ringing,
        'accepted' => CallRemoteState.accepted,
        'connected' => CallRemoteState.connected,
        _ => CallRemoteState.ended,
      },
      endReason: json['end_reason'] as String?,
      clientCallId: json['client_call_id'] as String,
      sdpOffer: json['sdp_offer'] as String?,
      sdpAnswer: json['sdp_answer'] as String?,
      ringExpiresAt: DateTime.parse(json['ring_expires_at'] as String).toUtc(),
      createdAt: DateTime.parse(json['created_at'] as String).toUtc(),
      updatedAt: DateTime.parse(json['updated_at'] as String).toUtc(),
      acceptedAt: json['accepted_at'] == null
          ? null
          : DateTime.parse(json['accepted_at'] as String).toUtc(),
      endedAt: json['ended_at'] == null
          ? null
          : DateTime.parse(json['ended_at'] as String).toUtc(),
      version: (json['version'] as num?)?.toInt() ?? 0,
    );
  }
}

class IceCandidateDto {
  const IceCandidateDto({
    required this.seq,
    required this.candidate,
    required this.clientIceId,
    this.sdpMid,
    this.sdpMLineIndex,
  });

  final int seq;
  final String candidate;
  final String clientIceId;
  final String? sdpMid;
  final int? sdpMLineIndex;

  factory IceCandidateDto.fromJson(Map<String, dynamic> json) {
    return IceCandidateDto(
      seq: (json['seq'] as num).toInt(),
      candidate: json['candidate'] as String,
      clientIceId: json['client_ice_id'] as String,
      sdpMid: json['sdp_mid'] as String?,
      sdpMLineIndex: (json['sdp_mline_index'] as num?)?.toInt(),
    );
  }
}
