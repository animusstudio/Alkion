// Disposable fixture process for capture interruption qualification (see
// integration_test/support/recovery_child.dart). Built and started only by
// `make -C app capture-recovery`; it refuses to run without a config naming
// a marked synthetic installation under the system temp directory.
import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;
import 'package:powersync/powersync.dart' show PowerSyncDatabase;
import 'package:workout_tracker/capture/capture_coordinator.dart';
import 'package:workout_tracker/sync/schema.dart';

import '../test/support/capture_faults.dart';
import 'support/capture_installation.dart';
import 'support/recovery_child.dart';

Future<void> main() async {
  final configPath = Platform.environment[recoveryChildConfigVariable];
  if (configPath == null) {
    stderr.writeln('capture recovery child: no config; nothing to do');
    exit(64);
  }
  WidgetsFlutterBinding.ensureInitialized();
  final config = RecoveryChildConfig.read(configPath);
  final log = File(config.logPath);
  void say(String line) =>
      log.writeAsStringSync('$line\n', mode: FileMode.append, flush: true);

  try {
    final installation = SyntheticInstallation(Directory(config.root))
      ..checkSynthetic();
    installation.usePreferences();
    final database = PowerSyncDatabase(
      schema: schema,
      path: p.join(installation.source.path, 'workout-tracker.db'),
    );
    await database.initialize();
    final process = InstallationProcess(
      installation,
      database,
      liveDraft: config.liveDraft,
    );
    await process.prepareGate();

    var seen = 0;
    final faults = ScriptedCaptureFaults(
      onHit: (boundary, _) async {
        say('hit $boundary');
        if (boundary == config.blockAt && seen++ == config.blockOccurrence) {
          say('blocked $boundary ${config.blockOccurrence}');
          // Parked until the parent kills this process.
          await Completer<void>().future;
        }
      },
    );
    final coordinator = process.coordinator(
      faults: faults,
      newCaptureId: () => config.captureId,
      clock: () => DateTime.utc(2026, 10, 10, 10, 30, 5),
    );
    try {
      final certified = await coordinator.capture(
        mode: config.mode == 'local_hold'
            ? CaptureMode.localHold
            : CaptureMode.rehearsal,
      );
      var line =
          'done certified ${certified.captureId} ${certified.manifestSha256}';
      if (config.resume) {
        await coordinator.resumeOriginal(
          captureId: certified.captureId,
          decisionDigest: 'c' * 64,
        );
        line += ' resumed';
      }
      say(line);
    } on CaptureNotCertified catch (e) {
      say('done ${e.code}');
    }
  } catch (e) {
    say('error ${e.runtimeType}');
    exit(70);
  }
  exit(0);
}
