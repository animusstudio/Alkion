import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/settings/settings_service.dart';
import 'package:alkion/session/workout_notification.dart';

import '../support/screen_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'notifString resolves the persisted local locale, falls back to en',
    () async {
      final dir = await Directory.systemTemp.createTemp('alkion-notif-');
      final db = await FixtureDatabase.open(dir);
      try {
        final settings = SettingsService.local(db);
        await settings.load();
        await settings.setLocaleOverride('it');
        await settings.flushPersistence();
        final reloaded = SettingsService.local(db);
        await reloaded.load();
        expect(notifString(reloaded.locale?.languageCode, 'rest'), 'Recupero');
        expect(
          notifString(reloaded.locale?.languageCode, 'inProgress'),
          'Allenamento in corso',
        );
        expect(notifString('zz', 'rest'), 'Rest');
        expect(notifString('zz', 'inProgress'), 'Workout in progress');
        expect(notifString(null, 'rest'), 'Rest');
      } finally {
        await db.close();
        await dir.delete(recursive: true);
      }
    },
  );
}
