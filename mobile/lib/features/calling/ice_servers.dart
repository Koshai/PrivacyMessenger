/// Injectable ICE server configuration.
/// TURN usernames/passwords are short-lived and come from the API.
class IceServerConfig {
  const IceServerConfig({
    this.servers = const [
      IceServerEntry(urls: ['stun:stun.l.google.com:19302']),
    ],
    this.expiresAt,
    this.relayOnly = false,
    this.unavailableReason,
  });

  final List<IceServerEntry> servers;
  final DateTime? expiresAt;
  final bool relayOnly;

  /// Set when the server cannot issue TURN (missing deployment, 503).
  final String? unavailableReason;

  bool get isExpired =>
      expiresAt != null && !DateTime.now().toUtc().isBefore(expiresAt!);

  bool get hasTurn => servers.any((s) => s.urls.any(_isTurn));

  List<Map<String, dynamic>> toFlutterWebRtcIceServers() {
    return [
      for (final server in servers)
        {
          'urls': server.urls.length == 1 ? server.urls.first : server.urls,
          'username': ?server.username,
          'credential': ?server.credential,
        },
    ];
  }

  factory IceServerConfig.fromJson(
    Map<String, dynamic> json, {
    bool relayOnly = false,
  }) {
    final raw = json['ice_servers'];
    final servers = <IceServerEntry>[];
    if (raw is List) {
      for (final item in raw.whereType<Map>()) {
        final map = item.cast<String, dynamic>();
        final urls = <String>[];
        final urlField = map['urls'];
        if (urlField is String) urls.add(urlField);
        if (urlField is List) {
          urls.addAll(urlField.whereType<String>());
        }
        if (urls.isEmpty) continue;
        servers.add(IceServerEntry(
          urls: urls,
          username: map['username'] as String?,
          credential: map['credential'] as String?,
        ));
      }
    }
    return IceServerConfig(
      servers: servers,
      expiresAt: json['expires_at'] == null
          ? null
          : DateTime.parse(json['expires_at'] as String).toUtc(),
      relayOnly: relayOnly,
    );
  }

  IceServerConfig copyWith({bool? relayOnly}) {
    return IceServerConfig(
      servers: servers,
      expiresAt: expiresAt,
      relayOnly: relayOnly ?? this.relayOnly,
      unavailableReason: unavailableReason,
    );
  }
}

class IceServerEntry {
  const IceServerEntry({
    required this.urls,
    this.username,
    this.credential,
  });

  final List<String> urls;
  final String? username;
  final String? credential;
}

bool _isTurn(String url) {
  final lower = url.toLowerCase();
  return lower.startsWith('turn:') || lower.startsWith('turns:');
}
