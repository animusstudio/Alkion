import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/settings/settings_service.dart';
import '../alkion/domains/local_screen_harness.dart' show openDomainStore;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'muscle targets default off and persist independently per profile',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'alkion-target-prefs-',
      );
      final first = await openDomainStore(Directory('${root.path}/first'));
      final second = await openDomainStore(Directory('${root.path}/second'));
      try {
        expect(first.profileId, isNot(second.profileId));
        final settings = SettingsService.local(first);
        final other = SettingsService.local(second);
        await settings.load();
        await other.load();
        expect(settings.muscleTargetsEnabled, isFalse);
        expect(other.muscleTargetsEnabled, isFalse);
        await settings.setMuscleTargetsEnabled(true);
        await settings.setProfileName('Synthetic athlete');
        final reopened = SettingsService.local(first);
        await reopened.load();
        expect(reopened.muscleTargetsEnabled, isTrue);
        await other.load();
        expect(other.muscleTargetsEnabled, isFalse);
        await reopened.setMuscleTargetsEnabled(false);
        final disabled = SettingsService.local(first);
        await disabled.load();
        expect(disabled.muscleTargetsEnabled, isFalse);
        expect(disabled.profileName, 'Synthetic athlete');
      } finally {
        await first.close();
        await second.close();
        await root.delete(recursive: true);
      }
    },
  );
}
