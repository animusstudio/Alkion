import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/identity/identity_service.dart';

import '../support/screen_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  late FixtureDatabase db;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('alkion-identity-');
    db = await FixtureDatabase.open(dir);
  });
  tearDown(() async {
    await db.close();
    await dir.delete(recursive: true);
  });

  test(
    'uses the persisted local profile identity, onboarding initially incomplete',
    () async {
      final svc = IdentityService.local(db);
      await svc.init(probeExistingUserId: () async => null);
      expect(svc.currentUserId, isNotEmpty);
      expect(svc.currentUserId, db.profileId);
      expect(svc.onboardingComplete, isFalse);
      final id = svc.currentUserId;
      await db.close();
      db = await FixtureDatabase.open(dir);
      final again = IdentityService.local(db);
      await again.init(probeExistingUserId: () async => 'IGNORED-server-user');
      expect(again.currentUserId, id);
      expect(again.onboardingComplete, isFalse);
    },
  );

  test(
    'does not adopt a legacy account probe or mark onboarding complete',
    () async {
      var probed = false;
      final svc = IdentityService.local(db);
      await svc.init(
        probeExistingUserId: () async {
          probed = true;
          return 'server-user-123';
        },
      );
      expect(probed, isFalse);
      expect(svc.currentUserId, db.profileId);
      expect(svc.currentUserId, isNot('server-user-123'));
      expect(svc.onboardingComplete, isFalse);
    },
  );

  test(
    'completeOnboarding persists the profile-bound flag through reopen',
    () async {
      final svc = IdentityService.local(db);
      await svc.load();
      expect(svc.onboardingComplete, isFalse);
      await svc.completeOnboarding();
      await svc.flushPersistence();
      expect(svc.onboardingComplete, isTrue);
      final id = svc.currentUserId;
      await db.close();
      db = await FixtureDatabase.open(dir);
      final reload = IdentityService.local(db);
      await reload.load();
      expect(reload.currentUserId, id);
      expect(reload.onboardingComplete, isTrue);
      expect(await db.getAll('SELECT * FROM operations'), isEmpty);
    },
  );
}
