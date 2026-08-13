/// Where the bridge's address lives, and the migration that moves it.
///
/// This moved out of `SharedPreferences` because the two halves of pairing did not
/// survive equally. iOS wipes an app's preferences plist on reinstall and leaves
/// its keychain items alone, so a reinstall left the phone with a working Gather
/// session — presence, map and feed all fine — and no idea where its bridge was.
/// Push registration bails without an address, so the phone silently stopped
/// handing over its FCM token while the bridge went on pushing to the token from
/// the install before, which FCM accepts with a 200.
///
/// The migration is the risky half of that fix: shipping the move without it would
/// unpair every phone that is *already* paired, which is the same failure caused
/// deliberately. So it gets its own tests.
library;

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gather_companion/src/settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });

  BridgeSettingsStore store() => BridgeSettingsStore(storage: const FlutterSecureStorage());

  test('a fresh install has no computer, and says so rather than half of one', () async {
    final settings = await store().load();

    expect(settings.isComplete, isFalse);
    expect(settings.port, BridgeSettings.defaultPort, reason: 'a default, not a zero');
    expect(await store().loadName(), isNull);
  });

  test('what pairing wrote comes back, port and name included', () async {
    await store().save(const BridgeSettings(host: '10.0.0.9', port: 7788, token: 'tok'));
    await store().saveName('jonas-mac');

    final settings = await store().load();

    expect(settings.host, '10.0.0.9');
    expect(settings.port, 7788);
    expect(settings.token, 'tok');
    expect(settings.isComplete, isTrue);
    expect(await store().loadName(), 'jonas-mac');
  });

  test('a pairing from before the move is carried across on first read', () async {
    // The upgrade path for a phone that is already paired. Without this, shipping
    // the keychain move would unpair everybody.
    SharedPreferences.setMockInitialValues({
      'bridge.host': '192.168.178.81',
      'bridge.port': 7799,
      'bridge.token': 'legacy-token',
      'bridge.name': 'old-mac',
    });

    final settings = await store().load();

    expect(settings.host, '192.168.178.81');
    expect(settings.token, 'legacy-token');
    expect(settings.isComplete, isTrue);
    expect(await store().loadName(), 'old-mac');
  });

  test('the old copy is cleared, so it cannot come back after an unpair', () async {
    SharedPreferences.setMockInitialValues({
      'bridge.host': '192.168.178.81',
      'bridge.port': 7799,
      'bridge.token': 'legacy-token',
      'bridge.name': 'old-mac',
    });

    await store().load();

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('bridge.host'), isNull);
    expect(prefs.getString('bridge.token'), isNull);
    expect(prefs.getInt('bridge.port'), isNull);
    expect(prefs.getString('bridge.name'), isNull);

    // And the second read is served entirely from the keychain.
    expect((await store().load()).token, 'legacy-token');
  });

  test('a half-written legacy record is not migrated into a broken pairing', () async {
    // A host with no token cannot register anything. Migrating it would produce a
    // card claiming a computer that can never answer.
    SharedPreferences.setMockInitialValues({'bridge.host': '192.168.178.81'});

    expect((await store().load()).isComplete, isFalse);
  });

  test('forgetting the computer leaves nothing behind', () async {
    await store().save(const BridgeSettings(host: '10.0.0.9', port: 7799, token: 'tok'));
    await store().saveName('jonas-mac');

    await store().clear();

    expect((await store().load()).isComplete, isFalse);
    expect(await store().loadName(), isNull);
  });

  test('the install id is minted once and then kept', () async {
    // The whole point: an id that changed per launch would be no better than
    // keying the bridge's device list on the FCM token, which is what let a
    // reinstalled app leave a dead token behind absorbing every push.
    final first = await store().installId();

    expect(first, isNotEmpty);
    expect(await store().installId(), first);
    expect(await BridgeSettingsStore(storage: const FlutterSecureStorage()).installId(), first);
  });

  test('the install id survives forgetting the computer', () async {
    // It names the phone, not the relationship. Keeping it means re-pairing
    // replaces our old entry on the bridge rather than adding a second one.
    final before = await store().installId();
    await store().clear();

    expect(await store().installId(), before);
  });
}
