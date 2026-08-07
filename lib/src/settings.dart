import 'package:shared_preferences/shared_preferences.dart';

/// Where the computer-side bridge lives, and the token that pairs us with it.
///
/// `gather-app-bridge install` prints both. They are stored on the device so the
/// app reconnects on its own after a restart.
class BridgeSettings {
  const BridgeSettings({required this.host, required this.port, required this.token});

  final String host;
  final int port;
  final String token;

  static const _hostKey = 'bridge.host';
  static const _portKey = 'bridge.port';
  static const _tokenKey = 'bridge.token';
  static const _nameKey = 'bridge.name';

  static const defaultPort = 7799;

  bool get isComplete => host.trim().isNotEmpty && token.trim().isNotEmpty;

  Uri wsUri({int since = 0}) => Uri(
        scheme: 'ws',
        host: host.trim(),
        port: port,
        path: '/ws',
        queryParameters: {
          'token': token.trim(),
          if (since > 0) 'since': '$since',
        },
      );

  Uri httpUri(String path, [Map<String, String> query = const {}]) => Uri(
        scheme: 'http',
        host: host.trim(),
        port: port,
        path: path,
        queryParameters: {'token': token.trim(), ...query},
      );

  static const empty = BridgeSettings(host: '', port: defaultPort, token: '');

  BridgeSettings copyWith({String? host, int? port, String? token}) => BridgeSettings(
        host: host ?? this.host,
        port: port ?? this.port,
        token: token ?? this.token,
      );

  static Future<BridgeSettings> load() async {
    final prefs = await SharedPreferences.getInstance();
    return BridgeSettings(
      host: prefs.getString(_hostKey) ?? '',
      port: prefs.getInt(_portKey) ?? defaultPort,
      token: prefs.getString(_tokenKey) ?? '',
    );
  }

  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_hostKey, host.trim());
    await prefs.setInt(_portKey, port);
    await prefs.setString(_tokenKey, token.trim());
  }

  /// What the computer calls itself, shown as "paired with …".
  static Future<String?> loadName() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_nameKey);
  }

  static Future<void> saveName(String name) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_nameKey, name);
  }

  static Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_hostKey);
    await prefs.remove(_portKey);
    await prefs.remove(_tokenKey);
    await prefs.remove(_nameKey);
  }
}
