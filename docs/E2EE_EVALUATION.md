# Milestone C — E2EE evaluation (pre-integration)

**Date:** 2026-11-03  
**Decision status:** Provisional candidate identified; **integration not started** pending licensing acceptance.

## Requirement reminder

Do not invent a cryptographic protocol. Prefer a maintained, independently reviewed implementation suitable for Flutter / Android / iOS. The Go backend must never receive plaintext message content or private keys.

## Candidates reviewed

### 1. `libsignal` on pub.dev (Dart bindings to Signal’s libsignal)

- **URL:** https://pub.dev/packages/libsignal  
- **Upstream crypto:** [signalapp/libsignal](https://github.com/signalapp/libsignal) (Rust Signal Protocol: X3DH / Double Ratchet; recent versions include PQXDH / Kyber material in upstream).  
- **Platforms claimed:** Android SDK 24+, iOS 13+, plus desktop/web WASM. Fits MVP mobile targets.  
- **Maintenance:** Active releases through 2026 (e.g. 9.0.0 aligning with libsignal v0.106.0).  
- **License:** **AGPL-3.0** for the Dart wrapper (confirm on pub.dev / GitHub before shipping). AGPL typically requires offering corresponding source for network-distributed modified versions — a **product/legal decision**, not only a technical one.  
- **Trust assumptions:** Correctness depends on upstream Signal protocol code plus the third-party Dart FFI bridge quality and store implementations we write (identity/prekey/session stores). Signal does not officially support third-party use of libsignal.  
- **Limitations:** Group/sealed-sender features exist in the library but must **not** expand MVP scope. Claiming “Signal-compatible,” forward secrecy, or post-compromise security is allowed only for properties the integrated stack actually provides **and** that we test.

### 2. Homemade AES / NaCl “E2EE”

- **Rejected.** Charter forbids substituting homemade cryptography.

### 3. Official Signal client libraries without a Dart bridge

- Native Android/iOS embedding of official artifacts is possible but would fork the Flutter architecture and is unsupported for third parties. Higher integration cost than the Dart wrapper for this codebase.

## Provisional selection

**Prefer `libsignal` (pub.dev) wrapping upstream Signal Protocol**, contingent on:

1. Explicit acceptance of **AGPL-3.0** obligations for PrivacyMessenger distribution, **or** an alternative maintained non-AGPL binding with equivalent protocol pedigree.  
2. Spike proving: identity key generation, secure private-key storage (`flutter_secure_storage`), prekey upload, two-device encrypt/decrypt, tamper rejection — on Android emulator at minimum.  
3. Server design that stores **opaque ciphertext envelopes only**.

If AGPL is unacceptable and no other trustworthy binding is available, **Milestone C stops** and reports a licensing blocker rather than shipping plaintext or DIY crypto.

## Planned server contract (after approval)

- Device registers public identity / signed prekeys / one-time prekeys.  
- Messages are encrypted envelopes: `{conversation_id, sender_device, ciphertext, message_id, sent_at}`.  
- Delivery, sync, and acks operate on envelopes; no plaintext columns.  
- Authenticated WebSocket only after persistence contracts exist.

## What we will not claim until proven in tests

- Interoperability with Signal Messenger clients  
- Specific FS / PCS guarantees beyond what automated tests demonstrate for our store wiring  
- Sealed sender anonymity against our own server metadata
