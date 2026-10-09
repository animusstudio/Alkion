import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show immutable;
import 'package:path/path.dart' as p;

import '../data/active_session_draft.dart';
import '../data/finished_session_store.dart';
import '../session/resume.dart';
import 'capture_journal.dart';
import 'source_write_gate.dart';
import 'startup_inventory.dart';

/// Where the private capture state lives: `<appSupport>/capture/`, beside
/// the source stores. The journal, the gate's lock/state files and the
/// preparation area are coordinator state; none of them is a source store,
/// and none is ever part of a final capture.
@immutable
class CaptureLocations {
  CaptureLocations(this.source)
      : root = Directory(p.join(source.path, 'capture'));

  /// The application-support directory holding the source stores.
  final Directory source;

  /// The private capture directory.
  final Directory root;

  File get journal => File(p.join(root.path, 'journal.json'));
  Directory get gate => Directory(p.join(root.path, 'gate'));
  Directory get preparation => Directory(p.join(root.path, 'preparation'));
}

/// Asks the native gate whether any capture is recorded in [gate]'s state
/// directory, without naming one. Never throws. Returns the native code:
/// `open` (none), `mismatch` (some capture is recorded), or a failure code
/// such as `platform_unavailable`, `unsupported`, `state_corrupt`,
/// `io_error` or `probe_failed`.
///
/// The state directory is created through the native durable primitive
/// first, so on a platform without the plugin nothing is created and the
/// answer is `platform_unavailable` before any file-system work could fail.
///
/// This relies on `verifyHold` answering `open` for an open record before
/// it compares identities, and on no capture ever being recorded under the
/// empty id (the native side refuses it).
Future<String> probeSourceGate(
  SourceWriteGate gate, {
  required Directory base,
  CaptureFiles files = const CaptureFiles(),
}) async {
  try {
    await files.ensureDirectory(gate.stateDirectory, base: base);
    return await gate.holdStatus(const SourceHold('', 0));
  } on SourceGateException catch (e) {
    return e.code;
  } catch (_) {
    return 'probe_failed';
  }
}

/// Gate answers of a startup that is not capture-capable: no plugin on this
/// platform, or no usable lock primitive here. No capture can have closed
/// admission there, so capture state never holds such a startup.
const _notCaptureCapable = {'platform_unavailable', 'unsupported'};

/// The ordinary boot steps, in their existing order. The startup sequence
/// runs them only when no capture holds the source; the store loaders run
/// between [prepareSessions] and [connect].
abstract interface class OrdinaryStartupSteps {
  /// Client-local settings and units.
  Future<void> loadSettings();

  Future<void> openDatabase();

  /// Identity, which may generate and persist a new local user id.
  Future<void> initIdentity();

  /// Boot backfills and template absorption.
  Future<void> runBootMigrations();

  /// Session owner and notification wiring (no stored state is loaded).
  Future<void> prepareSessions();

  /// Remembered sign-in and, when opted in, sync.
  Future<void> connect();
}

/// The safe reason ordinary startup was held.
@immutable
class CaptureRecoveryState {
  const CaptureRecoveryState({
    required this.code,
    this.stage,
    this.captureId,
    this.inventory,
  });

  /// `capture_active`, a `journal_*` code, `gate_<native code>`,
  /// `preservation_failed` or `startup_inspection_failed`.
  final String code;

  /// The journal stage, when one was read.
  final String? stage;
  final String? captureId;

  /// Raw source files as inventoried (and preserved where possible) while
  /// held. Null if inventory itself failed.
  final StartupInventory? inventory;
}

sealed class StartupOutcome {
  const StartupOutcome();
}

/// Ordinary startup ran.
final class StartupAllowed extends StartupOutcome {
  const StartupAllowed({required this.inventory, required this.skippedLoaders});

  final StartupInventory inventory;

  /// Store roles whose loader did not run because their bytes could not be
  /// preserved; their files were left untouched. Only ever non-empty on a
  /// startup that is not capture-capable.
  final Set<String> skippedLoaders;
}

/// A capture holds (or may hold) the source: nothing ordinary ran.
final class CaptureRecoveryRequired extends StartupOutcome {
  const CaptureRecoveryRequired(this.recovery);

  final CaptureRecoveryState recovery;
}

/// Capture-first startup.
///
/// 1. Probes the native gate. `platform_unavailable`/`unsupported` mean
///    this startup is not capture-capable (Android builds today): capture
///    state never holds it, and step 4 applies.
/// 2. Capture-capable: an active journal stage (anything but
///    `resume_allowed`/`resumed`), a journal that is unreadable, of an
///    unknown version or naming an unknown stage, a recorded native capture
///    or any other gate failure holds startup.
/// 3. Capture-capable: every byte a loader could delete and every leftover
///    `.tmp` (which the next save overwrites) is preserved
///    ([preserveBeforeLoaders]). If anything cannot be read or preserved,
///    startup is held (`preservation_failed`): continuing would let the
///    first ordinary save or clear destroy those bytes.
/// 4. Not capture-capable: the same preservation is attempted (it fails
///    without the plugin); a store whose bytes were not kept is not loaded
///    and its file is left as it is, and startup continues as before.
///
/// Held: raw source files are inventoried and preserved where possible, NO
/// ordinary step and NO loader runs, and [CaptureRecoveryRequired] is
/// returned. Otherwise the ordinary steps run in their existing order.
/// Startup never repairs ids, promotes temporary files or fabricates
/// missing history.
Future<StartupOutcome> runCaptureAwareStartup({
  required CaptureJournal journal,
  required Future<String> Function() probeGate,
  required Directory source,
  required RawPreservation preservation,
  required List<StartupFileSpec> files,
  required OrdinaryStartupSteps steps,
  required DateTime now,
}) async {
  String gate;
  try {
    gate = await probeGate();
  } catch (_) {
    gate = 'probe_failed';
  }
  final capable = !_notCaptureCapable.contains(gate);

  if (capable) {
    CaptureRecoveryState? held;
    try {
      held = await _heldBy(journal, gate);
    } catch (_) {
      held = const CaptureRecoveryState(code: 'startup_inspection_failed');
    }
    if (held != null) {
      return CaptureRecoveryRequired(
        await _withInventory(held, source, preservation),
      );
    }
  }

  StartupFilePlan? plan;
  try {
    plan = await preserveBeforeLoaders(files, preservation, now);
  } catch (_) {
    plan = null;
  }
  if (capable && (plan == null || !plan.inventory.complete)) {
    return CaptureRecoveryRequired(
      CaptureRecoveryState(
        code: 'preservation_failed',
        inventory: plan?.inventory,
      ),
    );
  }
  // Not capture-capable and the pass failed unexpectedly: load nothing.
  plan ??= const StartupFilePlan(StartupInventory([]), {});

  await steps.loadSettings();
  await steps.openDatabase();
  await steps.initIdentity();
  await steps.runBootMigrations();
  await steps.prepareSessions();
  for (final spec in files) {
    if (plan.loadable.contains(spec.role)) await spec.load(now);
  }
  await steps.connect();
  return StartupAllowed(
    inventory: plan.inventory,
    skippedLoaders: {
      for (final spec in files)
        if (!plan.loadable.contains(spec.role)) spec.role,
    },
  );
}

Future<CaptureRecoveryState?> _heldBy(CaptureJournal journal, String gate) async {
  CaptureJournalState? state;
  try {
    state = await journal.read();
  } on CaptureJournalException catch (e) {
    return CaptureRecoveryState(code: e.code);
  }
  if (state != null && state.stage.blocksStartup) {
    return CaptureRecoveryState(
      code: 'capture_active',
      stage: state.stage.wire,
      captureId: state.captureId,
    );
  }
  if (gate != 'open') {
    return CaptureRecoveryState(
      code: 'gate_$gate',
      stage: state?.stage.wire,
      captureId: state?.captureId,
    );
  }
  return null;
}

Future<CaptureRecoveryState> _withInventory(
  CaptureRecoveryState state,
  Directory source,
  RawPreservation preservation,
) async {
  StartupInventory? inventory;
  try {
    inventory = await inspectCaptureStartup(
      source,
      preservation.preparation,
      files: preservation.files,
      base: preservation.base,
    );
  } catch (_) {
    inventory = null;
  }
  return CaptureRecoveryState(
    code: state.code,
    stage: state.stage,
    captureId: state.captureId,
    inventory: inventory,
  );
}

/// The draft store as ordinary startup loads it: the loader deletes bytes
/// that do not decode as a draft.
Future<StartupFileSpec> draftStartupFile(
  DraftStore store,
  Future<void> Function(DateTime now) load,
) async =>
    StartupFileSpec(
      role: 'draft',
      file: await store.file(),
      temporary: await store.temporaryFile(),
      destructiveReason: (Uint8List bytes, DateTime now) =>
          store.decodeBytes(bytes) == null ? 'malformed' : null,
      load: load,
    );

/// The finished-session snapshot as ordinary startup loads it: the loader
/// deletes bytes that do not decode, and a snapshot no longer resumable at
/// `now`.
Future<StartupFileSpec> finishedStartupFile(
  FinishedSessionStore store,
  Future<void> Function(DateTime now) load,
) async =>
    StartupFileSpec(
      role: 'finished',
      file: await store.file(),
      temporary: await store.temporaryFile(),
      destructiveReason: (Uint8List bytes, DateTime now) {
        final f = store.decodeBytes(bytes);
        if (f == null) return 'malformed';
        return isResumable(f, f.sessionId, now) ? null : 'expired';
      },
      load: load,
    );
