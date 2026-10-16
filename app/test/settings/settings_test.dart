import 'dart:io';
import 'package:alkion/store/local_store.dart';
import '../alkion/domains/local_screen_harness.dart' show openDomainStore;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:alkion/settings/settings_service.dart';
import 'package:alkion/theme/tokens.dart';
import 'package:alkion/units/unit_service.dart';

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

  group('SettingsService', () {
    test('defaults: dark mode, accents[0], Athlete, no connection', () async {
      final svc = SettingsService.local(database);
      await svc.load();

      expect(svc.mode, 'dark');
      expect(svc.brightness, Brightness.dark);
      expect(svc.accent, accents[0]);
      expect(svc.accentColor, accents[0]);
      expect(svc.profileName, 'Athlete');
      expect(svc.serverUrl, '');
    });

    test('setMode light → brightness is light and persists', () async {
      final svc = SettingsService.local(database);
      await svc.load();
      await svc.setMode('light');

      expect(svc.brightness, Brightness.light);

      // Verify persisted: a new instance loading from the same prefs reads light.
      final svc2 = SettingsService.local(database);
      await svc2.load();
      expect(svc2.mode, 'light');
      expect(svc2.brightness, Brightness.light);
    });

    test('setAccent persists and reconstructs via fromARGB', () async {
      final svc = SettingsService.local(database);
      await svc.load();
      await svc.setAccent(accents[1]);

      expect(svc.accent, accents[1]);

      final svc2 = SettingsService.local(database);
      await svc2.load();
      expect(svc2.accent, accents[1]);
    });

    test('unknown accent int on load falls back to accents[0]', () async {
      // Seed an int that doesn't match any of the 4 accents.
      await LocalPreferences(database, 'settings').save({'accent': 0xFFFF0000});
      final svc = SettingsService.local(database);
      await svc.load();
      expect(svc.accent, accents[0]);
    });
  });

  group('UnitService persistence', () {
    test('load defaults to kg', () async {
      final svc = UnitService.local(database);
      await svc.load();
      expect(svc.unit, Unit.kg);
    });

    test('setUnit lb persists; reload reads lb', () async {
      final svc = UnitService.local(database);
      await svc.load();
      svc.setUnit(Unit.lb);

      // Allow the fire-and-forget write to the prefs to complete.
      await svc.flushPersistence();

      final svc2 = UnitService.local(database);
      await svc2.load();
      expect(svc2.unit, Unit.lb);
    });
  });
}
