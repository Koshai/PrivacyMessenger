import 'call_auth.dart';
import 'call_controller.dart';
import 'models/call_session.dart';

/// Plain-language call chrome. No MLS/DTLS/ICE jargon.
class CallStatusCopy {
  const CallStatusCopy({
    required this.title,
    this.subtitle,
  });

  final String title;
  final String? subtitle;
}

CallStatusCopy callStatusCopy(CallController controller) {
  switch (controller.phase) {
    case CallPhase.outgoingRinging:
      return const CallStatusCopy(title: 'Calling…');
    case CallPhase.incomingRinging:
      return const CallStatusCopy(title: 'Incoming call');
    case CallPhase.connecting:
      return const CallStatusCopy(
        title: 'Connecting…',
        subtitle: 'Setting up the call',
      );
    case CallPhase.connected:
      return _connectedCopy(controller);
    case CallPhase.failed:
      return CallStatusCopy(
        title: 'Unable to connect',
        subtitle: callUserFacingError(controller),
      );
    case CallPhase.ended:
      return CallStatusCopy(
        title: 'Call ended',
        subtitle: callUserFacingError(controller),
      );
    case CallPhase.idle:
      return const CallStatusCopy(title: 'Call');
  }
}

CallStatusCopy _connectedCopy(CallController controller) {
  switch (controller.authPhase) {
    case CallAuthPhase.verifying:
    case CallAuthPhase.awaitingPeer:
      return const CallStatusCopy(
        title: 'Securing call…',
        subtitle: 'Verifying the other device before showing media',
      );
    case CallAuthPhase.identityChanged:
      return const CallStatusCopy(
        title: 'Identity changed',
        subtitle:
            'Safety number changed. This call was ended. Compare fingerprints '
            'before trusting a new device.',
      );
    case CallAuthPhase.failed:
      return const CallStatusCopy(
        title: 'Verification failed',
        subtitle: 'Couldn’t verify the other device. The call ended for your safety.',
      );
    case CallAuthPhase.authenticated:
      final quality = _qualityLine(controller.linkQuality);
      final duration = _formatDuration(controller.duration);
      if (controller.peerManuallyVerified) {
        return CallStatusCopy(
          title: 'Verified contact',
          subtitle: '$duration · $quality',
        );
      }
      return CallStatusCopy(
        title: duration,
        subtitle: '$quality · Device authenticated',
      );
    default:
      return CallStatusCopy(
        title: 'Connecting…',
        subtitle: _qualityLine(controller.linkQuality),
      );
  }
}

String _qualityLine(String linkQuality) {
  return switch (linkQuality) {
    'good' => 'Connection good',
    'poor' => 'Connection unstable',
    'lost' => 'Connection lost',
    _ => 'Waiting for media',
  };
}

String _formatDuration(Duration d) {
  final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
  final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return '$m:$s';
}

/// Maps controller errors to user-safe text. Returns null when none.
String? callUserFacingError(CallController controller) {
  final raw = controller.error;
  if (raw == null || raw.trim().isEmpty) return null;
  final e = raw.toLowerCase();
  if (e.contains('permission')) {
    return controller.lastRequestedMediaType == CallMediaType.video
        ? 'Microphone and camera access are required for video calls.'
        : 'Microphone access is required for calls.';
  }
  if (e.contains('identity revoked')) {
    return 'The other device is no longer trusted. The call ended.';
  }
  if (e.contains('verification') ||
      e.contains('authentication') ||
      e.contains('auth_') ||
      e.contains('missing_authenticator')) {
    return 'Couldn’t verify the other device. The call ended for your safety.';
  }
  if (e.contains('dtls') || e.contains('fingerprint')) {
    return 'The call couldn’t be secured. Please try again.';
  }
  if (e.contains('ring') || e.contains('timeout') || e.contains('no answer')) {
    return 'No answer. Try again later.';
  }
  if (e.contains('connection') ||
      e.contains('ice') ||
      e.contains('disconnect') ||
      e.contains('network') ||
      e.contains('unreachable')) {
    return 'Couldn’t connect. Check your internet connection and try again.';
  }
  if (e.contains('stateerror') ||
      e.contains('peer hello') ||
      e.contains('sdp') ||
      e.contains('offer') ||
      e.contains('candidate')) {
    return 'Unable to complete the call. Please try again.';
  }
  // Never surface raw exception text to ordinary users.
  return 'Unable to complete the call.';
}

bool isCallPermissionFailure(CallController controller) =>
    controller.permissionFailure ||
    (controller.error?.toLowerCase().contains('permission') ?? false);
