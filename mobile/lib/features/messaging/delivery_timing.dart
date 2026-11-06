import 'package:flutter/foundation.dart';

/// Monotonic stage durations for delivery investigation.
///
/// Records a stage name and elapsed milliseconds only. Callers must not pass
/// plaintext, keys, ciphertext, tokens, or message identifiers.
class DeliveryTiming {
  static const int _maxEvents = 80;
  static final List<DeliveryTimingEvent> events = [];

  static void reset() => events.clear();

  static DeliverySpan start() => DeliverySpan();

  static void record(String stage, int elapsedMs, {String? detail}) {
    final event = DeliveryTimingEvent(
      stage: _label(stage),
      elapsedMs: elapsedMs < 0 ? 0 : elapsedMs,
      detail: detail == null ? null : _label(detail),
    );
    events.add(event);
    if (events.length > _maxEvents) events.removeAt(0);
    if (!kDebugMode) return;
    final suffix = event.detail == null ? '' : ' detail=${event.detail}';
    debugPrint('DeliveryTiming stage=${event.stage} ms=${event.elapsedMs}$suffix');
  }

  static String _label(String value) {
    if (RegExp(r'^[A-Za-z0-9_./+-]{1,40}$').hasMatch(value)) return value;
    return 'redacted';
  }
}

class DeliverySpan {
  final Stopwatch _watch = Stopwatch()..start();
  int _last = 0;

  int get elapsedMilliseconds => _watch.elapsedMilliseconds;

  void lap(String stage) {
    final now = _watch.elapsedMilliseconds;
    DeliveryTiming.record(stage, now - _last);
    _last = now;
  }

  void total(String stage) {
    DeliveryTiming.record(stage, _watch.elapsedMilliseconds);
  }
}

class DeliveryTimingEvent {
  const DeliveryTimingEvent({
    required this.stage,
    required this.elapsedMs,
    this.detail,
  });

  final String stage;
  final int elapsedMs;
  final String? detail;

  @override
  String toString() {
    final suffix = detail == null ? '' : ' detail=$detail';
    return 'DeliveryTiming(stage=$stage, ms=$elapsedMs$suffix)';
  }
}
