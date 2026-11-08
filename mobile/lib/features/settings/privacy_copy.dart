/// User-facing privacy language for Settings.
///
/// Kept separate so widget tests can assert accuracy without brittle layout
/// coupling. Do not claim third-party certification or formal audits.
abstract final class PrivacyCopy {
  static const title = 'Privacy and Security';

  static const subtitle =
      'Messages you send are end-to-end encrypted on this device. '
      'The server relays encrypted data and cannot read message contents. '
      'This app has not been independently security-certified.';
}
