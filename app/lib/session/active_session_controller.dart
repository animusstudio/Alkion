import 'dart:async';
import 'dart:convert';
import 'dart:math' show max;

import 'package:flutter/foundation.dart';
import 'package:powersync/powersync.dart' show uuid;

import '../capture/session_capture_hooks.dart';
import '../capture/source_write_gate.dart';
import '../data/active_session_draft.dart';
import '../data/day_template_repository.dart'; // resolveSlot, DayTemplate
import '../data/exercise_repository.dart';
import '../data/finished_session_store.dart';
import '../data/models.dart';
import '../data/session_repository.dart';
import '../data/session_writer.dart';
import '../util/dates.dart';

// ── Pure helpers ─────────────────────────────────────────────────────────────

/// Rounds [v] to the nearest [step].
///
/// Example: `roundTo(38.75, 2.5) == 40.0`.
double roundTo(double v, double step) => (v / step).round() * step;

/// Builds a [BlockState] from a fully-resolved slot, seeding weights from
/// [lastTopKg] (or the exercise's base weight, or 20 as a last-resort floor
/// for custom exercises that have no base weight yet).
///
/// The warm-up ramp formula:
///   weight_i = roundTo(suggested * (0.5 + 0.18 * i), step)
///   reps_i   = max(1, 8 − 2*i)
///
/// Working sets use [suggested] weight, [repLow] reps, RIR 1.
BlockState buildBlock({
  required ResolvedSlot resolved,
  double? lastTopKg,
}) {
  final exercise = resolved.exercise;
  final step = exercise.plateStepKg;

  // Seed: last known top weight beats base; 20 is the custom-only floor —
  // the seeded catalog always has base_weight_kg after the trait migration.
  final seed = lastTopKg ?? exercise.baseWeightKg ?? 20.0;

  // Compound exercises bump one plate on top of the seed to encourage
  // progressive overload; isolation exercises stay at the seed.
  final suggested = roundTo(
    seed + (exercise.compound ? step : 0),
    step,
  );

  // Warm-up ramp
  final warmups = <SetState>[];
  for (var i = 0; i < resolved.warmupSets; i++) {
    warmups.add(SetState(
      id: uuid.v4(),
      weightKg: roundTo(suggested * (0.5 + 0.18 * i), step),
      reps: max(1, 8 - 2 * i),
      rir: null,
      isWarmup: true,
      done: false,
    ));
  }

  // Working sets
  final working = <SetState>[];
  for (var i = 0; i < resolved.workSets; i++) {
    working.add(SetState(
      id: uuid.v4(),
      weightKg: suggested,
      reps: resolved.repLow,
      rir: 1,
      isWarmup: false,
      done: false,
    ));
  }

  return BlockState(
    exercise: exercise,
    resolved: resolved,
    warmupSets: warmups,
    workingSets: working,
    expanded: true,
  );
}

/// A set together with the block it belongs to.
typedef LiveSet = ({BlockState block, SetState set});

/// The heaviest done working set in [block] and whether it beats the
/// block's all-time best (no history counts as a PR). The same rule the
/// block header and the finish-time PR flag use.
({double topKg, bool isPr}) liveTopOf(BlockState block) {
  final top = block.workingSets
      .where((s) => s.done)
      .fold<double>(0, (m, s) => s.weightKg > m ? s.weightKg : m);
  final best = block.bestKg;
  return (topKg: top, isPr: top > 0 && (best == null || top > best));
}

/// A fresh workout opens with only its first exercise expanded; the live set
/// expands the others as the workout reaches them.
void expandOnlyFirst(List<BlockState> blocks) {
  for (var i = 0; i < blocks.length; i++) {
    blocks[i].expanded = i == 0;
  }
}

// ── Data classes ─────────────────────────────────────────────────────────────

/// Mutable state for a single set during an active session.
class SetState {
  final String id;
  double weightKg;
  int reps;
  int? rir;
  final bool isWarmup;
  bool done;

  SetState({
    required this.id,
    required this.weightKg,
    required this.reps,
    required this.rir,
    required this.isWarmup,
    required this.done,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'weightKg': weightKg,
        'reps': reps,
        'rir': rir,
        'isWarmup': isWarmup,
        'done': done,
      };

  factory SetState.fromJson(Map<String, dynamic> json) => SetState(
        id: json['id'] as String,
        weightKg: (json['weightKg'] as num).toDouble(),
        reps: json['reps'] as int,
        rir: json['rir'] as int?,
        isWarmup: json['isWarmup'] as bool,
        done: json['done'] as bool,
      );
}

/// State for one exercise block (accordion) in the active session.
class BlockState {
  final Exercise exercise;
  final ResolvedSlot resolved;
  List<SetState> warmupSets;
  List<SetState> workingSets;
  bool expanded;

  /// The all-time best top-set weight for this exercise (loaded from the DB
  /// at session build time). Used for live PR detection.
  double? bestKg;

  /// The most-recent (last-session) top set for this exercise — weight, reps,
  /// and ISO date. Shown as the "Last · {ago}" reference row in the UI.
  ({double weight, int reps, String date})? lastTop;

  BlockState({
    required this.exercise,
    required this.resolved,
    required this.warmupSets,
    required this.workingSets,
    required this.expanded,
    this.bestKg,
    this.lastTop,
  });

  /// All sets in display order: warm-ups first, then working.
  List<SetState> get allSets => [...warmupSets, ...workingSets];

  Map<String, dynamic> toJson() => {
        'exerciseId': exercise.id,
        'exerciseName': exercise.name,
        'exerciseSlug': exercise.slug,
        'exerciseMuscleGroup': exercise.muscleGroup,
        'exerciseEquip': exercise.equip,
        'exerciseCompound': exercise.compound,
        'exerciseBaseWeightKg': exercise.baseWeightKg,
        'exercisePlateStepKg': exercise.plateStepKg,
        'exerciseDefaultRepLow': exercise.defaultRepLow,
        'exerciseDefaultRepHigh': exercise.defaultRepHigh,
        'exerciseDefaultWarmupSets': exercise.defaultWarmupSets,
        'exerciseDefaultWorkingSets': exercise.defaultWorkingSets,
        'exerciseDefaultRirLow': exercise.defaultRirLow,
        'exerciseDefaultRirHigh': exercise.defaultRirHigh,
        'exerciseDefaultRestSeconds': exercise.defaultRestSeconds,
        'resolvedWorkSets': resolved.workSets,
        'resolvedWarmupSets': resolved.warmupSets,
        'resolvedRepLow': resolved.repLow,
        'resolvedRepHigh': resolved.repHigh,
        'resolvedRirLow': resolved.rirLow,
        'resolvedRirHigh': resolved.rirHigh,
        'warmupSets': warmupSets.map((s) => s.toJson()).toList(),
        'workingSets': workingSets.map((s) => s.toJson()).toList(),
        'expanded': expanded,
        'bestKg': bestKg,
        'lastTopWeight': lastTop?.weight,
        'lastTopReps': lastTop?.reps,
        'lastTopDate': lastTop?.date,
      };

  factory BlockState.fromJson(Map<String, dynamic> json) {
    final exercise = Exercise(
      id: json['exerciseId'] as String,
      name: json['exerciseName'] as String,
      slug: json['exerciseSlug'] as String? ?? '',
      muscleGroup: json['exerciseMuscleGroup'] as String? ?? '',
      equip: json['exerciseEquip'] as String?,
      compound: json['exerciseCompound'] as bool? ?? false,
      baseWeightKg: (json['exerciseBaseWeightKg'] as num?)?.toDouble(),
      plateStepKg: (json['exercisePlateStepKg'] as num?)?.toDouble() ?? 2.5,
      defaultRepLow: json['exerciseDefaultRepLow'] as int?,
      defaultRepHigh: json['exerciseDefaultRepHigh'] as int?,
      defaultWarmupSets: json['exerciseDefaultWarmupSets'] as int?,
      defaultWorkingSets: json['exerciseDefaultWorkingSets'] as int?,
      defaultRirLow: json['exerciseDefaultRirLow'] as int?,
      defaultRirHigh: json['exerciseDefaultRirHigh'] as int?,
      defaultRestSeconds: json['exerciseDefaultRestSeconds'] as int?,
      isTemplate: false,
    );
    final resolved = ResolvedSlot(
      exercise: exercise,
      workSets: json['resolvedWorkSets'] as int,
      warmupSets: json['resolvedWarmupSets'] as int,
      repLow: json['resolvedRepLow'] as int,
      repHigh: json['resolvedRepHigh'] as int,
      rirLow: json['resolvedRirLow'] as int,
      rirHigh: json['resolvedRirHigh'] as int,
    );
    final ltWeight = (json['lastTopWeight'] as num?)?.toDouble();
    final ltReps = json['lastTopReps'] as int?;
    final ltDate = json['lastTopDate'] as String?;
    final lastTop = (ltWeight != null && ltReps != null && ltDate != null)
        ? (weight: ltWeight, reps: ltReps, date: ltDate)
        : null;

    return BlockState(
      exercise: exercise,
      resolved: resolved,
      warmupSets: (json['warmupSets'] as List)
          .map((e) => SetState.fromJson(e as Map<String, dynamic>))
          .toList(),
      workingSets: (json['workingSets'] as List)
          .map((e) => SetState.fromJson(e as Map<String, dynamic>))
          .toList(),
      expanded: json['expanded'] as bool? ?? true,
      bestKg: (json['bestKg'] as num?)?.toDouble(),
      lastTop: lastTop,
    );
  }
}

/// The in-memory model for an ongoing session, held by [ActiveSessionController].
class SessionDraft {
  final String? templateId;
  final String name;
  final String focus;
  final DateTime startedAt;
  final List<BlockState> blocks;

  /// The `sessions.id` this draft was resumed from, or null for a fresh
  /// workout. When set, finishing replaces that session in place.
  final String? sessionId;

  /// The `sessions.date` of the resumed session, kept when it is finished
  /// again so the workout stays on the day it was done. Null for a fresh
  /// workout.
  final String? sessionDate;

  const SessionDraft({
    required this.templateId,
    required this.name,
    required this.focus,
    required this.startedAt,
    required this.blocks,
    this.sessionId,
    this.sessionDate,
  });

  Map<String, dynamic> toJson() => {
        'templateId': templateId,
        'name': name,
        'focus': focus,
        'startedAt': startedAt.toIso8601String(),
        'blocks': blocks.map((b) => b.toJson()).toList(),
        'sessionId': sessionId,
        'sessionDate': sessionDate,
      };

  factory SessionDraft.fromJson(Map<String, dynamic> json) => SessionDraft(
        templateId: json['templateId'] as String?,
        name: json['name'] as String,
        focus: json['focus'] as String,
        startedAt: DateTime.parse(json['startedAt'] as String),
        blocks: (json['blocks'] as List)
            .map((e) => BlockState.fromJson(e as Map<String, dynamic>))
            .toList(),
        // Absent in drafts written by older builds → a fresh workout.
        sessionId: json['sessionId'] as String?,
        sessionDate: json['sessionDate'] as String?,
      );

  /// An independent copy made through the same JSON path the draft files use,
  /// so no [BlockState]/[SetState] is shared with this draft.
  SessionDraft deepCopy() => SessionDraft.fromJson(
      jsonDecode(jsonEncode(toJson())) as Map<String, dynamic>);
}

// ── ActiveSessionController ──────────────────────────────────────────────────

/// Manages the in-memory state of an active workout session.
///
/// Call [buildFromTemplate] to initialise from a [DayTemplate]; or
/// [seedForTest] in unit tests to inject a ready-made draft.
///
/// All state mutations (toggleDone, addSet, etc.) call [notifyListeners] so
/// that Provider-wired widgets rebuild automatically.
class ActiveSessionController extends ChangeNotifier {
  /// [draftStore] enables debounced autosave of the in-progress draft (used
  /// for resume-on-launch). Null (e.g. in unit tests) disables persistence.
  ActiveSessionController({DraftStore? draftStore}) : _draftStore = draftStore;

  /// Adopts a previously persisted draft (resume-on-launch / crash recovery).
  ActiveSessionController.fromDraft(SessionDraft draft, {DraftStore? draftStore})
      : _draftStore = draftStore,
        _draft = draft;

  final DraftStore? _draftStore;
  Timer? _saveDebounce;

  /// The store the draft autosaves to, or null when it is not persisted.
  DraftStore? get draftStore => _draftStore;

  /// Autosave debounce window (exposed for tests).
  static const saveDebounce = Duration(seconds: 1);

  SessionDraft? _draft;

  /// Fences autosaves: each scheduling, finish, discard and freeze moves it
  /// on, and an autosave whose epoch is no longer current never writes —
  /// not even one whose timer already fired and is waiting for admission.
  int _saveEpoch = 0;

  /// Generation of the capture that froze this controller's callbacks.
  int? _frozenGeneration;

  /// A mutation happened while frozen, so its autosave is still owed.
  bool _savePending = false;

  /// Whether a capture froze autosave and rest auto-stop.
  bool get callbacksFrozen => _frozenGeneration != null;

  @override
  void notifyListeners() {
    _scheduleSave();
    super.notifyListeners();
  }

  void _scheduleSave() {
    final store = _draftStore;
    final d = _draft;
    if (store == null || d == null) return;
    _saveDebounce?.cancel();
    _saveDebounce = null;
    final epoch = ++_saveEpoch;
    if (callbacksFrozen) {
      _savePending = true;
      return;
    }
    // Copied now: the autosave writes the state it was scheduled for.
    _armSave(store, d.deepCopy(), epoch);
  }

  void _armSave(DraftStore store, SessionDraft copy, int epoch) {
    _saveDebounce = Timer(saveDebounce, () {
      if (epoch != _saveEpoch) return;
      if (callbacksFrozen) {
        _savePending = true;
        return;
      }
      SessionWriteLedger.instance.detach(runSourceWrite(
        'session.autosave',
        (_) async {
          // A finish, discard, newer schedule or capture freeze since the
          // timer fired supersedes this save.
          if (epoch != _saveEpoch || callbacksFrozen) return;
          await SessionWriteLedger.instance.write('draft', () => store.save(copy));
        },
      ).catchError((Object e) {
        // Refused (a capture closed admission) or failed: still owed, unless
        // the workout ended meanwhile.
        if (_draft == null) return;
        _savePending = true;
        // A refusal is retried after the debounce while nothing newer was
        // scheduled and no capture froze callbacks (the capture then
        // flushes the draft itself, or resumeCallbacks saves it).
        if (e is SourceGateException &&
            epoch == _saveEpoch &&
            !callbacksFrozen) {
          _armSave(store, copy, epoch);
        }
      }));
    });
  }

  /// Moves on whenever the draft's persisted state may become stale; the
  /// capture compares it to know whether its flush covered every change.
  int get saveEpoch => _saveEpoch;

  /// Stops autosave and rest auto-stop for capture [generation]: the pending
  /// debounce is cancelled and already scheduled callbacks are fenced. Later
  /// mutations stay in memory until [resumeCallbacks].
  void freezeCallbacks(int generation) {
    if (_saveDebounce?.isActive ?? false) _savePending = true;
    _saveDebounce?.cancel();
    _saveDebounce = null;
    _saveEpoch++;
    _frozenGeneration = generation;
  }

  /// The capture's flush of the draft as it was at [epoch] landed: nothing
  /// is owed unless the draft was scheduled for saving again since.
  void markFlushed(int epoch) {
    if (epoch == _saveEpoch) _savePending = false;
  }

  /// Ends a freeze (or, unfrozen, settles what a refused autosave still
  /// owes): a rest whose countdown ran out meanwhile ends at its due time
  /// (no silent extension, no timer continuity), and an owed save or a
  /// mutation made while frozen is autosaved.
  void resumeCallbacks(DateTime now) {
    _frozenGeneration = null;
    final start = restStart;
    var changed = false;
    if (start != null) {
      final due = start.add(Duration(seconds: restTotal));
      if (!now.isBefore(due)) {
        restEndedAt = due;
        restStart = null;
        restTotal = 0;
        changed = true;
      }
    }
    if (changed || _savePending) {
      _savePending = false;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _saveDebounce?.cancel();
    _saveEpoch++;
    super.dispose();
  }

  SessionDraft get draft {
    assert(_draft != null, 'No active session — call buildFromTemplate first.');
    return _draft!;
  }

  /// Null-safe read for widgets that may render a frame while the draft is
  /// being torn down. `draft`'s assert is stripped in release, leaving a bare
  /// `!` that would crash instead.
  SessionDraft? get draftOrNull => _draft;

  bool get hasSession => _draft != null;

  // ── Build ─────────────────────────────────────────────────────────────────

  /// Initialises the controller from a [DayTemplate].
  ///
  /// Resolves each slot, queries the last/best top set for seeding and PR
  /// detection, then builds the block list.
  Future<void> buildFromTemplate(
    DayTemplate template, {
    required ExerciseRepository exerciseRepo,
    required SessionRepository sessionRepo,
  }) async {
    final blocks = <BlockState>[];

    for (final slot in template.slots) {
      final exercise = await exerciseRepo.byId(slot.exerciseId);
      if (exercise == null) continue;

      final resolved = resolveSlot(slot, exercise);

      final lastTop = await sessionRepo.lastTopSet(slot.exerciseId);
      final bestKg = await sessionRepo.bestTopSet(slot.exerciseId);

      final block = buildBlock(
        resolved: resolved,
        lastTopKg: lastTop?.weight,
      );
      block.bestKg = bestKg;
      block.lastTop = lastTop;
      blocks.add(block);
    }

    expandOnlyFirst(blocks);
    _draft = SessionDraft(
      templateId: template.id,
      name: template.name,
      focus: template.focus ?? '',
      startedAt: DateTime.now(),
      blocks: blocks,
    );
    notifyListeners();
  }

  /// Seeds an empty session with no blocks (custom / ad-hoc workout).
  ///
  /// Used by the launcher's "Start empty" option before pushing
  /// [ActiveSessionScreen].
  void seedEmpty({required String name, required String focus}) {
    _draft = SessionDraft(
      templateId: null,
      name: name,
      focus: focus,
      startedAt: DateTime.now(),
      blocks: [],
    );
    notifyListeners();
  }

  /// Seeds the controller directly — for use in tests only.
  @visibleForTesting
  void seedForTest(SessionDraft draft) {
    _draft = draft;
    notifyListeners();
  }

  // ── Rest timer (app-scoped so it survives minimizing the screen) ─────────
  DateTime? restStart;
  int restTotal = 0;

  /// When the last rest ended (ran out or was skipped), for the header's
  /// "rested" count-up. In memory only, like the live set: null after a
  /// resume, and cleared when the next rest starts.
  DateTime? restEndedAt;

  bool get resting => restStart != null;

  void startRest(int seconds) {
    restStart = DateTime.now();
    restTotal = seconds;
    restEndedAt = null;
    notifyListeners();
  }

  void addRestTime(int seconds) {
    if (restStart == null) return;
    restTotal += seconds;
    notifyListeners();
  }

  /// Ends the rest. A late call (the app was backgrounded when it ran out)
  /// dates the end to when the countdown reached zero, not to now.
  void stopRest() {
    final start = restStart;
    if (start == null) return;
    final due = start.add(Duration(seconds: restTotal));
    final now = DateTime.now();
    restEndedAt = now.isBefore(due) ? now : due;
    restStart = null;
    restTotal = 0;
    notifyListeners();
  }

  /// Sets rest state directly (used to reconcile after a background +30s tap
  /// that the live controller didn't see). No-op if unchanged.
  void setRestRaw(DateTime? restStart, int restTotal) {
    if (this.restStart == restStart && this.restTotal == restTotal) return;
    this.restStart = restStart;
    this.restTotal = restTotal;
    notifyListeners();
  }

  // ── Live set (in-memory focus; never persisted — recomputed on resume) ──

  String? _focusedSetId;
  String? _rirPromptSetId;

  /// Closes the RIR strip. It has no timer: only an action on another set or
  /// a change to the set list closes it.
  void _closeRirPrompt() => _rirPromptSetId = null;

  /// Whether any set in the workout has been logged (warm-ups included): the
  /// header keeps its rest row from then on.
  bool get hasLoggedSet =>
      _draft?.blocks.any((b) => b.allSets.any((s) => s.done)) ?? false;

  LiveSet? _firstPending() {
    final d = _draft;
    if (d == null) return null;
    for (final b in d.blocks) {
      for (final s in b.allSets) {
        if (!s.done) return (block: b, set: s);
      }
    }
    return null;
  }

  /// The set the log bar acts on: the tapped set while it still exists,
  /// otherwise the first not-done set in on-screen order (blocks top to
  /// bottom, warm-ups before working sets). Null when every set is done.
  LiveSet? get liveSet {
    final d = _draft;
    if (d == null) return null;
    final focused = _focusedSetId;
    if (focused != null) {
      for (final b in d.blocks) {
        for (final s in b.allSets) {
          if (s.id == focused) return (block: b, set: s);
        }
      }
    }
    return _firstPending();
  }

  /// What the header's "Next ·" line names: the live set while it is still
  /// to do, otherwise the first set still to do. A logged set open for
  /// correction is never "next".
  LiveSet? get nextPendingSet {
    final live = liveSet;
    if (live != null && !live.set.done) return live;
    return _firstPending();
  }

  /// The logged set whose RIR strip is open, or null.
  String? get rirPromptSetId => _rirPromptSetId;

  /// Makes [set] the live set (a tap on its row). Closes the RIR strip: a
  /// tap on another set moves on, and a tap on the prompted set turns it
  /// into the live card.
  void focusSet(SetState set) {
    if (_focusedSetId == set.id && _rirPromptSetId == null) return;
    _focusedSetId = set.id;
    _closeRirPrompt();
    notifyListeners();
  }

  /// Logs the live set, or — when it is already logged — confirms the
  /// correction made in the live card. Focus then falls back to the first
  /// not-done set; when that is in another block, the block just finished
  /// collapses (only if every set in it is done) and the next one expands.
  /// A newly logged working set opens the RIR strip on it; anything else closes it.
  /// Returns null when there is no live set.
  ({BlockState block, SetState set, bool newlyDone})? logLiveSet() {
    final live = liveSet;
    if (live == null) return null;
    final newlyDone = !live.set.done;
    live.set.done = true;
    _focusedSetId = null;
    if (newlyDone && !live.set.isWarmup) {
      _rirPromptSetId = live.set.id;
    } else {
      _closeRirPrompt();
    }
    final next = liveSet;
    if (next != null && !identical(next.block, live.block)) {
      if (live.block.allSets.every((s) => s.done)) live.block.expanded = false;
      next.block.expanded = true;
    }
    notifyListeners();
    return (block: live.block, set: live.set, newlyDone: newlyDone);
  }

  /// Un-logs [set] and makes it the live set.
  void markNotDone(SetState set) {
    set.done = false;
    _focusedSetId = set.id;
    _closeRirPrompt();
    notifyListeners();
  }

  /// A tap on the RIR strip: stores [rir]; the strip stays open.
  void setRirFromPrompt(SetState set, int rir) {
    set.rir = rir;
    _rirPromptSetId = set.id;
    notifyListeners();
  }

  // ── Computed getters ──────────────────────────────────────────────────────

  /// Wall-clock elapsed since the session started.
  Duration get elapsed => DateTime.now().difference(draft.startedAt);

  /// Number of working sets that have been ticked done.
  int get doneWork => draft.blocks
      .expand((b) => b.workingSets)
      .where((s) => s.done)
      .length;

  /// Total number of working sets (done + not done).
  int get totalWork =>
      draft.blocks.fold(0, (n, b) => n + b.workingSets.length);

  /// Whether the session can be finished (at least one working set done).
  bool get canFinish => doneWork >= 1;

  /// Number of exercise blocks that have beaten their all-time best in this
  /// session (optimistic — the server's is_pr flags are authoritative after sync).
  int get prCount {
    var count = 0;
    for (final block in draft.blocks) {
      final maxDoneWorking = block.workingSets
          .where((s) => s.done)
          .fold<double>(0, (m, s) => s.weightKg > m ? s.weightKg : m);
      final best = block.bestKg;
      if (best == null || (maxDoneWorking > 0 && maxDoneWorking > best)) {
        if (maxDoneWorking > 0) count++;
      }
    }
    return count;
  }

  // ── Mutations ─────────────────────────────────────────────────────────────

  /// Notifies listeners after a caller mutates a [SetState] directly
  /// (e.g. weight/reps/RIR changed by a stepper — the set is mutated in-place
  /// by the UI and this method propagates the rebuild).
  void markChanged() => notifyListeners();

  /// Toggles [set] within [block] between done and not done.
  void toggleDone(BlockState block, SetState set) {
    set.done = !set.done;
    notifyListeners();
  }

  /// Appends a new working set to [block] (cloning weight/reps from the last
  /// working set in the block, or using the block's default suggested weight).
  void addSet(BlockState block) {
    final last = block.workingSets.isNotEmpty ? block.workingSets.last : null;
    final step = block.exercise.plateStepKg;
    final seed = block.resolved.exercise.baseWeightKg ?? 20.0;
    final suggested = roundTo(
      seed + (block.exercise.compound ? step : 0),
      step,
    );
    block.workingSets.add(SetState(
      id: uuid.v4(),
      weightKg: last?.weightKg ?? suggested,
      reps: last?.reps ?? block.resolved.repLow,
      rir: last?.rir ?? 1,
      isWarmup: false,
      done: false,
    ));
    _closeRirPrompt();
    notifyListeners();
  }

  /// Removes [set] (warm-up or working) from [block] and returns its index in
  /// its own list (-1 if it was not there), for [restoreSet].
  int removeSet(BlockState block, SetState set) {
    final list = set.isWarmup ? block.warmupSets : block.workingSets;
    final index = list.indexOf(set);
    list.remove(set);
    if (_focusedSetId == set.id) _focusedSetId = null;
    _closeRirPrompt();
    notifyListeners();
    return index;
  }

  /// Undo for [removeSet]: puts [set] back at [index] (clamped) in its own
  /// list. A no-op when the session has since finished/been discarded, or
  /// [block] has since left the workout.
  void restoreSet(BlockState block, SetState set, int index) {
    final d = draftOrNull;
    if (d == null || !d.blocks.contains(block)) return;
    final list = set.isWarmup ? block.warmupSets : block.workingSets;
    list.insert(index.clamp(0, list.length), set);
    _closeRirPrompt();
    notifyListeners();
  }

  /// Appends a warm-up set to [block], continuing the same ramp
  /// [buildBlock] uses: the i-th warm-up is `(0.5 + 0.18 * i)` of the first
  /// working set's weight (or, with no working set, the block's suggested
  /// weight), rounded to the plate step and never above it; reps
  /// `max(1, 8 - 2 * i)`.
  void addWarmupSet(BlockState block) {
    final step = block.exercise.plateStepKg;
    final seed = block.exercise.baseWeightKg ?? 20.0;
    final reference = block.workingSets.isNotEmpty
        ? block.workingSets.first.weightKg
        : roundTo(seed + (block.exercise.compound ? step : 0), step);
    final i = block.warmupSets.length;
    final weight = roundTo(reference * (0.5 + 0.18 * i), step);
    block.warmupSets.add(SetState(
      id: uuid.v4(),
      weightKg: weight > reference ? reference : weight,
      reps: max(1, 8 - 2 * i),
      rir: null,
      isWarmup: true,
      done: false,
    ));
    _closeRirPrompt();
    notifyListeners();
  }

  /// Moves [block] [delta] positions in the workout (negative = up). A move
  /// past either end is a no-op.
  void moveBlock(BlockState block, int delta) {
    final blocks = draft.blocks;
    final from = blocks.indexOf(block);
    final to = from + delta;
    if (from < 0 || to < 0 || to >= blocks.length || delta == 0) return;
    blocks
      ..removeAt(from)
      ..insert(to, block);
    _closeRirPrompt();
    notifyListeners();
  }

  /// Moves the block at [from] so it ends up at [to] (both indexes into the
  /// current list; [to] is the block's final position). Drag-and-drop uses
  /// this; an out-of-range or no-op move is ignored.
  void moveBlockTo(int from, int to) {
    final blocks = draft.blocks;
    if (from == to ||
        from < 0 ||
        to < 0 ||
        from >= blocks.length ||
        to >= blocks.length) {
      return;
    }
    blocks.insert(to, blocks.removeAt(from));
    _closeRirPrompt();
    notifyListeners();
  }

  /// Removes [block] from the session.
  void removeBlock(BlockState block) {
    draft.blocks.remove(block);
    _closeRirPrompt();
    notifyListeners();
  }

  /// Whether the workout already has a block for the exercise [exerciseId].
  bool hasExercise(String exerciseId) =>
      draft.blocks.any((b) => b.exercise.id == exerciseId);

  /// Appends a new block for [exercise] using the exercise's own defaults.
  /// Does nothing if the workout already has that exercise.
  ///
  /// Seeds the block from logged history exactly like [buildFromTemplate] so a
  /// mid-workout add shows previous data ("last time …"), a history-based
  /// suggested weight, and PR detection — for custom and template exercises
  /// alike. (Previously this skipped the lookup, so any added exercise read as
  /// "No previous data" even when it had history.)
  Future<void> addBlock(
    Exercise exercise, {
    required SessionRepository sessionRepo,
  }) async {
    // Build a default slot from the exercise's own defaults (no slot overrides).
    final slot = Slot(exerciseId: exercise.id, position: draft.blocks.length);
    final resolved = resolveSlot(slot, exercise);
    // A resumed workout's own finished rows stay in the DB until it is
    // finished again; exclude them so the PR baseline and the "Last" row are
    // the pre-workout ones (a fresh workout has no sessionId: no filter).
    final lastTop = await sessionRepo.lastTopSet(exercise.id,
        excludeSessionId: draft.sessionId);
    final bestKg = await sessionRepo.bestTopSet(exercise.id,
        excludeSessionId: draft.sessionId);
    // An exercise appears once per workout: blocks are keyed by exercise id
    // on screen. Checked after the lookups, so a second add that was already
    // in flight is dropped too.
    if (hasExercise(exercise.id)) return;
    final block = buildBlock(resolved: resolved, lastTopKg: lastTop?.weight);
    block.bestKg = bestKg;
    block.lastTop = lastTop;
    draft.blocks.add(block);
    _closeRirPrompt();
    notifyListeners();
  }

  // ── Finish ────────────────────────────────────────────────────────────────

  /// Snapshot of the last successful [finish]; null before one, and never set
  /// by [discard]. `shell/session_launcher.dart`'s `finishWorkout` is the
  /// production path: it hands this to `SessionManager.recordFinished` once
  /// the write transaction has COMMITTED — [finish] runs, and notifies,
  /// inside the transaction, before the commit.
  FinishedSession? get lastFinished => _lastFinished;
  FinishedSession? _lastFinished;

  /// Persists the session to the local PowerSync DB, clears the draft store,
  /// and clears the in-memory draft.
  ///
  /// A fresh draft gets a new session id; a resumed draft (non-null
  /// `sessionId`) replaces its own session in place, on its original date.
  /// Returns the session id. The caller must wrap this in a write transaction
  /// (`db.writeTransaction((tx) => controller.finish(PowerSyncTxExecutor(tx)))`)
  /// to ensure atomicity — `shell/session_launcher.dart`'s `finishWorkout` is
  /// the production path that does both: it runs this inside the caller's
  /// transaction and, only after that transaction commits, hands the
  /// resulting [lastFinished] to `SessionManager.recordFinished`. Pass
  /// [draftStore] to also clear the on-disk draft (call with the same
  /// [DraftStore] used to save the session while it was active).
  Future<String> finish(SqlExecutor executor, {DraftStore? draftStore}) async {
    final d = draft;
    final now = DateTime.now();
    final resumed = d.sessionId != null;
    final sessionId = d.sessionId ?? uuid.v4();
    final dateIso = d.sessionDate ?? isoDate(now);
    final splitLabel =
        d.focus.isEmpty ? d.name : '${d.name} · ${d.focus}'; // omit empty focus

    // Collect all sets: warm-ups (is_warmup=true) then working, per block.
    // set_number runs across the whole workout (not per exercise) — it is the
    // only persisted record of exercise order: History and the summary order
    // exercises by their first set_number (see SessionRepository.setsForSession).
    final sets = <SetWrite>[];
    var setNum = 1;
    for (final block in d.blocks) {
      final blockSets = <SetWrite>[];
      for (final s in block.warmupSets.where((s) => s.done)) {
        blockSets.add(SetWrite(
          id: s.id, exerciseId: block.exercise.id, setNumber: setNum++,
          weightKg: s.weightKg.toStringAsFixed(2), reps: s.reps, rir: null, isWarmup: true,
        ));
      }
      for (final s in block.workingSets.where((s) => s.done)) {
        blockSets.add(SetWrite(
          id: s.id, exerciseId: block.exercise.id, setNumber: setNum++,
          weightKg: s.weightKg.toStringAsFixed(2), reps: s.reps, rir: s.rir, isWarmup: false,
        ));
      }
      final topIdx = topSetIndex(blockSets);
      if (topIdx >= 0) {
        final top = blockSets[topIdx];
        final topWeight = double.tryParse(top.weightKg) ?? 0;
        final isPr = block.bestKg != null && topWeight > block.bestKg!;
        blockSets[topIdx] = SetWrite(
          id: top.id, exerciseId: top.exerciseId, setNumber: top.setNumber,
          weightKg: top.weightKg, reps: top.reps, rir: top.rir, isWarmup: top.isWarmup,
          isTopSet: true, isPr: isPr,
        );
      }
      sets.addAll(blockSets);
    }

    final elapsedAtFinish = now.difference(d.startedAt);
    final write = SessionWrite(
      id: sessionId,
      dateIso: dateIso,
      dayTemplateId: d.templateId,
      splitLabel: splitLabel,
      durationMin: (elapsedAtFinish.inSeconds / 60).round(),
      sets: sets,
    );

    if (resumed) {
      await replaceSession(executor, write);
    } else {
      await persistSession(executor, write);
    }

    // Clear the on-disk draft (if a store is provided) then the in-memory state.
    _saveDebounce?.cancel();
    _saveEpoch++;
    if (draftStore != null) {
      await SessionWriteLedger.instance.write('draft', draftStore.clear);
    }
    // Recorded only once nothing above can fail any more.
    _lastFinished = FinishedSession(
      sessionId: sessionId,
      sessionDate: dateIso,
      finishedAt: now,
      elapsedSeconds: elapsedAtFinish.inSeconds,
      draft: d.deepCopy(),
    );
    _draft = null;
    restStart = null;
    restTotal = 0;
    restEndedAt = null;
    _focusedSetId = null;
    _rirPromptSetId = null;
    notifyListeners();

    return sessionId;
  }

  /// Clears the in-memory draft without persisting, and deletes the draft
  /// file so a discarded workout cannot resurrect. Used when the user
  /// discards the session.
  ///
  /// One logical source operation: admitted before anything changes, so a
  /// refusal (a capture holds the source) throws and leaves the workout as
  /// it was. Completes once the file clear finished; its failure is thrown
  /// and stays observable to capture.
  Future<void> discard() => SessionWriteLedger.instance.track(
        runSourceWrite('session.discard', (_) async {
          _saveDebounce?.cancel();
          _saveEpoch++;
          _draft = null;
          restStart = null;
          restTotal = 0;
          restEndedAt = null;
          _focusedSetId = null;
          _rirPromptSetId = null;
          final store = _draftStore;
          final clearing = store == null
              ? null
              : SessionWriteLedger.instance.write('draft', store.clear);
          notifyListeners();
          await clearing;
        }),
      );
}
