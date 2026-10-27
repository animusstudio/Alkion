import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/settings/settings_service.dart';
import 'package:alkion/store/local_store.dart';
import '../alkion/domains/local_screen_harness.dart' show openDomainStore;

class _FailedRead implements LocalDatabase {
  _FailedRead(this.source);
  final LocalDatabase source;
  bool fail = true;
  @override
  Future<T> readTransaction<T>(
    Future<T> Function(LocalRead) callback, {
    StoreToken? expected,
  }) => fail
      ? Future.error(const StoreException('synthetic_read_failure'))
      : source.readTransaction(callback, expected: expected);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late LocalStore database;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('alkion-body-style');
    database = await openDomainStore(root);
  });
  tearDown(() async {
    await database.close();
    await root.delete(recursive: true);
  });
  test('artwork choice persists in existing settings snapshot', () async {
    final settings = SettingsService.local(database);
    await settings.load();
    expect(settings.bodyStyle, 'male');
    await settings.setBodyStyle('female');
    await settings.setProfileName('Synthetic');
    await settings.flushPersistence();
    final reopened = SettingsService.local(database);
    await reopened.load();
    expect(reopened.bodyStyle, 'female');
    expect(reopened.profileName, 'Synthetic');
    expect(
      () => reopened.setBodyStyle('unknown'),
      throwsA(isA<StoreException>()),
    );
  });
  test(
    'failed artwork read stays observable and can reload without rewriting',
    () async {
      await LocalPreferences(
        database,
        'settings',
      ).save({'body_style': 'female'});
      final failing = _FailedRead(database);
      final settings = SettingsService.local(failing);
      await expectLater(settings.load(), throwsA(isA<StoreException>()));
      expect(settings.bodyStyle, 'male');
      failing.fail = false;
      await settings.load();
      expect(settings.bodyStyle, 'female');
      final stored = await LocalPreferences(database, 'settings').load();
      expect(stored, {'body_style': 'female'});
      settings.dispose();
    },
  );
  test('unknown stored artwork safely falls back', () async {
    await LocalPreferences(
      database,
      'settings',
    ).save({'body_style': 'unknown'});
    final settings = SettingsService.local(database);
    await settings.load();
    expect(settings.bodyStyle, 'male');
  });
}
