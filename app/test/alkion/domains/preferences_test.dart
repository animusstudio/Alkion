import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/settings/settings_service.dart';
import 'package:alkion/settings/bodyweight_goal.dart';
import 'package:alkion/units/unit_service.dart';
import 'local_screen_harness.dart';

void main() {
  test(
    'unit, cut/bulk/maintain, language and rest persist through two real SQLite reopens without kg rewrites',
    () async {
      final root = await Directory.systemTemp.createTemp('alkion-preferences');
      var store = await openDomainStore(root);
      try {
        await seedExercise(store, 'ex', 'Bench', base: '80.125000000000000001');
        final settings = SettingsService.local(store);
        await settings.load();
        await settings.setBodyweightGoal(BodyweightGoal.cut);
        await settings.setLocaleOverride('it');
        await settings.setRestCompoundSeconds(155);
        await settings.setRestIsolationSeconds(75);
        final units = UnitService.local(store);
        await units.load();
        units.setUnit(Unit.lb);
        await units.flushPersistence();
        final rows = await store.getAll('SELECT * FROM exercises');
        for (var i = 0; i < 2; i++) {
          await store.close();
          store = await openDomainStore(root);
          final restored = SettingsService.local(store);
          await restored.load();
          final u = UnitService.local(store);
          await u.load();
          expect(u.unit, Unit.lb);
          expect(restored.bodyweightGoal, BodyweightGoal.cut);
          expect(restored.localeOverride, 'it');
          expect(restored.restCompoundSeconds, 155);
          expect(restored.restIsolationSeconds, 75);
          expect(await store.getAll('SELECT * FROM exercises'), rows);
        }
      } finally {
        await store.close();
        await root.delete(recursive: true);
      }
    },
  );
}
