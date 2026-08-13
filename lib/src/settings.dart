import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Where the computer-side bridge lives, and the token that pairs us with it.
///
/// `gather-app-bridge pair` prints both. They are stored on the device so the app
/// can keep handing over its push token after a restart.
class BridgeSettings {
  const BridgeSettings({required this.host, required this.port, required this.token});

  final String host;
  final int port;
  final String token;

  static const defaultPort = 7799;

  bool get isComplete => host.trim().isNotEmpty && token.trim().isNotEmpty;

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
}

/// Persists [BridgeSettings] in the platform keychain.
///
/// ## Why the keychain, when this is not a secret worth one
///
/// It was in `SharedPreferences` until it turned out that the two halves of
/// pairing do not survive equally. iOS wipes an app's preferences plist when the
/// app is reinstalled, but leaves its keychain items alone — so a reinstall left
/// the phone with a working Gather session and no idea where its bridge was.
/// Presence carried on working, which is why this was invisible for a while, but
/// push registration bails when the address is missing: the phone never handed
/// over an FCM token again, and the bridge kept pushing to the token from the
/// install before. Every layer reported success.
///
/// So this moved for **durability**, not for secrecy. [GatherCredentialStore] is
/// still the one that is here because its contents are dangerous; this one is here
/// so that it lives and dies with that one. Being harder to read out of a device
/// backup is a bonus, not the reason.
class BridgeSettingsStore {
  BridgeSettingsStore({FlutterSecureStorage? storage})
      : _storage = storage ??
            const FlutterSecureStorage(
              // Matched to `GatherCredentialStore` on purpose: these two records are
              // now one fact split across two stores, and a phone that could read
              // one but not the other would be back in the state this class exists
              // to prevent.
              iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock_this_device),
              aOptions: AndroidOptions(),
            );

  final FlutterSecureStorage _storage;

  static const _hostKey = 'bridge.host';
  static const _portKey = 'bridge.port';
  static const _tokenKey = 'bridge.token';
  static const _nameKey = 'bridge.name';

  /// Identifies this installation to the bridge, so it can replace our previous
  /// token instead of collecting both.
  ///
  /// Minted once and kept, which is the whole point — an id that changed per
  /// launch would be no better than keying on the token itself. It rides in this
  /// store rather than in `SharedPreferences` for the same reason as the rest: it
  /// has to outlive a reinstall to be worth anything.
  static const _installKey = 'bridge.installId';

  /// The four keys as they were written before this store existed.
  ///
  /// Read once per launch, and only when the keychain has nothing — see
  /// [_migrateFromPreferences].
  static const _legacyKeys = [_hostKey, _portKey, _tokenKey, _nameKey];

  Future<BridgeSettings> load() async {
    final host = await _read(_hostKey);
    if (host == null || host.isEmpty) {
      final migrated = await _migrateFromPreferences();
      if (migrated != null) return migrated;
    }
    return BridgeSettings(
      host: host ?? '',
      port: int.tryParse(await _read(_portKey) ?? '') ?? BridgeSettings.defaultPort,
      token: await _read(_tokenKey) ?? '',
    );
  }

  Future<void> save(BridgeSettings settings) async {
    await _write(_hostKey, settings.host.trim());
    await _write(_portKey, '${settings.port}');
    await _write(_tokenKey, settings.token.trim());
  }

  /// What the computer calls itself, shown on the settings card.
  Future<String?> loadName() => _read(_nameKey);

  Future<void> saveName(String name) => _write(_nameKey, name);

  /// A stable id for this install, minted on first use.
  ///
  /// Deliberately not `FirebaseInstallations.getId()`, which would be one more
  /// Firebase dependency for a value that only ever has to be unique and stable —
  /// and which is itself reset by a reinstall, the exact event this has to survive.
  Future<String> installId() async {
    final existing = await _read(_installKey);
    if (existing != null && existing.isNotEmpty) return existing;
    // Not cryptographic, and does not need to be: it names one install to one
    // bridge on one LAN. Microseconds-since-epoch plus an identity hash is enough
    // to not collide with the same person's other phone.
    final minted = 'i${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}'
        '${identityHashCode(this).toRadixString(36)}';
    await _write(_installKey, minted);
    return minted;
  }

  /// Forgets the bridge, but keeps [installId].
  ///
  /// The id is not part of the pairing — it identifies the phone, not the
  /// relationship — and keeping it means re-pairing replaces our old entry in the
  /// bridge's device list rather than adding a second one beside it.
  Future<void> clear() async {
    for (final key in _legacyKeys) {
      await _delete(key);
    }
  }

  /// Moves a pre-keychain pairing across, once.
  ///
  /// Without this, shipping the move would silently unpair every phone that is
  /// already paired — the failure it is meant to fix, caused deliberately.
  /// Returns null when there was nothing to move.
  Future<BridgeSettings?> _migrateFromPreferences() async {
    final SharedPreferences prefs;
    try {
      prefs = await SharedPreferences.getInstance();
    } on Object {
      return null;
    }

    final host = prefs.getString(_hostKey);
    final token = prefs.getString(_tokenKey);
    if (host == null || host.isEmpty || token == null || token.isEmpty) return null;

    final settings = BridgeSettings(
      host: host,
      port: prefs.getInt(_portKey) ?? BridgeSettings.defaultPort,
      token: token,
    );
    await save(settings);
    final name = prefs.getString(_nameKey);
    if (name != null && name.isNotEmpty) await saveName(name);

    // Cleared only after the keychain write, so a crash in between leaves the old
    // copy readable and the migration simply runs again next launch.
    for (final key in _legacyKeys) {
      await prefs.remove(key);
    }
    return settings;
  }

  /// Keychain access can fail — a locked device before first unlock, a
  /// misconfigured entitlement, a simulator with no keychain at all. None of that
  /// should crash the app on launch; it should look like "no computer paired",
  /// which is a state the settings card now states plainly.
  Future<String?> _read(String key) async {
    try {
      return await _storage.read(key: key);
    } on Object {
      return null;
    }
  }

  Future<void> _write(String key, String value) async {
    try {
      await _storage.write(key: key, value: value);
    } on Object {
      /* nothing useful to do; the next pairing writes it again */
    }
  }

  Future<void> _delete(String key) async {
    try {
      await _storage.delete(key: key);
    } on Object {
      /* already gone, or unreadable — either way it is not coming back */
    }
  }
}
