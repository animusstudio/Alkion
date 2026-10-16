import 'dart:io';
import 'package:alkion/store/local_store.dart';
import '../alkion/domains/local_screen_harness.dart' show openDomainStore;
import 'package:flutter/widgets.dart';
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
  test('locale override: null=system default, set persists', () async {
    final s = SettingsService.local(database);
    await s.load();
    expect(s.localeOverride, isNull);
    expect(s.locale, isNull);

    await s.setLocaleOverride('it');
    expect(s.locale, const Locale('it'));
    final s2 = SettingsService.local(database);
    await s2.load();
    expect(s2.localeOverride, 'it');
    expect(s2.locale, const Locale('it'));

    await s.setLocaleOverride(null);
    expect(s.locale, isNull);
  });
}
