import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/features/calling/webrtc_call_service.dart';

void main() {
  test('sanitizeCallSdp strips Plan-B ssrc msid lines and normalizes CRLF', () {
    const raw = 'v=0\n'
        'o=- 1 1 IN IP4 127.0.0.1\n'
        's=-\n'
        't=0 0\n'
        'm=audio 9 UDP/TLS/RTP/SAVPF 111\n'
        'a=msid:3cd4f58e-0943-412c-86a0-6c48c3c03946 91151a13-5ed2-4c33-aefa-4f39e91650a6\n'
        'a=ssrc:1054884035 cname:uzBa2oH+/8z9+4Aq\n'
        'a=ssrc:1054884035 msid:3cd4f58e-0943-412c-86a0-6c48c3c03946 91151a13-5ed2-4c33-aefa-4f39e91650a6\n'
        'a=ssrc:1054884035 mslabel:3cd4f58e-0943-412c-86a0-6c48c3c03946\n'
        'a=ssrc:1054884035 label:91151a13-5ed2-4c33-aefa-4f39e91650a6\n'
        'a=sendrecv\n';

    final cleaned = sanitizeCallSdp(raw);

    expect(cleaned.contains('a=ssrc:1054884035 msid:'), isFalse);
    expect(cleaned.contains('a=ssrc:1054884035 mslabel:'), isFalse);
    expect(cleaned.contains('a=ssrc:1054884035 label:'), isFalse);
    expect(
      cleaned.contains(
        'a=msid:3cd4f58e-0943-412c-86a0-6c48c3c03946 91151a13-5ed2-4c33-aefa-4f39e91650a6',
      ),
      isTrue,
    );
    expect(cleaned.contains('a=ssrc:1054884035 cname:uzBa2oH+/8z9+4Aq'), isTrue);
    expect(cleaned.contains('\r\n'), isTrue);
    expect(cleaned.endsWith('\r\n'), isTrue);
  });

  test('sanitizeCallSdp leaves empty input unchanged', () {
    expect(sanitizeCallSdp(''), '');
  });
}
