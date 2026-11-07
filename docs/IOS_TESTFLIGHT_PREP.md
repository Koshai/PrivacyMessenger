# Step 19.7.27B prerequisites — TestFlight distribution

This document prepares **19.7.27B**. It does not enroll an Apple account, create certificates, or upload a build.

Do not paste certificates, provisioning profiles, or private keys into chat or into the repository.

## 1. Apple Developer Program

- Enroll the organization or individual in the [Apple Developer Program](https://developer.apple.com/programs/) (paid membership).
- Confirm the legal entity matches App Store Connect.
- Wait until membership is Active before creating signing assets.

## 2. Signing certificates and provisioning

For CI-signed TestFlight builds you will need:

| Asset | Purpose |
| --- | --- |
| Apple Distribution certificate | Sign the IPA for App Store / TestFlight |
| App Store provisioning profile | Bundle ID + entitlements for distribution |
| Optional: Development cert + profile | Internal device installs during debugging |

Prefer storing these in GitHub Actions secrets / a private encrypted store, never in git.

Typical secret names (placeholders only — create empty secrets only after membership exists):

- `APPLE_CERTIFICATE_BASE64` — distribution `.p12` (base64)
- `APPLE_CERTIFICATE_PASSWORD`
- `APPLE_PROVISIONING_PROFILE_BASE64`
- `APPLE_API_KEY_ID` / `APPLE_API_ISSUER_ID` / `APPLE_API_KEY_P8` — App Store Connect API key for upload

Do not commit functional-looking fake values.

## 3. Bundle identifier registration

Register in Certificates, Identifiers & Profiles:

```text
com.privatemessenger.privateMessenger
```

Enable capabilities required by the shipping app only after they are implemented, for example:

- Push Notifications (if/when PushKit or APNs is added)
- Associated Domains (only if used)

CallKit does not replace VoIP push registration.

## 4. App Store Connect application

- Create a new iOS app with the registered bundle ID.
- Set display name consistent with `CFBundleDisplayName` (`Private Messenger`).
- Complete primary category, privacy policy URL, and contact info before external testing.

## 5. TestFlight build upload

After a signed archive:

1. Build with distribution signing (not `--no-codesign`).
2. Upload via `xcodebuild` / `altool` / `notary` pathway or Transporter using the App Store Connect API key.
3. Wait for processing; resolve missing compliance / export encryption questions honestly (OpenMLS / E2EE will require accurate answers).

Validation dart-defines for TestFlight QA builds:

```text
--dart-define=APP_ENV=validation
--dart-define=API_BASE_URL=https://privacymessenger-test.duckdns.org
```

## 6. External testers

- Add external tester group and email invites.
- First external build requires Beta App Review.
- Provide test account credentials for reviewers (separate from production if possible).
- Document that existing Android MLS identities are independent of iOS installs.

## 7. Secure CI credential management

- Restrict secret access to the signing workflow only.
- Rotate distribution certificates on staff change.
- Never log provisioning profile contents or `.p8` keys.
- Keep Android release signing completely separate.

## 8. Privacy disclosures and testing metadata

Prepare App Privacy answers for:

- Account email / identifiers
- Messages (E2EE — contents not readable by operator; still disclose collection categories accurately)
- Audio / camera usage for calls
- Diagnostics if any crash reporting is added later (none assumed today)

Also prepare:

- Camera / microphone purpose strings (already in Info.plist)
- Local network usage rationale
- Whether background VoIP is claimed — **do not claim terminated-app incoming calls** until PushKit + server push are implemented and tested

## Out of scope until 19.7.27B

- Creating or requesting real Apple credentials in this repository
- Publishing an IPA
- Claiming physical-device verification without a device test
