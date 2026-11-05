/// Injectable ICE server configuration (D3 TURN will plug in here).
class IceServerConfig {
  const IceServerConfig({
    this.stunUrls = const ['stun:stun.l.google.com:19302'],
    this.turnUrls = const [],
    this.username,
    this.credential,
    this.relayOnly = false,
  });

  final List<String> stunUrls;
  final List<String> turnUrls;
  final String? username;
  final String? credential;

  /// When true, prefer relay (privacy-sensitive). Full enforcement is D3.
  final bool relayOnly;

  List<Map<String, dynamic>> toFlutterWebRtcIceServers() {
    final out = <Map<String, dynamic>>[];
    for (final url in stunUrls) {
      out.add({'urls': url});
    }
    for (final url in turnUrls) {
      out.add({
        'urls': url,
        'username': ?username,
        'credential': ?credential,
      });
    }
    return out;
  }
}
