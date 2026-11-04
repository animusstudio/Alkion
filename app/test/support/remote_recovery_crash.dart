import 'dart:io';

import 'package:alkion/animus/remote_recovery_repository.dart';
import 'package:alkion/identity/alkion_profile.dart';
import 'package:alkion/store/local_store.dart';

/// Disposable subprocess only. Deliberately exits without closing SQLite after
/// a durable boundary, or inside the uncommitted archive transaction.
Future<void> main(List<String> args) async {
  if (args.length != 2 ||
      !args[0].contains('/alkion-remote-recovery-') ||
      !const ['intent', 'fence', 'archive'].contains(args[1])) {
    throw ArgumentError(
      'Explicit disposable recovery fixture and cut required',
    );
  }
  final profile = await AlkionProfile.open(supportRoot: Directory(args[0]));
  final store = await LocalStore.open(
    profile: profile,
    expectedProfileId: profile.profileId,
  );
  final binding = RemoteRecoveryBinding.fromWorkoutBinding({
    'format': 'alkion-native-workout-binding/1',
    'translation': 'synthetic/1',
    'installation_id': profile.installationId,
    'profile_id': profile.profileId,
    'generation': store.token.generation,
    'issuer': 'https://identity.example.test/application/o/synthetic/',
    'subject': 'synthetic-owner',
    'api_origin': 'https://api.example.test',
    'client_id': 'synthetic-native',
    'data_space_id': '10000000-0000-4000-8000-000000000001',
  });
  final repository = RemoteRecoveryRepository(store);
  await repository.beginDiscovery(binding);
  if (args[1] != 'intent') await repository.fence(binding.id);
  Future<Never> cut() async {
    stdout.writeln('durable-recovery-cut:${args[1]}');
    await stdout.flush();
    exit(86);
  }

  if (args[1] == 'archive') {
    await repository.capture(
      binding.id,
      checkpoint: (phase) async {
        if (phase == 'remote-archive-before-commit') await cut();
      },
    );
    throw StateError('Archive cut was not reached');
  }
  await cut();
}
