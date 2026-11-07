# Outgoing outbox safety (19.7.25)

## Durable prepare-before-submit

Outgoing MLS application messages use a durable prepared-ciphertext outbox in the encrypted local history database (not the OpenMLS SQLCipher file).

Lifecycle: `preparing` → `encrypting` → `ready` → `submitting` → `sent`, with `failed`, `uncertain`, and `blocked` recovery states.

The `encrypting` marker is written and re-read from SQLite **before** `encryptApplication` runs, so a crash after ratchet advancement without stored wire bytes fails closed as `blocked`.

## Ambiguous submits

HTTP timeouts become `uncertain` with outbox retained. Uncertain rows are **never** auto-resubmitted on reconnect, pending sync, conversation reopen, or app restart. Only an explicit user Resubmit action may POST the same durable ciphertext.

## Stale MLS epoch behavior

OpenMLS application messages are bound to the epoch in which they were created. This project configures `max_past_epochs: 0`, so a recipient that has already merged a later Commit cannot decrypt an older-epoch application message.

If prepared outbox ciphertext was created in epoch N and the peer has advanced to N+1 before processing it:

1. An identical server replay still returns the original envelope (same `client_message_id`, original ciphertext). The sender may show Sent after a successful HTTP replay, but the recipient cannot decrypt.
2. Re-encrypting under the **same** `client_message_id` is forbidden once outbox bytes exist; the server would also reject a conflicting ciphertext with `409`.
3. Recovery requires a **new** `client_message_id` and a fresh encrypt in the current epoch (manual / future UX). The current client marks irreversible local cases as `blocked` rather than inventing ciphertext.

This is an intentional fail-closed tradeoff: silent re-encrypt under a reused client id is unsafe for MLS and for server idempotency.

## Outbox AEAD binding

Outbox wire bytes are AES-GCM encrypted at rest with AAD version `outbox-v2` covering:

- conversation id
- client message id
- sender id
- recipient id
- MLS group id hex
- content type

Tampering any bound field fails closed (`MessageHistoryCorruptException`). Diagnostics and DeliveryTiming logs record stage names and exception types only — not plaintext, ciphertext, or tokens.
