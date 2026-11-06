# Calling known limitations

These are product and engineering constraints for the current MVP. They are not undocumented behavior.

## Terminated-app incoming calls

The MVP does not deliver an incoming call when the app process is not running. There is no PushKit client, no VoIP push entitlement, and no claim of reliable background ringing after the process has been killed. A notification or CallKit report exists only while the process is alive. This is an accepted constraint for the initial release. It is not parity with WhatsApp or Signal.

Locked-screen incoming-call behavior has not been demonstrated.

## Identity and bindings

Contact pins are keyed by device id and are kept across logout. Logout deletes this device's call-signing seed and the call-binding inbox. A crash in the moment after OpenMLS consumes a binding and before the inbox write loses that binding; the call then fails closed. The inbox keeps at most eight bindings for three minutes. That crash window was not changed during hosted-deployment preparation.

Enrollment presence still comes from the server's device list. The signature, the pinned fingerprint, and the DTLS fingerprint are checked on the device. A timeout or a failed enrollment request does not by itself end a call that already authenticated. A `false` enrollment result does.

The call-binding inbox selects the newest usable record for a sender account and device. It does not also match a call id. A newer binding from the same device can therefore be the one offered to a different call, and that call fails closed when the statement does not match. This lookup was not changed during hosted-deployment preparation.

## Media and TURN

Direct and relay media still depend on WebRTC DTLS-SRTP. The app does not add a second media encryption layer.

The CI relay test uses coturn on loopback. The hosted validation Compose file prepares a public coturn listener, and that external relay has not been executed. DNS, firewall rules, cross-network clients, and VPS capacity are unverified. Relay metadata remains visible to the TURN operator. TURN over TLS is not enabled in the validation config.

## Platforms

Physical Android calling UX and physical iPhone CallKit behavior are unverified. Android emulator attachment is not a substitute for those checks.
