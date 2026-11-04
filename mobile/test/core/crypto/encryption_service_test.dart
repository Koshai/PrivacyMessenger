import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/crypto/encryption_service.dart';

void main() {
  test('UnavailableEncryptionService refuses crypto operations', () async {
    const service = UnavailableEncryptionService();

    expect(service.isAvailable, isFalse);
    expect(service.backendId, 'unavailable');
    await expectLater(service.ensureIdentityKeys(), throwsUnsupportedError);
    await expectLater(
      service.encrypt(recipientUserId: 'u', plaintext: [1]),
      throwsUnsupportedError,
    );
  });

  test('OpenMLS backend id is distinct from unavailable stub', () {
    expect(const UnavailableEncryptionService().backendId, isNot('openmls-3.3.0'));
  });
}
