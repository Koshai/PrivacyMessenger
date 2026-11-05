import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../messaging/safety_number_screen.dart';
import 'call_auth.dart';
import 'call_controller.dart';
import 'models/call_session.dart';

/// Full-screen call UI driven by [CallController] (no WebRTC ops here).
class ActiveCallScreen extends StatelessWidget {
  const ActiveCallScreen({super.key, required this.controller});

  final CallController controller;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final session = controller.session;
        final video = session?.mediaType == CallMediaType.video;
        final title = switch (controller.phase) {
          CallPhase.outgoingRinging => 'Calling…',
          CallPhase.incomingRinging => 'Incoming call',
          CallPhase.connecting => 'Connecting…',
          CallPhase.connected => switch (controller.authPhase) {
              CallAuthPhase.verifying || CallAuthPhase.awaitingPeer => 'Verifying identity…',
              CallAuthPhase.identityChanged => 'Identity changed',
              CallAuthPhase.failed => 'Verification failed',
              CallAuthPhase.authenticated when controller.peerManuallyVerified =>
                'Verified contact',
              CallAuthPhase.authenticated => 'Authenticated device',
              _ => _formatDuration(controller.duration),
            },
          CallPhase.failed => 'Call failed',
          CallPhase.ended => 'Call ended',
          CallPhase.idle => 'Call',
        };

        return Scaffold(
          backgroundColor: Colors.black87,
          body: SafeArea(
            child: Stack(
              children: [
                if (video && controller.remoteMediaAuthenticated) ...[
                  Positioned.fill(
                    child: _VideoPane(renderer: controller.media.remoteRenderer),
                  ),
                ] else if (video) ...[
                  const Positioned.fill(
                    child: ColoredBox(
                      color: Colors.black,
                      child: Center(
                        child: Text(
                          'Verifying peer before showing video',
                          style: TextStyle(color: Colors.white70),
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    right: 16,
                    top: 16,
                    width: 120,
                    height: 160,
                    child: _VideoPane(renderer: controller.media.localRenderer),
                  ),
                ] else
                  Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.person, size: 96, color: Colors.white70),
                        const SizedBox(height: 16),
                        Text(
                          title,
                          style: const TextStyle(color: Colors.white, fontSize: 22),
                        ),
                        if (controller.error != null)
                          Padding(
                            padding: const EdgeInsets.all(16),
                            child: Text(
                              controller.error!,
                              style: const TextStyle(color: Colors.orangeAccent),
                              textAlign: TextAlign.center,
                            ),
                          ),
                      ],
                    ),
                  ),
                Positioned(
                  left: 24,
                  right: 24,
                  bottom: 140,
                  child: Column(
                    children: [
                      Text(
                        controller.authPhase == CallAuthPhase.identityChanged
                            ? 'Safety number changed. This call was ended. Compare fingerprints before trusting a new device.'
                            : controller.peerManuallyVerified
                                ? 'Safety number verified'
                                : controller.authPhase == CallAuthPhase.authenticated
                                    ? 'Authenticated device ${controller.peerFingerprintHex ?? ''}. Safety number not compared yet.'
                                    : '',
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Colors.white70),
                      ),
                      if (controller.authPhase == CallAuthPhase.authenticated &&
                          controller.peerFingerprintHex != null)
                        TextButton(
                          onPressed: () {
                            final peerId = session?.callerUserId == controller.myUserId
                                ? session?.calleeUserId
                                : session?.callerUserId;
                            Navigator.of(context).push(
                              MaterialPageRoute<void>(
                                builder: (_) => SafetyNumberScreen(
                                  peerEmail: peerId ?? 'peer',
                                  peerFingerprintHex: controller.peerFingerprintHex!,
                                  localFingerprintHex:
                                      controller.localSafetyFingerprintHex ?? '',
                                  initialTrust: controller.peerManuallyVerified
                                      ? SafetyTrustState.verified
                                      : SafetyTrustState.unverified,
                                  onTrustChanged: (state) {
                                    if (state == SafetyTrustState.verified) {
                                      controller.markSafetyNumberVerified();
                                    }
                                  },
                                ),
                              ),
                            );
                          },
                          child: const Text('Compare safety number'),
                        ),
                    ],
                  ),
                ),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 32,
                  child: _CallControls(controller: controller),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  static String _formatDuration(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }
}

class _VideoPane extends StatelessWidget {
  const _VideoPane({required this.renderer});
  final Object? renderer;

  @override
  Widget build(BuildContext context) {
    if (renderer is RTCVideoRenderer) {
      return RTCVideoView(renderer as RTCVideoRenderer, mirror: true);
    }
    return const ColoredBox(color: Colors.black26);
  }
}

class _CallControls extends StatelessWidget {
  const _CallControls({required this.controller});
  final CallController controller;

  @override
  Widget build(BuildContext context) {
    final phase = controller.phase;
    return Wrap(
      alignment: WrapAlignment.center,
      spacing: 16,
      runSpacing: 12,
      children: [
        if (phase == CallPhase.incomingRinging) ...[
          _RoundButton(
            icon: Icons.call_end,
            color: Colors.red,
            label: 'Decline',
            onPressed: controller.declineIncoming,
          ),
          _RoundButton(
            icon: Icons.call,
            color: Colors.green,
            label: 'Accept',
            onPressed: controller.acceptIncoming,
          ),
        ] else if (phase == CallPhase.outgoingRinging) ...[
          _RoundButton(
            icon: Icons.call_end,
            color: Colors.red,
            label: 'Cancel',
            onPressed: controller.cancelOutgoing,
          ),
        ] else ...[
          _RoundButton(
            icon: controller.micMuted ? Icons.mic_off : Icons.mic,
            color: Colors.white24,
            label: controller.micMuted ? 'Unmute' : 'Mute',
            onPressed: controller.toggleMute,
          ),
          _RoundButton(
            icon: controller.speakerOn ? Icons.volume_up : Icons.hearing,
            color: Colors.white24,
            label: 'Speaker',
            onPressed: controller.toggleSpeaker,
          ),
          if (controller.session?.mediaType == CallMediaType.video) ...[
            _RoundButton(
              icon: controller.cameraEnabled ? Icons.videocam : Icons.videocam_off,
              color: Colors.white24,
              label: 'Camera',
              onPressed: controller.toggleCamera,
            ),
            _RoundButton(
              icon: Icons.cameraswitch,
              color: Colors.white24,
              label: 'Flip',
              onPressed: controller.switchCamera,
            ),
          ],
          _RoundButton(
            icon: Icons.call_end,
            color: Colors.red,
            label: 'Hang up',
            onPressed: controller.hangUp,
          ),
        ],
      ],
    );
  }
}

class _RoundButton extends StatelessWidget {
  const _RoundButton({
    required this.icon,
    required this.color,
    required this.label,
    required this.onPressed,
  });

  final IconData icon;
  final Color color;
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Material(
          color: color,
          shape: const CircleBorder(),
          child: IconButton(
            iconSize: 32,
            color: Colors.white,
            icon: Icon(icon),
            tooltip: label,
            onPressed: onPressed,
          ),
        ),
        const SizedBox(height: 4),
        Text(label, style: const TextStyle(color: Colors.white70, fontSize: 12)),
      ],
    );
  }
}

/// Hosts call UI over the authenticated shell when a call is active.
class CallHost extends StatefulWidget {
  const CallHost({super.key, required this.controller, required this.child});

  final CallController controller;
  final Widget child;

  @override
  State<CallHost> createState() => _CallHostState();
}

class _CallHostState extends State<CallHost> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    unawaited(widget.controller.onAppLifecycle(state));
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) {
        final active = widget.controller.phase != CallPhase.idle;
        return Stack(
          children: [
            widget.child,
            if (active)
              Positioned.fill(child: ActiveCallScreen(controller: widget.controller)),
          ],
        );
      },
    );
  }
}
