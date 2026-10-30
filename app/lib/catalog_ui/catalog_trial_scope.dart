import 'package:flutter/widgets.dart';
import 'package:uuid/uuid.dart';

import '../catalog/catalog.dart';
import '../data/exercise_repository.dart';
import '../data/models.dart';

/// A concrete execution and exact, private equipment context. Navigation rows
/// deliberately cannot be represented as a choice.
class CatalogChoice {
  const CatalogChoice.variant(
    String id, {
    this.setupId = 'default',
    this.nickname,
  }) : variantId = id,
       customName = null,
       customProfile = null,
       customId = null,
       personalGroups = const {},
       ownedExerciseId = null;
  CatalogChoice.custom(
    String name,
    String profile, {
    String? id,
    Set<String> personalGroups = const {},
    this.setupId = 'default',
    this.nickname,
  }) : customName = name,
       customProfile = profile,
       personalGroups = Set.unmodifiable(personalGroups),
       variantId = null,
       customId = id ?? const Uuid().v4(),
       ownedExerciseId = null;
  CatalogChoice.owned(Exercise exercise)
    : ownedExerciseId = exercise.id,
      customName = exercise.name,
      customProfile = null,
      customId = null,
      variantId = null,
      setupId = 'default',
      nickname = null,
      personalGroups = const {};
  final String? variantId, customName, customProfile, nickname, customId;
  final String? ownedExerciseId;
  bool get isOwned => ownedExerciseId != null;
  final String setupId;

  /// Optional personal organization, never copied into anatomical profiles or
  /// the legacy single-muscle column. Empty means explicitly unclassified.
  final Set<String> personalGroups;
  String get definitionKey => isOwned
      ? 'owned:$ownedExerciseId'
      : variantId == null
      ? 'custom:$customId'
      : 'variant:$variantId';
  String get key => '$definitionKey@$setupId';
}

/// Explicitly injected into the disposable trial only. No serialized mapping,
/// owner-profile discovery or durable metric contract is implied by this state.
class CatalogTrialState extends ChangeNotifier {
  CatalogTrialState(this.bundle);
  final CatalogBundle bundle;
  bool get durable => false;
  bool get active => true;
  String get indexProfileId => 'disposable-catalog-trial';
  List<Exercise> get ownedExercises => const [];
  CatalogChoice choiceForOwned(Exercise exercise) =>
      exercises[exercise.id] ?? CatalogChoice.owned(exercise);
  final List<CatalogChoice> recents = [];
  final Set<String> favorites = {};
  final Map<String, CatalogChoice> choices = {};
  final Map<String, CatalogChoice> routineContexts = {};
  bool useInRoutine(
    String originSlotId,
    CatalogChoice choice, {
    required Slot? actualSlot,
    required String exerciseId,
    required int? expectedRevision,
  }) {
    if (actualSlot == null ||
        actualSlot.id != originSlotId ||
        actualSlot.exerciseId != exerciseId ||
        actualSlot.localRevision != expectedRevision) {
      return false;
    }
    routineContexts[originSlotId] = choice;
    notifyListeners();
    return true;
  }

  final Map<String, CatalogChoice> exercises = {};
  final Map<String, Exercise> _materialized = {};
  final Map<String, Future<Exercise>> _pending = {};
  final Map<String, PreparedDomainAction> _intents = {};
  final Map<String, List<CatalogChoice>> setups = {};
  final Map<String, Map<String, String>> metricDrafts = {};
  final Map<String, Map<String, String>> loggedMetrics = {};
  final Map<String, CatalogChoice> setContexts = {};
  final Map<Object, CatalogChoice> upcomingContexts = {};
  final Map<Object, CatalogChoice> blockContexts = {};
  final Map<String, Map<String, String>> routineMetrics = {};
  static const uuid = Uuid();

  final _indexes = <String, CatalogIndex>{};
  CatalogIndex index(String locale) => _indexes.putIfAbsent(
    locale,
    () => CatalogIndex(bundle, locale: locale, profileId: indexProfileId),
  );
  CatalogMeasurementProfile measurement(CatalogChoice choice) =>
      choice.variantId == null
      ? bundle.measurementProfiles[choice.customProfile ?? 'load_reps']!
      : bundle.measurementFor(bundle.variants[choice.variantId]!);
  String label(CatalogChoice choice, String locale, {String? query}) =>
      choice.customName ??
      (choice.setupId == 'default'
          ? index(locale).variantLabel(choice.variantId!)
          : identifyingLabel(choice, locale));
  String identifyingLabel(CatalogChoice choice, String locale) =>
      choice.customName ??
      index(locale).identifyingVariantLabel(choice.variantId!);

  String distinction(CatalogChoice choice, String locale) {
    if (choice.nickname?.isNotEmpty == true) return choice.nickname!;
    final variant = bundle.variants[choice.variantId];
    if (variant == null) return '';
    if (choice.setupId != 'default') {
      final ordinal =
          (setups[choice.variantId]?.indexWhere(
                (s) => s.setupId == choice.setupId,
              ) ??
              -1) +
          1;
      return '${CatalogLabels(locale).equipment(variant.equipmentKind)} · $ordinal';
    }
    return CatalogLabels(
      locale,
    ).distinction(variant, bundle.variantsForFamily(variant.familyId));
  }

  void remember(CatalogChoice choice, {String? locale, String? query}) {
    choices[choice.key] = choice;
    recents.removeWhere((c) => c.key == choice.key);
    recents.insert(0, choice);
    if (recents.length > 12) recents.removeLast();
    notifyListeners();
  }

  void toggleFavorite(CatalogChoice choice) {
    choices[choice.key] = choice;
    if (!favorites.add(choice.key)) favorites.remove(choice.key);
    notifyListeners();
  }

  CatalogChoice newSetup(CatalogChoice current, String nickname) {
    final choice = CatalogChoice.variant(
      current.variantId!,
      setupId: uuid.v4(),
      nickname: nickname.trim().isEmpty ? null : nickname.trim(),
    );
    (setups[current.variantId!] ??= []).add(choice);
    notifyListeners();
    return choice;
  }

  /// Definitions use the existing repository only in the explicit synthetic
  /// store. General measurement observations stay exclusively in this adapter.
  Future<Exercise> materialize(
    CatalogChoice choice,
    ExerciseRepository repo, {
    required String locale,
  }) async {
    if (choice.isOwned) {
      final owned = await repo.byId(choice.ownedExerciseId!);
      if (owned == null) throw StateError('Owned exercise is unavailable');
      return owned;
    }
    if (_materialized.containsKey(choice.definitionKey)) {
      return _materialized[choice.definitionKey]!;
    }
    if (_pending.containsKey(choice.definitionKey)) {
      return _pending[choice.definitionKey]!;
    }
    Future<Exercise> create() async {
      final intent = _intents.putIfAbsent(
        choice.definitionKey,
        () => repo.prepareExercise(
          ExerciseDraft(
            name: identifyingLabel(choice, locale),
            muscleGroup: '',
            equip: choice.variantId == null
                ? null
                : CatalogLabels(
                    locale,
                  ).equipment(bundle.variants[choice.variantId]!.equipmentKind),
            compound: false,
            plateStepKg: 2.5,
            baseWeightKg: null,
            defaultWarmupSets: 0,
            defaultWorkingSets: 1,
            defaultRepLow: 8,
            defaultRepHigh: 8,
          ),
        ),
      );
      await repo.commitPrepared(intent);
      final id = intent.action.target.id;
      final exercise = (await repo.byId(id))!;
      exercises[id] = choice.variantId == null
          ? choice
          : CatalogChoice.variant(choice.variantId!);
      _materialized[choice.definitionKey] = exercise;
      _intents.remove(choice.definitionKey);
      remember(choice);
      return exercise;
    }

    final future = create();
    _pending[choice.definitionKey] = future;
    try {
      return await future;
    } finally {
      _pending.remove(choice.definitionKey);
    }
  }
}

class CatalogTrialScope extends InheritedNotifier<CatalogTrialState> {
  const CatalogTrialScope({
    super.key,
    required CatalogTrialState state,
    required super.child,
  }) : super(notifier: state);
  static CatalogTrialState? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<CatalogTrialScope>()?.notifier;
}
