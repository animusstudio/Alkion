// The process-interruption driver for capture qualification.
//
// `make -C app capture-recovery` builds integration_test/capture_recovery_child.dart
// as its own disposable Linux debug bundle and passes its executable to the
// recovery test (`--dart-define=CAPTURE_CHILD=...`). The test copies a marked
// synthetic installation, writes a config next to it and starts the child
// on it. The child runs one real capture (real native gate and files, real
// PowerSync database, the registered native sync adapter) and logs every
// fault boundary it passes. When told to, it parks at one boundary and says
// so; the test then SIGKILLs it, so the kernel drops its locks exactly as
// for an app killed there. Only the child's own process is ever killed, and
// only on its own copy of a synthetic installation.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'capture_installation.dart';

/// Environment variable naming the child's config file.
const recoveryChildConfigVariable = 'REPS_CAPTURE_RECOVERY_CHILD';

/// The child bundle's executable, from the Make target.
const recoveryChildExecutable = String.fromEnvironment('CAPTURE_CHILD');

/// What the child is asked to do.
class RecoveryChildConfig {
  const RecoveryChildConfig({
    required this.root,
    required this.mode,
    required this.liveDraft,
    required this.captureId,
    this.resume = false,
    this.blockAt,
    this.blockOccurrence = 0,
  });

  factory RecoveryChildConfig.read(String path) {
    final j = jsonDecode(File(path).readAsStringSync()) as Map<String, Object?>;
    return RecoveryChildConfig(
      root: j['root']! as String,
      mode: j['mode']! as String,
      liveDraft: j['live_draft']! as bool,
      captureId: j['capture_id']! as String,
      resume: j['resume']! as bool,
      blockAt: j['block_at'] as String?,
      blockOccurrence: j['block_occurrence']! as int,
    );
  }

  /// The synthetic installation root.
  final String root;

  /// `rehearsal` or `local_hold`.
  final String mode;
  final bool liveDraft;
  final String captureId;

  /// After a successful capture, record the explicit resume decision too.
  final bool resume;

  /// Park at the [blockOccurrence]th time this boundary is passed.
  final String? blockAt;
  final int blockOccurrence;

  String get logPath => p.join(root, 'child.log');

  Map<String, Object?> toJson() => {
    'root': root,
    'mode': mode,
    'live_draft': liveDraft,
    'capture_id': captureId,
    'resume': resume,
    'block_at': blockAt,
    'block_occurrence': blockOccurrence,
  };
}

/// One child run as the parent saw it.
class RecoveryChildRun {
  RecoveryChildRun(
    this.hits,
    this.outcome, {
    required this.killed,
    required this.exitCode,
  });

  /// Boundaries the child passed, in order.
  final List<String> hits;

  /// The child's last line: `blocked BOUNDARY N`, `done certified ID SHA`
  /// (with ` resumed` after an explicit decision), `done CODE` or
  /// `error TYPE`.
  final String outcome;

  /// Whether the parent sent SIGKILL (it was parked).
  final bool killed;

  /// The child's exit status as the OS reported it: `-9` when SIGKILL
  /// ended it, `0` after a completed run, `70` after an error.
  final int exitCode;

  /// The child was ended by SIGKILL, per its exit status.
  bool get diedBySigkill => exitCode == -ProcessSignal.sigkill.signalNumber;

  String? get manifestSha256 {
    final parts = outcome.split(' ');
    return parts.length >= 4 && parts[1] == 'certified' ? parts[3] : null;
  }
}

/// Starts the child on [installation] and waits until it parks (then kills
/// it) or finishes.
Future<RecoveryChildRun> runRecoveryChild(
  SyntheticInstallation installation, {
  required String mode,
  required bool liveDraft,
  required String captureId,
  bool resume = false,
  String? blockAt,
  int blockOccurrence = 0,
  Duration timeout = const Duration(minutes: 2),
}) async {
  installation.checkSynthetic();
  if (recoveryChildExecutable.isEmpty) {
    throw StateError('CAPTURE_CHILD is not set (make -C app capture-recovery)');
  }
  final config = RecoveryChildConfig(
    root: installation.root.path,
    mode: mode,
    liveDraft: liveDraft,
    captureId: captureId,
    resume: resume,
    blockAt: blockAt,
    blockOccurrence: blockOccurrence,
  );
  final configFile = File(p.join(installation.root.path, 'child.json'))
    ..writeAsStringSync(jsonEncode(config.toJson()), flush: true);
  final log = File(config.logPath);
  if (log.existsSync()) log.deleteSync();

  // The tool's engine switches (VM service port, pause flags) are for the
  // test app only.
  final environment = Map.of(Platform.environment)
    ..removeWhere((k, _) => k.startsWith('FLUTTER_ENGINE_SWITCH'))
    ..[recoveryChildConfigVariable] = configFile.path;
  final process = await Process.start(
    recoveryChildExecutable,
    const [],
    environment: environment,
    includeParentEnvironment: false,
  );
  final output = StringBuffer();
  void keep(String s) {
    output.write(s);
    if (output.length > 8192) {
      final tail = output.toString().substring(output.length - 4096);
      output
        ..clear()
        ..write(tail);
    }
  }

  process.stdout.transform(utf8.decoder).listen(keep);
  process.stderr.transform(utf8.decoder).listen(keep);
  var exited = false;
  unawaited(process.exitCode.then((_) => exited = true));

  final deadline = DateTime.now().add(timeout);
  List<String> lines() => log.existsSync()
      ? log.readAsLinesSync().where((l) => l.isNotEmpty).toList()
      : const [];
  bool terminal(String l) =>
      l.startsWith('blocked ') ||
      l.startsWith('done ') ||
      l.startsWith('error ');
  while (true) {
    final current = lines();
    if (current.isNotEmpty && terminal(current.last)) break;
    if (exited || DateTime.now().isAfter(deadline)) {
      process.kill(ProcessSignal.sigkill);
      throw StateError(
        'recovery child stopped without a result '
        '(exited: $exited); log: ${current.join(' | ')}; output: $output',
      );
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  final all = lines();
  final outcome = all.last;
  final killed = outcome.startsWith('blocked ');
  final int exitCode;
  if (killed) {
    process.kill(ProcessSignal.sigkill);
    exitCode = await process.exitCode;
  } else {
    exitCode = await process.exitCode.timeout(
      const Duration(seconds: 30),
      onTimeout: () {
        process.kill(ProcessSignal.sigkill);
        return -1;
      },
    );
  }
  return RecoveryChildRun(
    [
      for (final l in all)
        if (l.startsWith('hit ')) l.substring(4),
    ],
    outcome,
    killed: killed,
    exitCode: exitCode,
  );
}
