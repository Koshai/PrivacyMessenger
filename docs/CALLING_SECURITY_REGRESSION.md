# Calling security regression (D6)

A failed check ends the call or refuses authentication. None of these paths enable remote media.

| Case | Result | Where |
| --- | --- | --- |
| Forged hello | Passed. A hello signed for another call is rejected. | `call_auth_d41_test.dart` |
| Replayed hello | Passed. A repeated nonce is rejected. | `verifyPeerHello` |
| Replayed confirm | Passed. Server replay of the same client auth id returns the stored frame or `ErrReplay`. | `backend/internal/callauth` |
| Invalid MLS binding | Passed. Wrong device, wrong fingerprint, or bad signature fails. | `verifyCallKeyBinding` and the live test |
| Changed trusted fingerprint | Passed. The stored pin is kept and `IdentityPinConflict` is returned. | `call_d6_reliability_test.dart` |
| Unexpected device replacement | Passed. A different device id for the same user fails the binding check. | `verifyCallKeyBinding` `pinnedDeviceForUser` |
| Revoked identity | Passed. Enrollment false fails the session. A later recheck hangs up and disposes media. | session test and `recheckPeerIdentity` |
| Substituted SDP / hello | Passed. A valid hello for a different call is rejected before authentication. | session substitution test |
| Modified DTLS certificate | Passed. A changed remote fingerprint ends the call. | `onDtlsRestart` |
| Missing authenticator | Passed. The call hangs up and remote media stays unauthenticated. | controller test |
| Unavailable secure storage | Passed. The write error propagates. A corrupt pin is not replaced. | pin tests |
| Incorrect call participants | Passed. Hello user, device, and role must match the session. | `verifyPeerHello` |
| Expired authentication window | Passed. Submit after 90 seconds from accept/create returns `ErrInvalid`. | `TestAuthWindowExpired` |
| Missing enrollment callback | Passed. Outcome is `Enrollment check unavailable`. | session test |
| Server-substituted binding | Passed on two live clients. Bob decrypts Alice's MLS ciphertext, checks the envelope sender, and rejects the same bytes for Bob's device. Random ciphertext does not decrypt. | `live_two_client_e2e_test.dart` |

The server allow-lists `application/call-key-binding` so the ciphertext can be delivered. That allow-list does not decrypt or authorize the binding. `IsMLSApplication` stays false for this type, so it is not rendered as chat.
