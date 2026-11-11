import 'package:alkion/catalog/catalog.dart';
import 'package:alkion/catalog_ui/catalog_runtime_state.dart';
import 'package:alkion/catalog_ui/catalog_scope.dart';
import 'package:alkion/data/exercise_repository.dart';
import 'package:alkion/data/models.dart';
import 'package:alkion/store/local_store.dart';

const _profileId = 'memory-catalog-test';

/// Test-only store stand-in. The in-memory state below never reads or writes
/// it; any call fails loudly instead of touching a profile.
class _InertDatabase implements LocalDatabase {
  @override
  String get profileId => _profileId;
  @override
  StoreToken get token => const StoreToken(_profileId, 0);
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('MemoryCatalogState has no store');
}

/// An in-memory [CatalogRuntimeState] for picker, browser and label tests that
/// need no admitted store. Recents, favorites and indexes stay in memory; an
/// explicit [materialize] creates an ordinary exercise in the repository the
/// caller passes, without catalog selection evidence.
class MemoryCatalogState extends CatalogRuntimeState {
  MemoryCatalogState(CatalogBundle bundle) : super(bundle, _InertDatabase());

  final _indexes = <String, CatalogIndex>{};
  final _materialized = <String, Exercise>{};
  final _pending = <String, Future<Exercise>>{};
  final _intents = <String, PreparedDomainAction>{};

  @override
  bool get active => true;
  @override
  String get indexProfileId => _profileId;
  @override
  List<Exercise> get ownedExercises => const [];
  @override
  CatalogIndex index(String locale) => _indexes.putIfAbsent(
    locale,
    () => CatalogIndex(bundle, locale: locale, profileId: indexProfileId),
  );

  @override
  void remember(CatalogChoice choice, {String? locale, String? query}) {
    choices[choice.key] = choice;
    recents.removeWhere((c) => c.key == choice.key);
    recents.insert(0, choice);
    if (recents.length > 12) recents.removeLast();
    notifyListeners();
  }

  @override
  void toggleFavorite(CatalogChoice choice) {
    choices[choice.key] = choice;
    if (!favorites.add(choice.key)) favorites.remove(choice.key);
    notifyListeners();
  }

  @override
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
    if (_materialized[choice.definitionKey] case final exercise?) {
      return exercise;
    }
    if (_pending[choice.definitionKey] case final pending?) return pending;
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
