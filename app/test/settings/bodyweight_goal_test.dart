import 'dart:io';
import 'package:alkion/store/local_store.dart';
import '../alkion/domains/local_screen_harness.dart' show openDomainStore;
import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/settings/bodyweight_goal.dart';
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

  group('bodyweightDeltaTone', () {
    test('a loss is good only on cut', () {
      expect(bodyweightDeltaTone(-0.5, BodyweightGoal.cut), DeltaTone.good);
      expect(bodyweightDeltaTone(-0.5, BodyweightGoal.bulk), DeltaTone.neutral);
      expect(
        bodyweightDeltaTone(-0.5, BodyweightGoal.maintain),
        DeltaTone.neutral,
      );
    });
    test('a gain is good only on bulk', () {
      expect(bodyweightDeltaTone(0.4, BodyweightGoal.bulk), DeltaTone.good);
      expect(bodyweightDeltaTone(0.4, BodyweightGoal.cut), DeltaTone.neutral);
      expect(
        bodyweightDeltaTone(0.4, BodyweightGoal.maintain),
        DeltaTone.neutral,
      );
    });
    test('no change is always neutral', () {
      for (final g in BodyweightGoal.values) {
        expect(bodyweightDeltaTone(0, g), DeltaTone.neutral);
      }
    });
  });

  group('SettingsService goal', () {
    test('defaults to maintain', () async {
      final s = SettingsService.local(database);
      await s.load();
      expect(s.bodyweightGoal, BodyweightGoal.maintain);
    });
    test('persists and notifies', () async {
      final s = SettingsService.local(database);
      await s.load();
      var notified = 0;
      s.addListener(() => notified++);
      await s.setBodyweightGoal(BodyweightGoal.cut);
      expect(notified, 1);
      final s2 = SettingsService.local(database);
      await s2.load();
      expect(s2.bodyweightGoal, BodyweightGoal.cut);
    });
    test('an unknown stored value reads as maintain', () async {
      await LocalPreferences(
        database,
        'settings',
      ).save({'bodyweight_goal': 'shred'});
      final s = SettingsService.local(database);
      await s.load();
      expect(s.bodyweightGoal, BodyweightGoal.maintain);
    });
  });
}
