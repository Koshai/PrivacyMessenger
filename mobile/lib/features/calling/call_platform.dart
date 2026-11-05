import 'package:flutter/services.dart';

/// Platform call UI. Payloads are a kind only: `incoming`, `ongoing`, or `ended`.
///
/// Notification text is fixed. No account id, device id, SDP, ICE, token, or key
/// is passed across this channel.
class CallPlatformBridge {
  CallPlatformBridge({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel('private_messenger/calls');

  static final instance = CallPlatformBridge();

  final MethodChannel _channel;

  static String bodyFor(String kind) => switch (kind) {
        'incoming' => 'Incoming call',
        'ongoing' => 'Call in progress',
        _ => '',
      };

  void bind({required void Function() onSystemEnded}) {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'systemEnded') onSystemEnded();
    });
  }

  Future<void> show(String kind) async {
    try {
      await _channel.invokeMethod<void>(kind);
    } on MissingPluginException {
      // Desktop tests and hosts without the mobile embedding.
    } on PlatformException {
      // A refused notification permission or an unavailable CallKit provider.
    }
  }
}
