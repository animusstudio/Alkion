import 'dart:io';
import 'package:alkion/store/local_store.dart';
import '../alkion/domains/local_screen_harness.dart' show openDomainStore;
import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/settings/settings_service.dart';

void main() {
  late Directory root;
  late LocalStore database;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('alkion-settings');
    database = await openDomainStore(root);
  });
  tearDown(() async {
    await database.close();
    await root.delete(recursive: true);
  });
  TestWidgetsFlutterBinding.ensureInitialized();
  test('development updates stay disabled', () async {
    final s = SettingsService.local(database);
    await s.load();
    expect(s.autoCheckUpdates, isFalse);
    await expectLater(
      s.setAutoCheckUpdates(true),
      throwsA(isA<UnsupportedError>()),
    );
    await s.setAutoCheckUpdates(false);
    final s2 = SettingsService.local(database);
    await s2.load();
    expect(s2.autoCheckUpdates, isFalse);
  });
}
