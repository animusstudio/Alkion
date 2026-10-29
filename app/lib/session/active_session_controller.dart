import 'dart:async';
import 'notification_action.dart';
import 'dart:convert';
import 'dart:math' show max;

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../data/active_session_draft.dart';
import '../data/day_template_repository.dart'; // resolveSlot, DayTemplate
import '../data/exercise_repository.dart';
import '../data/finished_session_store.dart';
import '../data/models.dart';
import '../data/session_repository.dart';
import '../data/session_writer.dart';
import '../util/calendar_keys.dart';
import '../util/prescription_format.dart';
import '../settings/settings_service.dart';
import '../store/local_store.dart';

const uuid = Uuid();

// ── Pure helpers ─────────────────────────────────────────────────────────────

/// Conservative fresh-generation limits, independent of imported/resumed data.
const freshTemplateSlotLimit = 100;
const freshGeneratedSetLimit = 1000;

enum FreshSessionLimit { workingSets, warmupSets, templateSlots, generatedSets }

/// A prescription needs explicit correction; the source remains untouched.
class FreshSessionLimitException implements Exception {
  const FreshSessionLimitException(this.limit, {this.count, this.exerciseName});
  final FreshSessionLimit limit;
  final int? count;
  final String? exerciseName;
}

/// Fresh generation needs a qualified source prescription, never a mixed pair
/// or a policy that the lossless draft decoder cannot admit.
class FreshPrescriptionUnavailableException implements Exception {
  const FreshPrescriptionUnavailableException(
    this.exerciseName, {
    this.rirPolicy = false,
  });
  final String exerciseName;
  final bool rirPolicy;
}

ResolvedSlot resolveFreshPrescription(Slot slot, Exercise exercise) {
  final reps = resolveRepPair(slot, exercise);
  if (reps == null) throw FreshPrescriptionUnavailableException(exercise.name);
  final resolved = resolveSlot(slot, exercise);
  final result = ResolvedSlot(
    exercise: exercise,
    workSets: resolved.workSets,
    warmupSets: resolved.warmupSets,
    repLow: reps.low,
    repHigh: reps.high,
    rirLow: resolved.rirLow,
    rirHigh: resolved.rirHigh,
    rirState: resolved.rirState,
    rirPolicy: resolved.rirPolicy,
  );
  _validateFreshCounts(result);
  return result;
}

void _validateFreshCounts(ResolvedSlot resolved) {
  if (qualifiedRepPair(resolved.repLow, resolved.repHigh) == null) {
    throw FreshPrescriptionUnavailableException(resolved.exercise.name);
  }
  if (resolved.rirPolicy != null &&
      !const {
        RirPolicy.inherit,
        RirPolicy.off,
        RirPolicy.target,
      }.contains(resolved.rirPolicy)) {
    throw FreshPrescriptionUnavailableException(
      resolved.exercise.name,
      rirPolicy: true,
    );
  }
  if (resolved.rirState == RirTargetState.available &&
      (resolved.rirPolicy == RirPolicy.off ||
          resolved.rirLow == null ||
          resolved.rirHigh == null ||
          resolved.rirLow! < rirMin ||
          resolved.rirHigh! > rirMax ||
          resolved.rirLow! > resolved.rirHigh!)) {
    throw FreshPrescriptionUnavailableException(
      resolved.exercise.name,
      rirPolicy: true,
    );
  }
  if (resolved.workSets < 1 || resolved.workSets > 99) {
    throw FreshSessionLimitException(
      FreshSessionLimit.workingSets,
      count: resolved.workSets,
      exerciseName: resolved.exercise.name,
    );
  }
  if (resolved.warmupSets < 0 || resolved.warmupSets > 99) {
    throw FreshSessionLimitException(
      FreshSessionLimit.warmupSets,
      count: resolved.warmupSets,
      exerciseName: resolved.exercise.name,
    );
  }
}

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
/// Working sets use [suggested] weight and [repLow] reps; actual RIR is absent.
BlockState buildBlock({required ResolvedSlot resolved, double? lastTopKg}) {
  _validateFreshCounts(resolved);
  final exercise = resolved.exercise;
  final step = exercise.plateStepKg;

  // Seed: last known top weight beats base; 20 is the custom-only floor —
  // the seeded catalog always has base_weight_kg after the trait migration.
  final seed = lastTopKg ?? exercise.baseWeightKg ?? 20.0;

  // Compound exercises bump one plate on top of the seed to encourage
  // progressive overload; isolation exercises stay at the seed.
  final suggested = roundTo(seed + (exercise.compound ? step : 0), step);

  // Warm-up ramp
  final warmups = <SetState>[];
  for (var i = 0; i < resolved.warmupSets; i++) {
    warmups.add(
      SetState(
        id: uuid.v4(),
        weightKg: roundTo(suggested * (0.5 + 0.18 * i), step),
        reps: max(1, 8 - 2 * i),
        rir: null,
        isWarmup: true,
        done: false,
      ),
    );
  }

  // Working sets
  final working = <SetState>[];
  for (var i = 0; i < resolved.workSets; i++) {
    working.add(
      SetState(
        id: uuid.v4(),
        weightKg: suggested,
        reps: resolved.repLow,
        rir: null,
        isWarmup: false,
        done: false,
      ),
    );
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
  double _weightKg;
  double get weightKg => _weightKg;
  set weightKg(double v) {
    weightTouched = true;
    _weightKg = v;
  }

  Object? originalWeight;
  bool weightUnavailable = false;
  bool weightTouched;
  int? localRevision;
  String get weightText => weightTouched
      ? _weightKg.toStringAsFixed(2)
      : originalWeight?.toString() ?? '';
  Object? get persistedWeight => weightTouched
      ? _weightKg.toStringAsFixed(2)
      : (weightUnavailable ? null : originalWeight);
  int _reps;
  int get reps => _reps;
  set reps(int value) {
    repsTouched = true;
    _reps = value;
  }

  int? _rir;
  int? get rir => _rir;
  set rir(int? value) {
    rirTouched = true;
    _rir = value;
  }

  Map<String, Object?> rawFields;
  bool repsTouched, rirTouched;
  bool get repsAvailable =>
      repsTouched || !rawFields.containsKey('reps') || rawFields['reps'] is int;
  bool get weightAvailable =>
      weightTouched ||
      !weightUnavailable && double.tryParse(weightText)?.isFinite == true;
  Map<String, Object?> get rawUntouched => {
    if (!repsTouched && rawFields.containsKey('reps'))
      'reps': rawFields['reps'],
    if (!rirTouched && rawFields.containsKey('rir')) 'rir': rawFields['rir'],
    if (rawFields.containsKey('is_warmup')) 'is_warmup': rawFields['is_warmup'],
  };
  final bool isWarmup;
  bool done;

  SetState({
    required this.id,
    required double weightKg,
    this.originalWeight,
    this.weightTouched = false,
    this.localRevision,
    required int reps,
    required int? rir,
    this.rawFields = const {},
    this.repsTouched = false,
    this.rirTouched = false,
    required this.isWarmup,
    required this.done,
  }) : _weightKg = weightKg,
       _reps = reps,
       _rir = rir {
    originalWeight ??= weightKg.toString();
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'weightKg': weightKg,
    'originalWeight': persistedWeight,
    'weightUnavailable': weightUnavailable,
    'weightTouched': weightTouched,
    'localRevision': localRevision,
    'rawFields': rawFields,
    'repsTouched': repsTouched,
    'rirTouched': rirTouched,
    'reps': reps,
    'rir': rir,
    'isWarmup': isWarmup,
    'done': done,
  };

  factory SetState.fromJson(Map<String, dynamic> json) {
    final value = SetState(
      id: json['id'] as String,
      weightKg: (json['weightKg'] as num).toDouble(),
      originalWeight: json.containsKey('originalWeight')
          ? json['originalWeight']
          : (json['weightKg'] as num).toString(),
      weightTouched: json['weightTouched'] as bool? ?? false,
      localRevision: json['localRevision'] as int?,
      rawFields: Map<String, Object?>.from(json['rawFields'] as Map? ?? {}),
      repsTouched: json['repsTouched'] == true,
      rirTouched: json['rirTouched'] == true,
      reps: json['reps'] as int,
      rir: json['rir'] as int?,
      isWarmup: json['isWarmup'] as bool,
      done: json['done'] as bool,
    );
    value.weightUnavailable = json['weightUnavailable'] == true;
    return value;
  }
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
  bool lastTopUnavailable;

  BlockState({
    required this.exercise,
    required this.resolved,
    required this.warmupSets,
    required this.workingSets,
    required this.expanded,
    this.bestKg,
    this.lastTop,
    this.lastTopUnavailable = false,
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
    'resolvedRirState': resolved.rirState.name,
    'resolvedRirPolicy': resolved.rirPolicy,
    'warmupSets': warmupSets.map((s) => s.toJson()).toList(),
    'workingSets': workingSets.map((s) => s.toJson()).toList(),
    'expanded': expanded,
    'bestKg': bestKg,
    'lastTopWeight': lastTop?.weight,
    'lastTopReps': lastTop?.reps,
    'lastTopDate': lastTop?.date,
    'lastTopUnavailable': lastTopUnavailable,
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
    final rirLow = json['resolvedRirLow'] as int?;
    final rirHigh = json['resolvedRirHigh'] as int?;
    final rirPolicy = json['resolvedRirPolicy'] as String?;
    final qualifiedRir =
        rirLow != null &&
        rirHigh != null &&
        rirLow >= rirMin &&
        rirHigh <= rirMax &&
        rirLow <= rirHigh;
    final hasRirMetadata =
        json.containsKey('resolvedRirPolicy') ||
        json.containsKey('resolvedRirState');
    final RirTargetState rirState;
    if (hasRirMetadata) {
      // New metadata is an admission boundary. Unknown literals must stay in
      // the original draft bytes, never become an enabled target or normalize
      // into a known value when the draft is reserialized.
      if (rirPolicy != null &&
          !const {
            RirPolicy.inherit,
            RirPolicy.off,
            RirPolicy.target,
          }.contains(rirPolicy)) {
        throw const FormatException('Unknown draft RIR policy');
      }
      rirState = switch (json['resolvedRirState']) {
        'available' => RirTargetState.available,
        'unavailable' => RirTargetState.unavailable,
        'absent' => RirTargetState.absent,
        _ => throw const FormatException('Unknown draft RIR state'),
      };
      if (rirState == RirTargetState.available &&
          (!qualifiedRir || rirPolicy == RirPolicy.off)) {
        throw const FormatException('Unqualified draft RIR target');
      }
    } else {
      // Old numeric drafts remain readable, including retained invalid pairs.
      // Their bounds/observations stay exact; invalid targets are unavailable.
      rirState = qualifiedRir
          ? RirTargetState.available
          : rirLow == null && rirHigh == null
          ? RirTargetState.absent
          : RirTargetState.unavailable;
    }
    final resolved = ResolvedSlot(
      exercise: exercise,
      workSets: json['resolvedWorkSets'] as int,
      warmupSets: json['resolvedWarmupSets'] as int,
      repLow: json['resolvedRepLow'] as int,
      repHigh: json['resolvedRepHigh'] as int,
      rirLow: rirLow,
      rirHigh: rirHigh,
      rirPolicy: rirPolicy,
      rirState: rirState,
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
      lastTopUnavailable: json['lastTopUnavailable'] == true,
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
  final Map<String, Object?>? sessionDateEvidence;
  final String? identity;
  String get draftId => identity ?? 'draft:${startedAt.toIso8601String()}';
  final int? localRevision;
  final Map<String, int> setBases;
  final DateTime? restStart, restEndedAt;
  final int restTotal;
  final String? focusedSetId, rirPromptSetId;
  Map<String, Object?> get timerJson => {
    'draftId': draftId,
    'startedAt': startedAt.toIso8601String(),
    'restStart': restStart?.toIso8601String(),
    'restTotal': restTotal,
    'restEndedAt': restEndedAt?.toIso8601String(),
  };

  const SessionDraft({
    required this.templateId,
    required this.name,
    required this.focus,
    required this.startedAt,
    required this.blocks,
    this.sessionId,
    this.sessionDate,
    this.sessionDateEvidence,
    this.identity,
    this.localRevision,
    this.setBases = const {},
    this.restStart,
    this.restTotal = 0,
    this.restEndedAt,
    this.focusedSetId,
    this.rirPromptSetId,
  });

  Map<String, dynamic> toJson() => {
    'templateId': templateId,
    'name': name,
    'focus': focus,
    'startedAt': startedAt.toIso8601String(),
    'blocks': blocks.map((b) => b.toJson()).toList(),
    'sessionId': sessionId,
    'sessionDate': sessionDate,
    'sessionDateEvidence': sessionDateEvidence,
    'draftId': draftId,
    'localRevision': localRevision,
    'setBases': setBases,
    'restStart': restStart?.toIso8601String(),
    'restTotal': restTotal,
    'restEndedAt': restEndedAt?.toIso8601String(),
    'focusedSetId': focusedSetId,
    'rirPromptSetId': rirPromptSetId,
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
    sessionDateEvidence: json['sessionDateEvidence'] == null
        ? null
        : Map<String, Object?>.from(json['sessionDateEvidence'] as Map),
    identity: json['draftId'] as String?,
    localRevision: json['localRevision'] as int?,
    setBases: Map<String, int>.from(json['setBases'] as Map? ?? {}),
    restStart: DateTime.tryParse(json['restStart'] as String? ?? ''),
    restTotal: json['restTotal'] as int? ?? 0,
    restEndedAt: DateTime.tryParse(json['restEndedAt'] as String? ?? ''),
    focusedSetId: json['focusedSetId'] as String?,
    rirPromptSetId: json['rirPromptSetId'] as String?,
  );

  /// An independent copy made through the same JSON path the draft files use,
  /// so no [BlockState]/[SetState] is shared with this draft.
  SessionDraft deepCopy() => SessionDraft.fromJson(
    jsonDecode(jsonEncode(toJson())) as Map<String, dynamic>,
  );
}

// ── ActiveSessionController ──────────────────────────────────────────────────

/// Manages the in-memory state of an active workout session.
///
/// Call [buildFromTemplate] to initialise from a [DayTemplate]; or
/// [seedForTest] in unit tests to inject a ready-made draft.
///
/// All state mutations (toggleDone, addSet, etc.) call [notifyListeners] so
/// that Provider-wired widgets rebuild automatically.
typedef _RestState = ({DateTime? start, int total, DateTime? endedAt});

class ActiveSessionController extends ChangeNotifier {
  /// [draftStore] enables debounced autosave of the in-progress draft (used
  /// for resume-on-launch). Null (e.g. in unit tests) disables persistence.
  ActiveSessionController({DraftStore? draftStore}) : _draftStore = draftStore;

  /// Adopts a previously persisted draft (resume-on-launch / crash recovery).
  ActiveSessionController.fromDraft(
    SessionDraft draft, {
    DraftStore? draftStore,
  }) : _draftStore = draftStore,
       _draft = draft {
    restStart = draft.restStart;
    restTotal = draft.restTotal;
    restEndedAt = draft.restEndedAt;
    _focusedSetId = draft.focusedSetId;
    _rirPromptSetId = draft.rirPromptSetId;
  }

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
  bool _notificationActionPending = false;
  _RestState? _notificationRestBefore;
  List<_RestState Function(_RestState)>? _notificationRestEdits;
  bool get notificationActionUncertain =>
      _draftStore?.pendingNotificationAction != null;

  /// Whether a capture froze autosave and rest auto-stop.
  bool get callbacksFrozen =>
      _frozenGeneration != null ||
      _pendingFinish != null ||
      _notificationActionPending;

  /// [callbacksFrozen] as a listenable, for what the screen shows as
  /// unavailable while a capture holds the source (the +30s rest chip).
  /// Kept apart from [notifyListeners], which schedules an autosave.
  ValueListenable<bool> get captureFrozen => _captureFrozen;
  final _captureFrozen = ValueNotifier<bool>(false);

  @override
  void notifyListeners() {
    _scheduleSave();
    super.notifyListeners();
  }

  void _scheduleSave() {
    final store = _draftStore;
    final d = _draft;
    if (store == null || d == null || finishPending) {
      return;
    }
    _saveDebounce?.cancel();
    _saveDebounce = null;
    final epoch = ++_saveEpoch;
    if (callbacksFrozen) {
      _savePending = true;
      return;
    }
    // Copied now: the autosave writes the state it was scheduled for.
    _armSave(store, snapshot(), epoch);
  }

  Object? persistenceError;
  Future<void> _persistenceTail = Future.value();
  bool get persistenceOwed =>
      _savePending ||
      _draftStore?.pending != null ||
      notificationActionUncertain;

  void _beginNotificationRest() {
    _notificationRestBefore = (
      start: restStart,
      total: restTotal,
      endedAt: restEndedAt,
    );
    _notificationRestEdits = [];
  }

  bool _adoptNotificationRest(CommittedRestChange? committed) {
    if (committed != null) {
      _RestState state = (
        start: committed.restStart,
        total: committed.restTotal,
        endedAt: _notificationRestBefore?.endedAt,
      );
      for (final edit
          in _notificationRestEdits ?? <_RestState Function(_RestState)>[]) {
        state = edit(state);
      }
      restStart = state.start;
      restTotal = state.total;
      restEndedAt = state.endedAt;
    }
    final action = _draftStore?.pendingNotificationAction;
    if (action != null) {
      _draftStore!.acknowledgeNotificationAction(action);
    }
    _notificationRestBefore = null;
    _notificationRestEdits = null;
    return committed != null;
  }

  Future<bool> _reconcileNotificationAction(DraftStore store) async {
    if (store.pendingNotificationAction == null) return false;
    final adopted = _adoptNotificationRest(
      await store.reconcileNotificationAction(),
    );
    persistenceError = null;
    return adopted;
  }

  SessionDraft snapshot() {
    final json = draft.toJson()
      ..addAll({
        'restStart': restStart?.toIso8601String(),
        'restTotal': restTotal,
        'restEndedAt': restEndedAt?.toIso8601String(),
        'focusedSetId': _focusedSetId,
        'rirPromptSetId': _rirPromptSetId,
      });
    return SessionDraft.fromJson(json);
  }

  void _armSave(DraftStore store, SessionDraft copy, int epoch) {
    _savePending = true;
    _saveDebounce = Timer(saveDebounce, () {
      if (epoch != _saveEpoch || callbacksFrozen || _pendingFinish != null) {
        return;
      }
      _persistenceTail = _persistenceTail.then((_) async {
        if (epoch != _saveEpoch || callbacksFrozen || _pendingFinish != null) {
          return;
        }
        var reconciled = false;
        try {
          final uncertain = notificationActionUncertain;
          reconciled = await _reconcileNotificationAction(store);
          final saved = uncertain ? snapshot() : copy;
          if (store.pending != null) {
            await store.save(saved);
          }
          if (epoch != _saveEpoch) {
            return;
          }
          await store.save(saved);
          if (epoch == _saveEpoch) {
            _savePending = false;
          }
          persistenceError = null;
        } catch (e) {
          persistenceError = e;
          _savePending = true;
        } finally {
          if (reconciled) super.notifyListeners();
        }
      });
    });
  }

  /// Lifecycle/transfer/backup/close barrier. Failures leave exact work owed.
  Future<void> flushPersistence() {
    final finishing = _finishInFlight;
    if (finishing != null) return finishing.then<void>((_) {});
    _saveDebounce?.cancel();
    final epoch = ++_saveEpoch;
    final work = _persistenceTail.then<void>((_) async {
      final store = _draftStore;
      if (store == null || _draft == null) return;
      if (_pendingFinish != null) {
        throw const StoreException('finish_retry_required');
      }
      var reconciled = false;
      try {
        reconciled = await _reconcileNotificationAction(store);
        if (_pendingFinish != null) {
          throw const StoreException('finish_retry_required');
        }
        if (!_savePending && store.pending == null) return;
        // Settle the already frozen older save. Finish may have prepared while
        // that write awaited SQL; it owns the next transition from this base.
        if (store.pending != null) {
          await store.save(snapshot());
          if (_pendingFinish != null) {
            throw const StoreException('finish_retry_required');
          }
        }
        await store.save(snapshot());
        if (epoch == _saveEpoch) _savePending = false;
        persistenceError = null;
      } catch (error) {
        persistenceError = error;
        _savePending = true;
        rethrow;
      } finally {
        if (reconciled) super.notifyListeners();
      }
    });
    // Every explicit flush and autosave shares one tail. Keep the returned
    // failure visible while allowing recovery/Finish to await a settled tail.
    _persistenceTail = work.then<void>(
      (_) {},
      onError: (Object error, StackTrace stack) {},
    );
    // A queued flush may meet Finish after admission. Join its outcome only
    // outside the internal tail that Finish itself waits for.
    return work.catchError((Object error, StackTrace stack) {
      final finishing = _finishInFlight;
      if (finishing != null &&
          error is StoreException &&
          error.category == 'finish_retry_required') {
        return finishing.then<void>((_) {});
      }
      Error.throwWithStackTrace(error, stack);
    });
  }

  /// Shares the autosave tail. Pending edits settle first; no older snapshot
  /// may overwrite the action's committed rest, and finish cannot prepare from
  /// the old revision while the action is in flight.
  Future<bool> applyNotificationAction(NotificationAction action) {
    final store = _draftStore;
    if (store == null || _draft == null || callbacksFrozen) {
      return Future.value(false);
    }
    _notificationActionPending = true;
    _captureFrozen.value = true;
    _saveDebounce?.cancel();
    final epoch = ++_saveEpoch;
    final previousAction = store.pendingNotificationAction;
    if (previousAction == null) _beginNotificationRest();
    final work = _persistenceTail.then((_) async {
      var adopted = false;
      try {
        adopted = await _reconcileNotificationAction(store);
        if (_savePending || store.pending != null) {
          if (store.pending != null) await store.save(snapshot());
          await store.save(snapshot());
          if (epoch == _saveEpoch) _savePending = false;
        }
        if (_frozenGeneration != null || finishPending || _draft == null) {
          return false;
        }
        if (previousAction?.encode() == action.encode()) return adopted;
        if (_notificationRestEdits == null) _beginNotificationRest();
        final committed = await store.consumeAction(action);
        adopted = _adoptNotificationRest(committed) || adopted;
        if (committed == null) return false;
        persistenceError = null;
        // This state is already durable. Ordinary listeners must not autosave
        // the pre-action rest or create a second consumption.
        return true;
      } catch (error) {
        persistenceError = error;
        rethrow;
      } finally {
        _notificationActionPending = false;
        _captureFrozen.value = callbacksFrozen;
        if (_savePending) _scheduleSave();
        if (!notificationActionUncertain) {
          _notificationRestBefore = null;
          _notificationRestEdits = null;
        }
        if (adopted) super.notifyListeners();
      }
    });
    _persistenceTail = work.then<void>((_) {}, onError: (Object error) {});
    return work;
  }

  /// Moves on whenever the draft's persisted state may become stale; the
  /// capture compares it to know whether its flush covered every change.
  int get saveEpoch => _saveEpoch;

  /// Stops autosave and rest auto-stop for capture [generation]: the pending
  /// debounce is cancelled and already scheduled callbacks are fenced. Later
  /// mutations stay in memory until [resumeCallbacks].
  void freezeCallbacks(int generation) {
    if (_saveDebounce?.isActive ?? false) {
      _savePending = true;
    }
    _saveDebounce?.cancel();
    _saveDebounce = null;
    _saveEpoch++;
    _frozenGeneration = generation;
    _captureFrozen.value = true;
  }

  /// The capture's flush of the draft as it was at [epoch] landed: nothing
  /// is owed unless the draft was scheduled for saving again since.
  void markFlushed(int epoch) {
    if (epoch == _saveEpoch) {
      _savePending = false;
    }
  }

  /// Ends a freeze (or, unfrozen, settles what a refused autosave still
  /// owes): a rest whose countdown ran out meanwhile ends at its due time
  /// (no silent extension, no timer continuity), and an owed save or a
  /// mutation made while frozen is autosaved.
  void resumeCallbacks(DateTime now) {
    _frozenGeneration = null;
    _captureFrozen.value = _pendingFinish != null;
    if (_pendingFinish != null) {
      return;
    }
    if (notificationActionUncertain) {
      unawaited(
        flushPersistence().then((_) => resumeCallbacks(now)).catchError((
          Object error,
        ) {
          persistenceError = error;
        }),
      );
      return;
    }
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
    _captureFrozen.dispose();
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
    // Count all slots, including unresolved references, before any lookup.
    if (template.slots.length > freshTemplateSlotLimit) {
      throw FreshSessionLimitException(
        FreshSessionLimit.templateSlots,
        count: template.slots.length,
      );
    }
    final prescriptions = <ResolvedSlot>[];
    var remaining = freshGeneratedSetLimit;
    for (final slot in template.slots) {
      final exercise = await exerciseRepo.byId(slot.exerciseId);
      if (exercise == null) {
        continue;
      }

      final resolved = resolveFreshPrescription(slot, exercise);
      _validateFreshCounts(resolved);
      // Subtract only validated bounded counts; stop before exceeding the cap.
      if (resolved.workSets > remaining ||
          resolved.warmupSets > remaining - resolved.workSets) {
        throw FreshSessionLimitException(
          FreshSessionLimit.generatedSets,
          exerciseName: exercise.name,
        );
      }
      remaining -= resolved.workSets + resolved.warmupSets;
      prescriptions.add(resolved);
    }

    // No generated block, per-set UUID or draft mutation precedes preflight.
    final blocks = <BlockState>[];
    for (final resolved in prescriptions) {
      final exerciseId = resolved.exercise.id;
      final reference = await sessionRepo.lastTopSetEvidence(exerciseId);
      final lastTop = reference.value;
      final bestKg = await sessionRepo.bestTopSet(exerciseId);

      final block = buildBlock(resolved: resolved, lastTopKg: lastTop?.weight);
      block.bestKg = bestKg;
      block.lastTop = lastTop;
      block.lastTopUnavailable = reference.unavailable;
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
    if (finishPending) {
      throw const StoreException('finish_retry_required');
    }
    final start = DateTime.now();
    // Log Set remains responsive. Its new rest is ordered after the in-flight
    // notification, with the tap's absolute start rather than a later retry.
    _notificationRestEdits?.add(
      (_) => (start: start, total: seconds, endedAt: null),
    );
    restStart = start;
    restTotal = seconds;
    restEndedAt = null;
    notifyListeners();
  }

  /// Extends the running rest. Refused while a capture froze the callbacks:
  /// the extension is shown as unavailable then, never applied silently.
  void addRestTime(int seconds) {
    if (finishPending) {
      throw const StoreException('finish_retry_required');
    }
    if (restStart == null || callbacksFrozen) {
      return;
    }
    _notificationRestEdits?.add(
      (state) => (
        start: state.start,
        total: state.start == null ? state.total : state.total + seconds,
        endedAt: state.endedAt,
      ),
    );
    restTotal += seconds;
    notifyListeners();
  }

  /// Ends the rest. A late call (the app was backgrounded when it ran out)
  /// dates the end to when the countdown reached zero, not to now.
  void stopRest() {
    if (finishPending) {
      throw const StoreException('finish_retry_required');
    }
    final start = restStart;
    if (start == null) {
      return;
    }
    final due = start.add(Duration(seconds: restTotal));
    final now = DateTime.now();
    _notificationRestEdits?.add((state) {
      final deadline = state.start?.add(Duration(seconds: state.total));
      return (
        start: null,
        total: 0,
        endedAt: deadline == null
            ? state.endedAt
            : now.isBefore(deadline)
            ? now
            : deadline,
      );
    });
    restEndedAt = now.isBefore(due) ? now : due;
    restStart = null;
    restTotal = 0;
    notifyListeners();
  }

  /// Sets rest state directly (used to reconcile after a background +30s tap
  /// that the live controller didn't see). No-op if unchanged.
  void setRestRaw(DateTime? restStart, int restTotal) {
    if (finishPending) {
      throw const StoreException('finish_retry_required');
    }
    if (this.restStart == restStart && this.restTotal == restTotal) {
      return;
    }
    _notificationRestEdits?.add(
      (state) => (start: restStart, total: restTotal, endedAt: state.endedAt),
    );
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
    if (d == null) {
      return null;
    }
    for (final b in d.blocks) {
      for (final s in b.allSets) {
        if (!s.done) {
          return (block: b, set: s);
        }
      }
    }
    return null;
  }

  /// The set the log bar acts on: the tapped set while it still exists,
  /// otherwise the first not-done set in on-screen order (blocks top to
  /// bottom, warm-ups before working sets). Null when every set is done.
  LiveSet? get liveSet {
    final d = _draft;
    if (d == null) {
      return null;
    }
    final focused = _focusedSetId;
    if (focused != null) {
      for (final b in d.blocks) {
        for (final s in b.allSets) {
          if (s.id == focused) {
            return (block: b, set: s);
          }
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
    if (live != null && !live.set.done) {
      return live;
    }
    return _firstPending();
  }

  /// The logged set whose RIR strip is open, or null.
  String? get rirPromptSetId => _rirPromptSetId;

  /// Makes [set] the live set (a tap on its row). Closes the RIR strip: a
  /// tap on another set moves on, and a tap on the prompted set turns it
  /// into the live card.
  void focusSet(SetState set) {
    if (finishPending) {
      throw const StoreException('finish_retry_required');
    }
    if (_focusedSetId == set.id && _rirPromptSetId == null) {
      return;
    }
    _focusedSetId = set.id;
    _closeRirPrompt();
    notifyListeners();
  }

  /// Logs the live set, or — when it is already logged — confirms the
  /// correction made in the live card. Focus then falls back to the first
  /// not-done set; when that is in another block, the block just finished
  /// collapses (only if every set in it is done) and the next one expands.
  /// A valid target may offer the optional RIR strip; no-target logging closes it.
  /// Returns null when there is no live set.
  ({BlockState block, SetState set, bool newlyDone})? logLiveSet() {
    final live = liveSet;
    if (live == null) {
      return null;
    }
    final newlyDone = !live.set.done;
    live.set.done = true;
    _focusedSetId = null;
    if (newlyDone && !live.set.isWarmup && live.block.resolved.hasRirTarget) {
      _rirPromptSetId = live.set.id;
    } else {
      _closeRirPrompt();
    }
    final next = liveSet;
    if (next != null && !identical(next.block, live.block)) {
      if (live.block.allSets.every((s) => s.done)) {
        live.block.expanded = false;
      }
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
  void setRirFromPrompt(SetState set, int? rir) {
    set.rir = rir;
    _rirPromptSetId = set.id;
    notifyListeners();
  }

  // ── Computed getters ──────────────────────────────────────────────────────

  /// Wall-clock elapsed since the session started.
  Duration get elapsed => DateTime.now().difference(draft.startedAt);

  /// Number of working sets that have been ticked done.
  int get doneWork =>
      draft.blocks.expand((b) => b.workingSets).where((s) => s.done).length;

  /// Total number of working sets (done + not done).
  int get totalWork => draft.blocks.fold(0, (n, b) => n + b.workingSets.length);

  /// Whether the session can be finished (at least one working set done).
  bool get canFinish => doneWork >= 1;

  /// Number of exercise blocks that have beaten their all-time best in this
  /// session, using the current local best evidence.
  int get prCount {
    var count = 0;
    for (final block in draft.blocks) {
      final maxDoneWorking = block.workingSets
          .where((s) => s.done)
          .fold<double>(0, (m, s) => s.weightKg > m ? s.weightKg : m);
      final best = block.bestKg;
      if (best == null || (maxDoneWorking > 0 && maxDoneWorking > best)) {
        if (maxDoneWorking > 0) {
          count++;
        }
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
    if (finishPending) {
      throw const StoreException('finish_retry_required');
    }
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
    block.workingSets.add(
      SetState(
        id: uuid.v4(),
        weightKg: last?.weightKg ?? suggested,
        reps: last?.reps ?? block.resolved.repLow,
        rir: null,
        isWarmup: false,
        done: false,
      ),
    );
    _closeRirPrompt();
    notifyListeners();
  }

  /// Removes [set] (warm-up or working) from [block] and returns its index in
  /// its own list (-1 if it was not there), for [restoreSet].
  int removeSet(BlockState block, SetState set) {
    final list = set.isWarmup ? block.warmupSets : block.workingSets;
    final index = list.indexOf(set);
    list.remove(set);
    if (_focusedSetId == set.id) {
      _focusedSetId = null;
    }
    _closeRirPrompt();
    notifyListeners();
    return index;
  }

  /// Undo for [removeSet]: puts [set] back at [index] (clamped) in its own
  /// list. A no-op when the session has since finished/been discarded, or
  /// [block] has since left the workout.
  void restoreSet(BlockState block, SetState set, int index) {
    final d = draftOrNull;
    if (d == null || !d.blocks.contains(block)) {
      return;
    }
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
    block.warmupSets.add(
      SetState(
        id: uuid.v4(),
        weightKg: weight > reference ? reference : weight,
        reps: max(1, 8 - 2 * i),
        rir: null,
        isWarmup: true,
        done: false,
      ),
    );
    _closeRirPrompt();
    notifyListeners();
  }

  /// Moves [block] [delta] positions in the workout (negative = up). A move
  /// past either end is a no-op.
  void moveBlock(BlockState block, int delta) {
    if (finishPending) {
      throw const StoreException('finish_retry_required');
    }
    final blocks = draft.blocks;
    final from = blocks.indexOf(block);
    final to = from + delta;
    if (from < 0 || to < 0 || to >= blocks.length || delta == 0) {
      return;
    }
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
    if (finishPending) {
      throw const StoreException('finish_retry_required');
    }
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
    if (finishPending) {
      throw const StoreException('finish_retry_required');
    }
    draft.blocks.remove(block);
    _closeRirPrompt();
    notifyListeners();
  }

  /// Whether the workout already has a block for the exercise [exerciseId].
  bool hasExercise(String exerciseId) =>
      draft.blocks.any((b) => b.exercise.id == exerciseId);

  /// Appends a new block using qualified exercise defaults and captured
  /// creation choices, without recomputing any existing block.
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
    RepEntry repEntry = RepEntry.fixed,
    RirControls rirControls = RirControls.off,
  }) async {
    // Build a default slot from the exercise's own defaults (no slot overrides).
    final hasRepEvidence =
        exercise.defaultRepLow != null ||
        exercise.defaultRepHigh != null ||
        exercise.rawFields['default_rep_low'] != null ||
        exercise.rawFields['default_rep_high'] != null;
    final slot = Slot(
      exerciseId: exercise.id,
      position: draft.blocks.length,
      repLow: hasRepEvidence ? null : 8,
      repHigh: hasRepEvidence
          ? null
          : repEntry == RepEntry.range
          ? 12
          : 8,
      rirPolicy: rirControls == RirControls.off
          ? RirPolicy.off
          : RirPolicy.inherit,
    );
    final resolved = resolveFreshPrescription(slot, exercise);
    _validateFreshCounts(resolved);
    // A resumed workout's own finished rows stay in the DB until it is
    // finished again; exclude them so the PR baseline and the "Last" row are
    // the pre-workout ones (a fresh workout has no sessionId: no filter).
    final reference = await sessionRepo.lastTopSetEvidence(
      exercise.id,
      excludeSessionId: draft.sessionId,
    );
    final lastTop = reference.value;
    final bestKg = await sessionRepo.bestTopSet(
      exercise.id,
      excludeSessionId: draft.sessionId,
    );
    // An exercise appears once per workout: blocks are keyed by exercise id
    // on screen. Checked after the lookups, so a second add that was already
    // in flight is dropped too.
    if (hasExercise(exercise.id)) {
      return;
    }
    final block = buildBlock(resolved: resolved, lastTopKg: lastTop?.weight);
    block.bestKg = bestKg;
    block.lastTop = lastTop;
    block.lastTopUnavailable = reference.unavailable;
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

  /// Prepared finish intent and snapshot retained until the local workflow
  /// commits or reconciles. Preserve a resumed workout's identity and date;
  /// only publish [lastFinished] after commitFinish succeeds.
  PreparedDomainAction? _pendingFinish;
  FinishedSession? _pendingRecovery;
  Future<String>? _finishInFlight;
  PreparedDomainAction? get pendingFinish => _pendingFinish;
  bool get finishPending => _pendingFinish != null;

  PreparedDomainAction prepareFinish(
    WorkoutRepository repository, {
    DateTime? at,
  }) {
    if (_notificationActionPending || notificationActionUncertain) {
      throw const StoreException('notification_action_pending');
    }
    if (_pendingFinish != null) {
      return _pendingFinish!;
    }
    final now = at ?? DateTime.now();
    final d = snapshot();
    final sessionId = d.sessionId ?? uuid.v4();
    final dateIso = d.sessionDate ?? (d.sessionId == null ? isoDate(now) : '');
    final splitLabel = d.focus.isEmpty
        ? d.name
        : '${d.name} · ${d.focus}'; // omit empty focus

    // Collect all sets: warm-ups (is_warmup=true) then working, per block.
    // set_number runs across the whole workout (not per exercise) — it is the
    // only persisted record of exercise order: History and the summary order
    // exercises by their first set_number (see SessionRepository.setsForSession).
    final sets = <SetWrite>[];
    var setNum = 1;
    for (final block in d.blocks) {
      final blockSets = <SetWrite>[];
      for (final s in block.warmupSets.where((s) => s.done)) {
        blockSets.add(
          SetWrite(
            id: s.id,
            exerciseId: block.exercise.id,
            setNumber: setNum++,
            weightKg: s.persistedWeight,
            reps: s.reps,
            rawUntouched: s.rawUntouched,
            rir: null,
            isWarmup: true,
          ),
        );
      }
      for (final s in block.workingSets.where((s) => s.done)) {
        blockSets.add(
          SetWrite(
            id: s.id,
            exerciseId: block.exercise.id,
            setNumber: setNum++,
            weightKg: s.persistedWeight,
            reps: s.reps,
            rawUntouched: s.rawUntouched,
            rir: s.rir,
            isWarmup: false,
          ),
        );
      }
      final topIdx = topSetIndex(blockSets);
      if (topIdx >= 0) {
        final top = blockSets[topIdx];
        final topWeight = double.tryParse(top.weightKg?.toString() ?? '') ?? 0;
        final isPr = block.bestKg != null && topWeight > block.bestKg!;
        blockSets[topIdx] = SetWrite(
          id: top.id,
          exerciseId: top.exerciseId,
          setNumber: top.setNumber,
          weightKg: top.weightKg,
          reps: top.reps,
          rawUntouched: top.rawUntouched,
          rir: top.rir,
          isWarmup: top.isWarmup,
          isTopSet: true,
          isPr: isPr,
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

    final store = _draftStore;
    if (store == null || store.database == null) {
      throw const StoreException('local_store_required');
    }
    final recovery = FinishedSession(
      sessionId: sessionId,
      sessionDate: dateIso,
      finishedAt: now,
      elapsedSeconds: elapsedAtFinish.inSeconds,
      draft: d,
    );
    _pendingRecovery = recovery;
    _pendingFinish = repository.prepareFinish(
      write: write,
      baseRevision: d.localRevision ?? 0,
      setBases: d.setBases,
      recovery: recovery.toJson(),
      draftRevision: store.pending == null
          ? store.persistedRevision
          : store.pending!.expectedRevision + 1,
      draftId: d.draftId,
    );
    _saveDebounce?.cancel();
    _saveEpoch++;
    _captureFrozen.value = true;
    super.notifyListeners();
    return _pendingFinish!;
  }

  Future<String> commitFinish(WorkoutRepository repository) {
    final finishing = _finishInFlight;
    if (finishing != null) return finishing;
    final previousPersistence = _persistenceTail;
    final completion = Completer<String>();
    // Install before prepareFinish synchronously notifies persistence listeners.
    _finishInFlight = completion.future;
    _commitFinish(repository, previousPersistence).then(
      (id) {
        _finishInFlight = null;
        completion.complete(id);
      },
      onError: (Object error, StackTrace stack) {
        _finishInFlight = null;
        completion.completeError(error, stack);
      },
    );
    return completion.future;
  }

  Future<String> _commitFinish(
    WorkoutRepository repository,
    Future<void> previousPersistence,
  ) async {
    final intent = prepareFinish(repository);
    final finished = _pendingRecovery!;
    await previousPersistence;
    final store = _draftStore;
    if (store?.pending != null) {
      await store!.save(snapshot());
    }
    await repository.commitPrepared(intent);
    // Only successfully awaited COMMIT or exact-byte replay adopts success.
    _lastFinished = finished;
    persistenceError = null;
    _draftStore?.completed();
    _pendingFinish = null;
    _pendingRecovery = null;
    _captureFrozen.value = _frozenGeneration != null;
    _saveDebounce?.cancel();
    _saveEpoch++;
    _savePending = false;
    _draft = null;
    restStart = null;
    restTotal = 0;
    restEndedAt = null;
    _focusedSetId = null;
    _rirPromptSetId = null;
    super.notifyListeners();
    return intent.action.target.id;
  }

  Future<String> finish(
    SqlExecutor executor, {
    DraftStore? draftStore,
    DateTime? now,
  }) => Future.error(const StoreException('prepared_workout_required'));

  Future<void> discard() async {
    if (_notificationActionPending) {
      throw const StoreException('notification_action_pending');
    }
    if (_pendingFinish != null) {
      throw const StoreException('finish_retry_required');
    }
    _saveDebounce?.cancel();
    _saveEpoch++;
    await _persistenceTail;
    final store = _draftStore;
    if (store != null) {
      await _reconcileNotificationAction(store);
      if (store.pending != null) {
        await store.save(snapshot());
      }
      await store.clear();
    }
    _draft = null;
    restStart = null;
    restTotal = 0;
    restEndedAt = null;
    _focusedSetId = null;
    _rirPromptSetId = null;
    _savePending = false;
    super.notifyListeners();
  }
}
