# Messaging Reliability Matrix — Step 19.7.30B

Maps failure scenarios to existing safeguards. Protocol / MLS semantics are unchanged.

## Persistent outgoing states → UI

| `LocalMessageDelivery` | Collapsed UI (`ChatDeliveryState`) | User label | Allowed action |
| --- | --- | --- | --- |
| preparing / encrypting / ready / submitting | sending | Sending… | none |
| sent | sent | Sent to server | none (not peer delivery) |
| failed | failed | Couldn’t send | Resubmit same client id + durable ciphertext |
| uncertain | uncertain | Not confirmed | Resubmit safely (same id + ciphertext); **no auto retry** |
| blocked | blocked | Can’t resend this copy | Compose new only |
| received | received | Received (incoming) | none |

Safeguards: `ConversationController.retry` only accepts failed/uncertain; `EncryptedConversationService._prepareApplicationCiphertext` refuses re-encrypt when outbox bytes missing after an advanced state.

## Failure / lifecycle scenarios

| Scenario | Safeguard | Evidence |
| --- | --- | --- |
| Offline / HTTP fail before accept | Durable outbox retained; UI failed | `outgoing_outbox_test` |
| Timeout after possible server accept | uncertain; no silent retry | `outgoing_outbox_test`, `outbox_safety_verification_test` |
| Explicit resubmit | Same client_message_id + prepared ciphertext | outbox tests |
| Crash after encrypt before outbox persist | blocked; no unsafe retry | outbox tests |
| Crash after outbox persist | resubmit allowed | outbox tests |
| Missing/corrupt outbox bytes | blocked / fail closed | outbox tests |
| Duplicate pending envelope inbound | Single bubble | `mls_send_diagnostics_test` |
| Identical concurrent server submit | One canonical row | `envelope_idempotency_concurrency_test.go` (needs `DATABASE_URL`) |
| Different ciphertext same client id | Reject / conflict | Go e2e + client 409 → blocked path |
| History key missing while DB exists | `MessageHistoryKeyLossException`; no key mint | `local_message_store_test` |
| Schema upgrade | Additive only; downgrade throws | schema v3→v4 migration test |
| Peer index corrupt/missing | Empty previews; history intact | 30A solidification tests |
| WebSocket reconnect | Hint stream; durable sync via HTTP pending | realtime + conversation controller |

## Architectural limitation (documented, not “passing”)

MLS SQLCipher DB and AES-GCM history DB are separate. A crash between MLS ratchet advance and history/outbox commit can leave non-atomic windows. Existing barriers minimize unsafe retry; they do not provide a single distributed transaction across the two stores.

## Physical-device scope (30B)

| Check | SM-S938U | Device B |
| --- | --- | --- |
| Open existing conversation | Pass (substantial a11y content nodes; not unavailable/empty) | Pending |
| History after background/reopen | Pass (nodes still present) | Pending |
| Bidirectional live send | **Unverified** (peer device offline) | Pending |
| Live outbox fault injection | Not run on established account | — |
