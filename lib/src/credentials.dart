/// Where the Gather refresh token lives on the phone.
///
/// Split from [BridgeSettings] deliberately, because the two are not comparable.
/// The bridge token is scoped to one daemon on one LAN; losing it means somebody
/// can read your presence while on your wifi. The Gather refresh token *is* your
/// Gather account — it mints ID tokens for as long as it stays valid, from
/// anywhere. So it goes in the platform keychain, and nothing else does.
///
/// `SharedPreferences` would have been one less dependency and one less code path.
/// It is also an unencrypted plist that iCloud and iTunes backups include, which
/// would put the user's Gather identity in every backup of the device until they
/// next changed their password.
library;

import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:gather_client/gather_client.dart';

class GatherCredentialStore {
  GatherCredentialStore({FlutterSecureStorage? storage})
      : _storage = storage ??
            const FlutterSecureStorage(
              iOptions: IOSOptions(
                // The collector reconnects in the background after a resume, which can
                // happen while the screen is still locked — so `first_unlock` rather
                // than `unlocked`. `ThisDeviceOnly` is the half that keeps it out of
                // backups and off any other device restored from one.
                accessibility: KeychainAccessibility.first_unlock_this_device,
              ),
              aOptions: AndroidOptions(encryptedSharedPreferences: true),
            );

  final FlutterSecureStorage _storage;

  static const _key = 'gather.credentials';

  /// The space handed over at pairing, used for the first connection only.
  ///
  /// Not secret, and not durable — the collector re-reads `recent-spaces` to follow
  /// the user between spaces — so it rides along in the same record purely to avoid
  /// a second store.
  static const _spaceKey = 'gather.spaceId';

  Future<GatherCredentials> load() async {
    final raw = await _read(_key);
    if (raw == null || raw.isEmpty) return GatherCredentials.empty;
    try {
      return GatherCredentials.fromJson(
        (jsonDecode(raw) as Map).cast<String, Object?>(),
      );
    } on Object {
      // A record we cannot read is a record we cannot use. Treating it as absent
      // sends the user to pairing, which is the only thing that would fix it anyway.
      return GatherCredentials.empty;
    }
  }

  Future<void> save(GatherCredentials credentials) =>
      _write(_key, jsonEncode(credentials.toJson()));

  Future<String?> loadSpaceId() => _read(_spaceKey);

  Future<void> saveSpaceId(String? spaceId) async {
    if (spaceId == null || spaceId.isEmpty) return;
    await _write(_spaceKey, spaceId);
  }

  Future<void> clear() async {
    await _delete(_key);
    await _delete(_spaceKey);
  }

  /// Keychain access can fail — a locked device before first unlock, a
  /// misconfigured entitlement, a simulator with no keychain at all. None of that
  /// should crash the app on launch; it should look like "not paired yet", which is
  /// a state the UI already handles.
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
      /* nothing useful to do; the next launch asks for pairing again */
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
