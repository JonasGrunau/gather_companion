/// Where the phone's planned meetings live between launches.
///
/// In the keychain rather than a preferences plist, the same choice
/// [GatherCredentialStore] makes and for a milder version of the same reason: a
/// plan is not a secret, but it is a list of where you will be and when, and a
/// preferences plist rides along in every unencrypted device backup. The keychain
/// also survives a reinstall, which a plist does not — losing your plans because
/// you updated the app would be a poor surprise.
///
/// Reads and writes are wrapped exactly as the credential store wraps them: a
/// keychain that cannot be reached (a locked device, a simulator without one)
/// reads as "no meetings yet" rather than taking the app down on the hot boot path.
library;

import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'calendar.dart';

class CalendarStore {
  CalendarStore({FlutterSecureStorage? storage})
      : _storage = storage ??
            const FlutterSecureStorage(
              iOptions: IOSOptions(
                accessibility: KeychainAccessibility.first_unlock_this_device,
              ),
              aOptions: AndroidOptions(),
            );

  final FlutterSecureStorage _storage;

  static const _key = 'calendar.meetings';

  Future<List<PlannedMeeting>> load() async {
    final raw = await _read(_key);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      final out = <PlannedMeeting>[];
      for (final item in list) {
        try {
          out.add(PlannedMeeting.fromJson((item as Map).cast<String, Object?>()));
        } on Object {
          // One unreadable row should not sink the rest — drop it and keep the
          // meetings that still parse.
        }
      }
      return out;
    } on Object {
      return const [];
    }
  }

  Future<void> save(List<PlannedMeeting> meetings) =>
      _write(_key, jsonEncode([for (final m in meetings) m.toJson()]));

  Future<void> clear() => _delete(_key);

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
      /* nothing useful to do; the next save writes it again */
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
