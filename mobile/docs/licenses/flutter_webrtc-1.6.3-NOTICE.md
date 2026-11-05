# flutter_webrtc 1.6.3 — license notice

| Item | Value |
| --- | --- |
| Package | [`flutter_webrtc`](https://pub.dev/packages/flutter_webrtc) |
| Pinned version | **1.6.3** |
| Package license | **MIT** |
| Native media stack | Google WebRTC (via flutter-webrtc / libwebrtc) |

## Compatibility

MIT is compatible with proprietary PrivacyMessenger distribution of this app binary, subject to retaining copyright and license notices for the dependency.

## Native dependency notes

- Android / iOS / desktop / web plugins ship with flutter_webrtc.
- Platform WebRTC binaries follow upstream WebRTC licensing (BSD-style / additional patents notices as published by the WebRTC project).
- `permission_handler` (separate package) is used for mic/camera prompts; its license is MIT.

## App policy

- Microphone and camera are requested only after explicit user action (start or accept call).
- Camera is not activated before call initiation or acceptance.
- D3 will add injectable TURN configuration; this pin does not claim production NAT traversal.

Full MIT text is included in the pub cache package `LICENSE` for flutter_webrtc 1.6.3.
