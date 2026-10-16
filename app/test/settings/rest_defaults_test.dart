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

  test('rest defaults: 180/90 default, persisted', () async {
    final s = SettingsService.local(database);
    await s.load();
    expect(s.restCompoundSeconds, 180);
    expect(s.restIsolationSeconds, 90);

    await s.setRestCompoundSeconds(150);
    await s.setRestIsolationSeconds(75);
    final s2 = SettingsService.local(database);
    await s2.load();
    expect(s2.restCompoundSeconds, 150);
    expect(s2.restIsolationSeconds, 75);
  });
}
