import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../core/ui/app_confirm_dialog.dart';
import '../messaging/safety_number_screen.dart';
import 'call_auth.dart';
import 'call_controller.dart';
import 'call_user_copy.dart';
import 'models/call_session.dart';

/// Full-screen call UI driven by [CallController] (no WebRTC ops here).
class ActiveCallScreen extends StatefulWidget {
  const ActiveCallScreen({super.key, required this.controller});

  final CallController controller;

  @override
  State<ActiveCallScreen> createState() => _ActiveCallScreenState();
}

class _ActiveCallScreenState extends State<ActiveCallScreen> {
  bool _handlingBack = false;

  CallController get controller => widget.controller;

  bool get _isTerminal =>
      controller.phase == CallPhase.ended ||
      controller.phase == CallPhase.failed;

  bool get _needsHangUpConfirm =>
      controller.phase == CallPhase.connecting ||
      controller.phase == CallPhase.connected;

  Future<void> _onSystemBack() async {
    if (_handlingBack) return;
    _handlingBack = true;
    try {
      final phase = controller.phase;
      if (phase == CallPhase.idle) return;
      if (phase == CallPhase.incomingRinging) {
        await controller.declineIncoming();
        return;
      }
      if (phase == CallPhase.outgoingRinging) {
        await controller.cancelOutgoing();
        return;
      }
      if (_isTerminal) {
        controller.dismissFailedCall();
        return;
      }
      if (_needsHangUpConfirm) {
        final confirmed = await showAppConfirmDialog(
          context: context,
          title: 'End call?',
          message: 'This will hang up the current call.',
          cancelLabel: 'Stay on call',
          confirmLabel: 'Hang up',
          isDestructive: true,
        );
        if (!confirmed || !mounted) return;
        await controller.hangUp(reason: 'system_back');
        return;
      }
      await controller.hangUp(reason: 'system_back');
    } finally {
      _handlingBack = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final session = controller.session;
        final video = session?.mediaType == CallMediaType.video;
        final copy = callStatusCopy(controller);
        final permissionFail = isCallPermissionFailure(controller);

        return PopScope(
          canPop: false,
          onPopInvokedWithResult: (didPop, _) async {
            if (didPop) return;
            await _onSystemBack();
          },
          child: Scaffold(
            backgroundColor: Colors.black87,
            body: SafeArea(
              child: Stack(
                children: [
                  if (video)
                    ..._videoLayers(controller)
                  else
                    const Center(
                      child: Icon(Icons.person, size: 96, color: Colors.white70),
                    ),
                  Positioned(
                    left: 16,
                    right: 16,
                    top: 8,
                    child: _CallStatusHeader(
                      title: copy.title,
                      subtitle: copy.subtitle,
                    ),
                  ),
                  Positioned(
                    left: 24,
                    right: 24,
                    bottom: 140,
                    child: _AuthFooter(controller: controller),
                  ),
                  if (_isTerminal &&
                      (permissionFail ||
                          callUserFacingError(controller) != null ||
                          controller.phase == CallPhase.ended))
                    Positioned(
                      left: 24,
                      right: 24,
                      bottom: 220,
                      child: _ErrorRecovery(
                        message: callUserFacingError(controller) ??
                            (controller.phase == CallPhase.ended
                                ? 'Returning to your chats…'
                                : 'Unable to complete the call.'),
                        showOpenSettings: permissionFail,
                        showDismiss: true,
                        onDismiss: controller.dismissFailedCall,
                      ),
                    ),
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 48,
                    child: Padding(
                      padding: const EdgeInsets.only(bottom: 24),
                      child: _CallControls(controller: controller),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  List<Widget> _videoLayers(CallController controller) {
    final showRemote = controller.remoteMediaAuthenticated;
    final showLocal =
        controller.cameraEnabled && controller.phase != CallPhase.ended;

    return [
      Positioned.fill(
        child: showRemote
            ? _VideoPane(
                renderer: controller.media.remoteRenderer,
                mirror: false,
                placeholder: 'Waiting for their video…',
              )
            : const ColoredBox(
                color: Colors.black,
                child: Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Text(
                      'Securing call before showing video',
                      style: TextStyle(color: Colors.white70),
                      textAlign: TextAlign.center,
                    ),
                  ),
                ),
              ),
      ),
      if (showLocal)
        Positioned(
          right: 16,
          top: 72,
          width: 112,
          height: 150,
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.white24),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(11),
              child: _VideoPane(
                renderer: controller.media.localRenderer,
                mirror: true,
                placeholder: 'You',
              ),
            ),
          ),
        )
      else if (controller.session?.mediaType == CallMediaType.video &&
          !controller.cameraEnabled &&
          controller.phase != CallPhase.ended)
        Positioned(
          right: 16,
          top: 72,
          width: 112,
          height: 150,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: Colors.black54,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.white24),
            ),
            child: const Center(
              child: Text(
                'No preview',
                style: TextStyle(color: Colors.white70, fontSize: 12),
                textAlign: TextAlign.center,
              ),
            ),
          ),
        ),
    ];
  }

}

class _CallStatusHeader extends StatelessWidget {
  const _CallStatusHeader({required this.title, this.subtitle});

  final String title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black45,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              title,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.w600,
              ),
              textAlign: TextAlign.center,
            ),
            if (subtitle != null && subtitle!.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                subtitle!,
                style: const TextStyle(color: Colors.white70, fontSize: 13),
                textAlign: TextAlign.center,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _AuthFooter extends StatelessWidget {
  const _AuthFooter({required this.controller});
  final CallController controller;

  @override
  Widget build(BuildContext context) {
    if (controller.authPhase == CallAuthPhase.identityChanged) {
      return const Text(
        'Safety number changed. Compare fingerprints before trusting a new device.',
        textAlign: TextAlign.center,
        style: TextStyle(color: Colors.white70),
      );
    }
    if (controller.authPhase != CallAuthPhase.authenticated) {
      return const SizedBox.shrink();
    }
    final peerHex = controller.peerFingerprintHex;
    return Column(
      children: [
        Text(
          controller.peerManuallyVerified
              ? 'Safety number verified by you'
              : 'Call secured. Safety number not compared yet.',
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.white70),
        ),
        if (peerHex != null && peerHex.isNotEmpty)
          TextButton(
            onPressed: () {
              final session = controller.session;
              final peerId = session?.callerUserId == controller.myUserId
                  ? session?.calleeUserId
                  : session?.callerUserId;
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => SafetyNumberScreen(
                    peerEmail: peerId ?? 'peer',
                    peerFingerprintHex: peerHex,
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
    );
  }
}

class _ErrorRecovery extends StatelessWidget {
  const _ErrorRecovery({
    required this.message,
    required this.showOpenSettings,
    required this.showDismiss,
    required this.onDismiss,
  });

  final String message;
  final bool showOpenSettings;
  final bool showDismiss;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black54,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              message,
              style: const TextStyle(color: Colors.orangeAccent),
              textAlign: TextAlign.center,
            ),
            if (showOpenSettings) ...[
              const SizedBox(height: 8),
              TextButton(
                onPressed: openAppSettings,
                child: const Text('Open settings'),
              ),
            ],
            if (showDismiss)
              TextButton(
                onPressed: onDismiss,
                child: const Text('Close'),
              ),
          ],
        ),
      ),
    );
  }
}

class _VideoPane extends StatelessWidget {
  const _VideoPane({
    required this.renderer,
    required this.mirror,
    required this.placeholder,
  });

  final Object? renderer;
  final bool mirror;
  final String placeholder;

  @override
  Widget build(BuildContext context) {
    if (renderer is RTCVideoRenderer) {
      return RTCVideoView(
        renderer as RTCVideoRenderer,
        mirror: mirror,
        objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
      );
    }
    return ColoredBox(
      color: Colors.black26,
      child: Center(
        child: Text(
          placeholder,
          style: const TextStyle(color: Colors.white54, fontSize: 12),
          textAlign: TextAlign.center,
        ),
      ),
    );
  }
}

class _CallControls extends StatelessWidget {
  const _CallControls({required this.controller});
  final CallController controller;

  @override
  Widget build(BuildContext context) {
    final phase = controller.phase;
    if (phase == CallPhase.ended || phase == CallPhase.failed) {
      return const SizedBox.shrink();
    }
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
            label: controller.speakerOn ? 'Speaker on' : 'Speaker',
            onPressed: controller.toggleSpeaker,
          ),
          if (controller.session?.mediaType == CallMediaType.video) ...[
            _RoundButton(
              icon: controller.cameraEnabled
                  ? Icons.videocam
                  : Icons.videocam_off,
              color: Colors.white24,
              label: controller.cameraEnabled ? 'Camera on' : 'Camera off',
              onPressed: controller.toggleCamera,
            ),
            _RoundButton(
              icon: Icons.cameraswitch,
              color: Colors.white24,
              label: 'Flip camera',
              onPressed: controller.cameraEnabled
                  ? controller.switchCamera
                  : null,
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
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: label,
      enabled: onPressed != null,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Material(
            color: color,
            shape: const CircleBorder(),
            child: IconButton(
              iconSize: 32,
              color: Colors.white,
              icon: Icon(icon, semanticLabel: label),
              tooltip: label,
              onPressed: onPressed,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            label,
            style: TextStyle(
              color: onPressed == null ? Colors.white38 : Colors.white70,
              fontSize: 12,
            ),
          ),
        ],
      ),
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
  OverlayEntry? _callOverlay;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.controller.addListener(_syncCallOverlay);
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncCallOverlay());
  }

  @override
  void didUpdateWidget(covariant CallHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_syncCallOverlay);
      widget.controller.addListener(_syncCallOverlay);
      _syncCallOverlay();
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_syncCallOverlay);
    WidgetsBinding.instance.removeObserver(this);
    _removeCallOverlay();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    unawaited(widget.controller.onAppLifecycle(state));
  }

  void _syncCallOverlay() {
    if (!mounted) return;
    final active = widget.controller.phase != CallPhase.idle;
    if (!active) {
      _removeCallOverlay();
      return;
    }
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) return;
    if (_callOverlay == null) {
      _callOverlay = OverlayEntry(
        builder: (context) => ActiveCallScreen(controller: widget.controller),
      );
      overlay.insert(_callOverlay!);
    } else {
      _callOverlay!.markNeedsBuild();
    }
  }

  void _removeCallOverlay() {
    _callOverlay?.remove();
    _callOverlay = null;
  }

  @override
  Widget build(BuildContext context) {
    // Call UI is inserted on the root Overlay so it covers Navigator.push
    // conversation routes. A local Stack sits under those routes and cannot.
    return widget.child;
  }
}
