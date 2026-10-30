import 'dart:math' show max;

import '../data/day_template_repository.dart'; // resolveSlot
import '../data/exercise_repository.dart';
import '../data/finished_session_store.dart';
import '../data/models.dart';
import '../store/local_store.dart';
import '../data/session_repository.dart';
import '../data/catalog_execution_repository.dart';
import '../l10n/app_localizations.dart';
import '../util/dates.dart';
import 'active_session_controller.dart';

// Resuming a just-finished workout: which finished session may be resumed,
// and how its live draft is rebuilt from the finish-time snapshot plus the
// rows now in the database.

/// How long after its last finish a workout stays resumable once the
/// calendar day has changed ("finished at 23:50, noticed at 00:20").
const resumeGrace = Duration(hours: 1);

/// Whether the finished session [sessionId] may be resumed at [now]: [f] is
/// its snapshot, and the session belongs to the current calendar day or was
/// finished within [resumeGrace].
///
/// The day branch uses the session's own date, not the finish time: a
/// workout re-finished just after midnight keeps its original date and must
/// not stay resumable for the whole next day. A negative difference (the
/// clock moved back) counts as within the grace period.
bool isResumable(FinishedSession? f, String sessionId, DateTime now) {
  if (f == null || f.sessionId != sessionId) {
    return false;
  }
  if (f.sessionDate == isoDate(now)) {
    return true;
  }
  return now.difference(f.finishedAt) <= resumeGrace;
}

/// The moment [f] stops being resumable: the later of the end of its
/// session's day and its grace period.
DateTime resumableUntil(FinishedSession f) {
  final day = qualifiedCalendarDate(f.sessionDate);
  final endOfGrace = f.finishedAt.add(resumeGrace);
  if (day == null) {
    return endOfGrace;
  }
  final endOfDay = DateTime(day.year, day.month, day.day + 1);
  return endOfDay.isAfter(endOfGrace) ? endOfDay : endOfGrace;
}

/// What a History card offers for its session.
enum SessionResumeState {
  /// Nothing — the usual edit/add/delete actions.
  none,

  /// "Resume workout", plus the usual actions.
  available,

  /// The session is the running (resumed) workout: only "Resume workout",
  /// which reopens it.
  inProgress,
}

/// The [SessionResumeState] of the History card for [sessionId].
/// [activeSessionId] is the running workout's `sessionId` (null for none, or
/// for a fresh workout).
SessionResumeState resumeStateFor({
  required String? activeSessionId,
  required FinishedSession? lastFinished,
  required String sessionId,
  required DateTime now,
}) {
  // Checked first: during a resumed workout the kept snapshot matches too.
  if (activeSessionId != null && activeSessionId == sessionId) {
    return SessionResumeState.inProgress;
  }
  if (isResumable(lastFinished, sessionId, now)) {
    return SessionResumeState.available;
  }
  return SessionResumeState.none;
}

/// What a tap on a History card's Resume action does, in this order.
enum ResumeTapAction { openRunning, forgetExpired, blockedByActive, resume }

/// The [ResumeTapAction] for a card in [state]; [hasActive] is whether any
/// workout is running.
///
/// `inProgress` reopens the running workout whatever [hasActive] says: that
/// running workout is the resumed one.
ResumeTapAction resumeTapAction(
  SessionResumeState state, {
  required bool hasActive,
}) => switch (state) {
  SessionResumeState.inProgress => ResumeTapAction.openRunning,
  SessionResumeState.none => ResumeTapAction.forgetExpired,
  SessionResumeState.available =>
    hasActive ? ResumeTapAction.blockedByActive : ResumeTapAction.resume,
};

/// Logged rows no snapshot block could take (their exercise has no block).
typedef UnmatchedRows = ({String exerciseId, List<LoggedSet> rows});

/// A logged row as a done set of the live workout.
SetState loggedToSetState(LoggedSet r) => SetState(
  id: r.id,
  weightKg: r.weightKg,
  reps: r.reps,
  rir: r.isWarmup ? null : r.rir,
  isWarmup: r.isWarmup,
  done: true,
  originalWeight: r.weightEvidence?.raw,
  rawFields: Map<String, Object?>.from(r.rawFields),
  localRevision: r.localRevision,
  catalog: r.catalog,
)..weightUnavailable = r.weightEvidence?.raw == null;

/// Merges the finish-time [source] draft with the session's logged [rows].
/// The DB is the truth for what was logged; the snapshot supplies only what
/// the DB cannot hold (planned sets, order, targets, baselines).
///
/// Keyed on set id, never on the snapshot's `done` flag:
/// - a snapshot set whose id is in [rows] → done, with the row's weight,
///   reps and RIR (a History edit wins; a set logged after a newer, lost
///   snapshot is still recognised);
/// - a done snapshot set missing from [rows] → dropped (deleted in History);
/// - an undone snapshot set missing from [rows] → kept (planned);
/// - a row matching no snapshot set (added in History) → appended, done, to
///   the first block of its exercise in `set_number` order, or reported in
///   `unmatched` when no block has that exercise;
/// - a block left with no sets at all → dropped.
///
/// Pure: [source] is not modified.
({SessionDraft draft, List<UnmatchedRows> unmatched}) mergeLoggedSets(
  SessionDraft source,
  List<LoggedSet> rows,
) {
  if (rows.any((row) => row.qualifiedSetNumber == null)) {
    throw const StoreException('set_order_review_required');
  }
  final copy = source.deepCopy();
  final byId = {for (final r in rows) r.id: r};
  final matched = <String>{};

  List<SetState> reconcile(List<SetState> sets) {
    final out = <SetState>[];
    for (final s in sets) {
      final r = byId[s.id];
      if (r != null) {
        matched.add(s.id);
        s
          ..weightKg = r.weightKg
          ..originalWeight = r.weightEvidence?.raw
          ..weightUnavailable = r.weightEvidence?.raw == null
          ..weightTouched = false
          ..localRevision = r.localRevision
          ..reps = r.reps
          ..rir = s.isWarmup ? null : r.rir
          ..rawFields = Map<String, Object?>.from(r.rawFields)
          ..repsTouched = false
          ..rirTouched = false
          ..catalog = r.catalog
          ..catalogTouched = false
          ..done = true;
        out.add(s);
      } else if (!s.done) {
        out.add(s);
      }
    }
    return out;
  }

  for (final b in copy.blocks) {
    b.warmupSets = reconcile(b.warmupSets);
    b.workingSets = reconcile(b.workingSets);
  }

  // Rows no snapshot set knows, grouped by exercise in first-appearance order.
  final extra = <String, List<LoggedSet>>{};
  for (final r in rows) {
    if (!matched.contains(r.id)) {
      final key = r.catalog == null ? r.exerciseId : 'catalog:${r.blockId}';
      extra.putIfAbsent(key, () => []).add(r);
    }
  }

  final unmatched = <UnmatchedRows>[];
  final typedSession =
      copy.blocks.any((b) => b.catalogSelection != null) ||
      rows.any((r) => r.catalog != null);
  if (typedSession) {
    final ordered = rows.where((r) => !matched.contains(r.id)).toList()
      ..sort((a, b) => a.setNumber.compareTo(b.setNumber));
    String? previousKey;
    List<LoggedSet>? run;
    for (final row in ordered) {
      final key = row.catalog == null
          ? 'legacy:${row.exerciseId}'
          : 'typed:${row.blockId}:${row.catalog!.selection.compatibilityKey}';
      if (key != previousKey) {
        run = <LoggedSet>[];
        unmatched.add((exerciseId: row.exerciseId, rows: run));
        previousKey = key;
      }
      run!.add(row);
    }
  }
  for (final entry in extra.entries) {
    if (typedSession) break;
    final added = [...entry.value]
      ..sort((a, b) => a.setNumber.compareTo(b.setNumber));
    BlockState? target;
    for (final b in copy.blocks) {
      if (added.first.catalog == null
          ? b.exercise.id == entry.key
          : b.blockId == added.first.blockId) {
        target = b;
        break;
      }
    }
    if (target == null) {
      unmatched.add((exerciseId: added.first.exerciseId, rows: added));
      continue;
    }
    for (final r in added) {
      (r.isWarmup ? target.warmupSets : target.workingSets).add(
        loggedToSetState(r),
      );
    }
  }

  return (
    draft: SessionDraft(
      templateId: copy.templateId,
      name: copy.name,
      focus: copy.focus,
      startedAt: copy.startedAt,
      blocks: copy.blocks.where((b) => b.allSets.isNotEmpty).toList(),
      sessionId: copy.sessionId,
      sessionDate: copy.sessionDate,
      identity: copy.draftId,
      localRevision: copy.localRevision,
      setBases: copy.setBases,
      sessionDateEvidence: copy.sessionDateEvidence,
      restStart: copy.restStart,
      restTotal: copy.restTotal,
      restEndedAt: copy.restEndedAt,
      focusedSetId: copy.focusedSetId,
      rirPromptSetId: copy.rirPromptSetId,
    ),
    unmatched: unmatched,
  );
}

/// Rebuilds the live draft for resuming the finished session [f] from its
/// snapshot and its current [rows] (see [mergeLoggedSets]).
///
/// - A block with nothing logged whose exercise was deleted since is dropped:
///   its planned sets were never stored and cannot reference a missing exercise.
///   A block with logged sets keeps its exercise: deleting an exercise is
///   refused while logged sets reference it.
/// - Each unmatched group becomes a block of exactly its logged rows, with an
///   exercise placeholder named after its id if the exercise is gone (the
///   fallback History shows), and a baseline that ignores this session.
/// - The clock continues from the finish: `startedAt` is [now] minus the
///   longer of the snapshot's elapsed time and the row's [durationMin], so a
///   stale snapshot cannot roll it back.
Future<SessionDraft> restoreFinishedDraft(
  FinishedSession f,
  List<LoggedSet> rows, {
  required int? durationMin,
  required ExerciseRepository exerciseRepo,
  required SessionRepository sessionRepo,
  required DateTime now,
}) async {
  final merged = mergeLoggedSets(f.draft, rows);
  final blocks = <BlockState>[];
  for (final b in merged.draft.blocks) {
    final hasLogged = b.allSets.any((s) => s.done);
    if (!hasLogged && await exerciseRepo.byId(b.exercise.id) == null) {
      continue;
    }
    blocks.add(b);
  }

  for (final g in merged.unmatched) {
    final sourceBlock = g.rows.first.blockId == null
        ? null
        : merged.draft.blocks
              .where((b) => b.blockId == g.rows.first.blockId)
              .firstOrNull;
    final exercise =
        sourceBlock?.exercise ??
        await exerciseRepo.byId(g.exerciseId) ??
        _placeholderExercise(g.exerciseId);
    final resolved =
        sourceBlock?.resolved ??
        resolveSlot(
          Slot(exerciseId: g.exerciseId, position: blocks.length),
          exercise,
        );
    final typedSelection = g.rows.first.catalog?.selection;
    final catalogReference = typedSelection == null
        ? null
        : await sessionRepo.catalogLoadReference(
            typedSelection,
            excludeSessionId: f.sessionId,
          );
    final bestKg = typedSelection != null
        ? catalogReference!.bestKg
        : await sessionRepo.bestTopSet(
            g.exerciseId,
            excludeSessionId: f.sessionId,
          );
    final reference = typedSelection != null
        ? null
        : await sessionRepo.lastTopSetEvidence(
            g.exerciseId,
            excludeSessionId: f.sessionId,
          );
    final typedLast = catalogReference?.last;
    final lastTop = typedSelection == null
        ? reference!.value
        : typedLast == null
        ? null
        : (
            weight: typedLast.weightKg,
            reps: typedLast.reps,
            date: typedLast.date,
          );
    blocks.add(
      BlockState(
        blockId: g.rows.first.blockId,
        originSlotId: g.rows.first.originSlotId ?? sourceBlock?.originSlotId,
        originSlotRevision:
            g.rows.first.originSlotRevision ?? sourceBlock?.originSlotRevision,
        catalogSelection: typedSelection,
        catalogBaselines: {
          if (typedSelection != null &&
              catalogReference?.bestMetrics?['reported_load'] != null)
            typedSelection.compatibilityKey:
                catalogReference!.bestMetrics!['reported_load']!,
        },
        exercise: exercise,
        resolved: resolved,
        warmupSets: [
          for (final r in g.rows)
            if (r.isWarmup) loggedToSetState(r),
        ],
        workingSets: [
          for (final r in g.rows)
            if (!r.isWarmup) loggedToSetState(r),
        ],
        expanded: true,
        bestKg: bestKg,
        lastTop: lastTop,
        lastTopUnavailable: reference?.unavailable ?? false,
      ),
    );
  }

  final elapsed = max(f.elapsedSeconds, (durationMin ?? 0) * 60);
  final executions = CatalogExecutionRepository.local(sessionRepo.db);
  for (final block in blocks) {
    final selections = {
      for (final set in block.allSets)
        if (set.catalog != null)
          set.catalog!.selection.compatibilityKey: set.catalog!.selection,
    };
    for (final selection in selections.values) {
      for (final dependency in await executions.dependenciesForSelection(
        selection,
      )) {
        if (!block.catalogDependencies.any(
          (known) => known.operationId == dependency.operationId,
        )) {
          block.catalogDependencies.add(dependency);
        }
      }
      if (!block.catalogBaselines.containsKey(selection.compatibilityKey)) {
        final reference = await sessionRepo.catalogLoadReference(
          selection,
          excludeSessionId: f.sessionId,
        );
        if (reference.bestMetrics?['reported_load'] case final best?) {
          block.catalogBaselines[selection.compatibilityKey] = best;
        }
        if (reference.lastMetrics case final metrics?) {
          block.catalogLastMetrics[selection.compatibilityKey] = metrics;
        }
      }
    }
  }
  return SessionDraft(
    templateId: merged.draft.templateId,
    name: merged.draft.name,
    focus: merged.draft.focus,
    startedAt: now.subtract(Duration(seconds: elapsed)),
    blocks: blocks,
    sessionId: f.sessionId,
    sessionDate: f.sessionDate,
    identity: merged.draft.draftId,
    localRevision: merged.draft.localRevision,
    setBases: {for (final row in rows) row.id: row.localRevision ?? 0},
    sessionDateEvidence: merged.draft.sessionDateEvidence,
  );
}

/// Title and message of the discard confirm. Discarding a resumed workout is
/// not destructive — its finished session stays in History untouched — so it
/// must not warn that the logged sets will be lost.
({String title, String message}) discardDialogCopy(
  AppLocalizations l,
  SessionDraft draft,
) => draft.sessionId != null
    ? (
        title: l.sessionDiscardChangesTitle,
        message: l.sessionDiscardChangesMessage,
      )
    : (title: l.sessionDiscardTitle, message: l.sessionDiscardMessage);

Exercise _placeholderExercise(String id) => Exercise(
  id: id,
  name: id,
  slug: '',
  muscleGroup: '',
  compound: false,
  plateStepKg: 2.5,
  isTemplate: false,
);
