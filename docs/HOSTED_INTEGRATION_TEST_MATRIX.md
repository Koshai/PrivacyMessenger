# Hosted integration test matrix

Run this matrix against the deployed validation host. A local unit test or a green CI job does not check a row below. Record each result in `docs/HOSTED_VALIDATION_RESULTS.md` only after it is executed.

Terminated-app incoming calls stay an accepted MVP limitation. Compile-only iOS CI is not an iPhone result.

## H1. Authentication and accounts

| Check | Pass condition |
| --- | --- |
| Two users request OTP | Both challenges are accepted and both messages arrive at the controlled recipient list |
| Both users verify | Sessions are issued |
| Wrong code | Rejected, no session |
| Expired code | Rejected, no session |
| OTP rate limit | The fourth request inside 15 minutes for one address is rejected |
| SMTP failure | The API reports failure and does not log the code or the SMTP password |
| Second login on the same account | The previous session stops working |
| Logout | `GET /auth/me` with the old token is rejected |

## H2. Friends and messaging

| Check | Pass condition |
| --- | --- |
| Friend request and accept | Each user sees the other |
| MLS conversation | A conversation is established with the existing client |
| Encrypted message each way | The receiver reads plaintext only after MLS decrypt |
| Ordering and duplicates | Existing client rules hold against the hosted API |
| Restart | A stored conversation opens again without a plaintext fallback |
| Binding content type | `application/call-key-binding` is not rendered as chat |

## H3. Calling

| Check | Pass condition |
| --- | --- |
| Outgoing and incoming audio | Two devices, accept path |
| Outgoing and incoming video | Two devices, accept path |
| Reject | Caller returns to idle and media stops |
| Identity | Pin, signature, and DTLS checks still fail closed on mismatch |
| Relay-only | A call connects with relay candidates only, confirmed in coturn allocation logs |
| Hang-up | Both sides release media |
| Rapid repeat | Several setup and teardown cycles without a stuck session |
| API restart during a call | Media may drop. A new call can be placed after the API is healthy. No plaintext fallback |
| coturn restart during a call | The current relay fails closed. A later call allocates again |
| Revoke device during a call | The call ends and media is released |
| Logout during a call | The call ends and the local call seed and inbox are cleared |

## H4. Devices

Run when the device is available. Leave the row as not run otherwise.

- Android foreground, background, and locked screen
- iOS foreground, background, and locked screen
- System call UI, audio route change, Bluetooth if a headset is present
- Microphone and camera permission grant and denial
- Wi-Fi to mobile-data handover
- Process killed before an incoming call. That case remains the accepted MVP limitation

## H5. Failure and recovery

| Check | Pass condition |
| --- | --- |
| API container restart | Health returns, existing session still validates, database rows remain |
| PostgreSQL restart | API reconnects or restarts cleanly, schema and messages remain |
| Client network loss | The call fails closed and can be placed again |
| Expired session | Protected routes reject it |
| Expired TURN credential | coturn rejects it. A new ice-config response works |
| Database interruption | The API does not serve a silent empty account store as success |
| Relay ports blocked | The relay-only call fails. It does not fall back to a claimed success |
| Interrupted binding | The call fails closed |
| Public port scan of 5432 and 4000 | Both closed on the public address |
