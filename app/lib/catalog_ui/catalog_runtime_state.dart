import 'dart:async';
import 'dart:convert';
import '../catalog/catalog.dart';
import '../data/catalog_execution_repository.dart';
import '../data/exercise_repository.dart';
import '../data/models.dart';
import '../data/catalog_personal_state.dart';
import '../domain/catalog_execution.dart';
import '../domain/local_action.dart';
import '../store/local_store.dart';
import 'catalog_trial_scope.dart';

/// Normal-app adapter. Its maps are presentation caches; set, routine and
/// measurement truth lives in the admitted store and the versioned draft.
class CatalogRuntimeState extends CatalogTrialState {
  CatalogRuntimeState(super.bundle, this.database)
    : repository = CatalogExecutionRepository.local(database),
      _token = database.token;
  final LocalDatabase database;
  final CatalogExecutionRepository repository;
  final StoreToken _token;
  bool _active = true;
  final _owned = <String, Exercise>{};
  final _results = <String, CatalogOwnedSelection>{};
  final _prepared = <String, PreparedCatalogSelection>{};
  final _pending = <String, Future<Exercise>>{};
  final _indexes = <String, CatalogIndex>{};
  final _memories = <String, _PersonalMemory>{};
  final _dirty = <String>{};
  final _personalIntents = <String, PreparedCatalogPersonalState>{};
  String _locale = 'en';
  Future<void>? _savingPersonal;
  @override
  bool get durable => true;
  @override
  bool get active =>
      _active &&
      database.token.profileId == _token.profileId &&
      database.token.generation == _token.generation;
  void _requireActive() {
    if (!active) throw const StoreException('stale_catalog_runtime');
  }

  @override
  String get indexProfileId => _token.profileId;
  @override
  CatalogIndex index(String locale) {
    _activateLocale(locale);
    return _indexes.putIfAbsent(
      locale,
      () => CatalogIndex(
        bundle,
        locale: locale,
        profileId: indexProfileId,
        generation: _token.generation,
        overlayIdentity: catalogHash(
          jsonEncode(_memoryJson(_memories[locale]!)),
        ),
      ),
    );
  }

  @override
  List<Exercise> get ownedExercises => List.unmodifiable(_owned.values);

  Future<void> initialize() async {
    for (final locale in ['shared']) {
      final saved = await CatalogPersonalStateStore.local(
        database,
      ).load(bundleDigest: bundle.digest);
      _requireActive();
      final memory = _PersonalMemory(saved.revision);
      for (final reference in saved.recents) {
        final choice = _decodeChoice(reference);
        choices[choice.key] = choice;
        if (reference['recent'] != false) memory.recents.add(choice);
      }
      memory.favorites.addAll(saved.favorites);
      _memories[locale] = memory;
      for (final presentationLocale in ['en', 'it', 'de', 'es']) {
        _memories[presentationLocale] = memory;
      }
    }
    final all = await ExerciseRepository.local(database).all();
    _requireActive();
    for (final exercise in all) {
      final selections = await repository.selectionsForExercise(exercise.id);
      _requireActive();
      _owned[exercise.id] = exercise;
      for (final selection in selections) {
        final dependencies = await repository.dependenciesForSelection(
          selection,
        );
        _requireActive();
        final choice = choiceForSelection(selection, exercise: exercise);
        _results[choice.key] = CatalogOwnedSelection(
          exercise: exercise,
          selection: selection,
          dependencies: dependencies,
        );
        if (repository.isDefaultContext(selection)) {
          exercises[exercise.id] = choice;
        } else {
          exercises.putIfAbsent(exercise.id, () => choice);
        }
        choices[choice.key] = choice;
        if (selection.variantId case final variant?) {
          if (!repository.isDefaultContext(selection) &&
              !(setups[variant] ?? []).any(
                (known) => known.setupId == choice.setupId,
              )) {
            (setups[variant] ??= []).add(choice);
          }
        }
      }
    }
    _activateLocale(_locale);
  }

  CatalogChoice choiceForSelection(
    CatalogSelectionEvidence selection, {
    Exercise? exercise,
  }) {
    final variant = bundle.variants[selection.variantId];
    if (variant != null &&
        selection.bundleDigest == bundle.digest &&
        variant.revision == selection.variantRevision) {
      return CatalogChoice.variant(
        variant.id,
        setupId: repository.isDefaultContext(selection)
            ? 'default'
            : selection.contextId,
        nickname: selection.contextLabel,
      );
    }
    return CatalogChoice.custom(
      selection.displayLabel,
      selection.profile.key,
      id: selection.exerciseId,
      setupId: repository.isDefaultContext(selection)
          ? 'default'
          : selection.contextId,
      nickname: selection.contextLabel,
      personalGroups: exercise?.executionDefinition?.personalGroups ?? const {},
    );
  }

  CatalogSelectionEvidence? selectionFor(CatalogChoice choice) =>
      _results[choice.key]?.selection;
  List<OperationDependency> dependenciesFor(CatalogChoice choice) =>
      _results[choice.key]?.dependencies ?? const [];

  @override
  void remember(CatalogChoice choice, {String? locale, String? query}) {
    _requireActive();
    _activateLocale(locale ?? _locale);
    if (choice.isOwned) return;
    choices[choice.key] = choice;
    recents.removeWhere((c) => c.key == choice.key);
    recents.insert(0, choice);
    if (recents.length > 12) recents.removeLast();
    _changedPersonal();
    notifyListeners();
  }

  @override
  void toggleFavorite(CatalogChoice choice) {
    _requireActive();
    choices[choice.key] = choice;
    if (!favorites.add(choice.key)) favorites.remove(choice.key);
    _changedPersonal();
    notifyListeners();
  }

  void _activateLocale(String locale) {
    final memory = _memories[locale];
    if (memory == null) return;
    _locale = locale;
    recents
      ..clear()
      ..addAll(memory.recents);
    favorites
      ..clear()
      ..addAll(memory.favorites);
  }

  void _changedPersonal() {
    final memory = _memories.putIfAbsent(_locale, () => _PersonalMemory(0));
    memory.recents
      ..clear()
      ..addAll(recents);
    memory.favorites
      ..clear()
      ..addAll(favorites);
    _indexes.clear();
    _dirty.add('shared');
    unawaited(flushPersistence().catchError((Object _) {}));
  }

  Map<String, Object?> _encodeChoice(
    CatalogChoice choice, {
    required bool recent,
  }) => {
    'version': 1,
    'recent': recent,
    'variantId': choice.variantId,
    'customId': choice.customId,
    'customName': choice.customName,
    'customProfile': choice.customProfile,
    'ownedExerciseId': choice.ownedExerciseId,
    'setupId': choice.setupId,
    'nickname': choice.nickname,
    'personalGroups': choice.personalGroups.toList()..sort(),
  };
  CatalogChoice _decodeChoice(Map<String, Object?> json) {
    catalogEvidenceKeys(Map<String, dynamic>.from(json), {
      'version',
      'recent',
      'variantId',
      'customId',
      'customName',
      'customProfile',
      'ownedExerciseId',
      'setupId',
      'nickname',
      'personalGroups',
    });
    if (json['version'] != 1) {
      throw const FormatException('Newer personal choice');
    }
    if (json['variantId'] case final String id) {
      if (!bundle.variants.containsKey(id)) {
        throw const FormatException('Foreign catalog choice');
      }
      return CatalogChoice.variant(
        id,
        setupId: json['setupId'] as String,
        nickname: json['nickname'] as String?,
      );
    }
    if (json['ownedExerciseId'] != null) {
      // Owned legacy selections are never persisted as catalog recents.
      throw const FormatException('Unsupported personal choice');
    }
    return CatalogChoice.custom(
      json['customName'] as String,
      json['customProfile'] as String,
      id: json['customId'] as String,
      setupId: json['setupId'] as String,
      nickname: json['nickname'] as String?,
      personalGroups: (json['personalGroups'] as List).cast<String>().toSet(),
    );
  }

  List<Map<String, Object?>> _memoryJson(_PersonalMemory memory) => [
    for (final choice in memory.recents.where((c) => !c.isOwned))
      _encodeChoice(choice, recent: true),
    for (final key in memory.favorites)
      if (!memory.recents.any((c) => c.key == key) && choices[key] != null)
        _encodeChoice(choices[key]!, recent: false),
  ];

  @override
  Future<Exercise> materialize(
    CatalogChoice choice,
    ExerciseRepository repo, {
    required String locale,
  }) async {
    _requireActive();
    if (choice.isOwned) {
      final exercise = await repo.byId(choice.ownedExerciseId!);
      _requireActive();
      if (exercise == null) throw const StoreException('deleted_target');
      return exercise;
    }
    if (_results[choice.key] case final result?) {
      remember(choice, locale: locale);
      return result.exercise;
    }
    if (_pending[choice.key] case final pending?) return pending;
    Future<Exercise> resolve() async {
      final variant = bundle.variants[choice.variantId];
      final source = catalogResistanceSource(variant);
      final previous = _results.values
          .where(
            (r) => choice.variantId == null
                ? r.selection.exerciseId == choice.customId
                : r.selection.variantId == choice.variantId,
          )
          .firstOrNull;
      final prepared =
          _prepared[choice.key] ??
          (previous != null && choice.setupId != 'default'
              ? repository.prepareNewContext(
                  previous.selection,
                  contextId: choice.setupId,
                  nickname: choice.nickname,
                  dependencies: previous.dependencies,
                )
              : await repository.prepareSelection(
                  bundle: choice.variantId == null ? null : bundle,
                  variantId: choice.variantId,
                  displayLabel: identifyingLabel(choice, locale),
                  setupId: choice.setupId,
                  nickname: choice.nickname,
                  customId: choice.customId,
                  profile: CatalogMeasurementProfileEvidence.fromCatalog(
                    measurement(choice),
                  ),
                  personalGroups: choice.personalGroups,
                  resistanceSource: source,
                  loadConvention: source == 'external'
                      ? 'reported_mass'
                      : 'unknown',
                ));
      _requireActive();
      _prepared[choice.key] = prepared;
      final result = await repository.commitPrepared(prepared);
      _requireActive();
      _results[choice.key] = result;
      _owned[result.exercise.id] = result.exercise;
      exercises.putIfAbsent(result.exercise.id, () => choice);
      _prepared.remove(choice.key);
      remember(choice, locale: locale);
      return result.exercise;
    }

    final pending = resolve();
    _pending[choice.key] = pending;
    try {
      return await pending;
    } finally {
      if (active) _pending.remove(choice.key);
    }
  }

  Future<void> flushPersistence() {
    if (_savingPersonal case final pending?) return pending;
    final result = _writePersonal();
    _savingPersonal = result;
    return result.whenComplete(() => _savingPersonal = null);
  }

  Future<void> _writePersonal() async {
    final store = CatalogPersonalStateStore.local(database);
    while (_dirty.isNotEmpty || _personalIntents.isNotEmpty) {
      final locale = _personalIntents.keys.firstOrNull ?? _dirty.first;
      final memory = _memories[locale]!;
      final intent = _personalIntents.putIfAbsent(locale, () {
        _dirty.remove(locale);
        return store.prepare(
          bundleDigest: bundle.digest,
          expectedRevision: memory.revision,
          favorites: memory.favorites,
          recents: _memoryJson(memory),
        );
      });
      final revision = await store.commitPrepared(intent);
      _requireActive();
      memory.revision = revision;
      _personalIntents.remove(locale);
    }
  }

  @override
  void dispose() {
    _active = false;
    _indexes.clear();
    super.dispose();
  }
}

class _PersonalMemory {
  _PersonalMemory(this.revision);
  int revision;
  final recents = <CatalogChoice>[];
  final favorites = <String>{};
}

/// Only explicit equipment/facet vocabulary establishes a load mode. A
/// personal nickname or a matching exercise name is never consulted.
String catalogResistanceSource(CatalogVariant? variant) {
  if (variant == null) return 'unknown';
  final explicit = variant.facets['resistance_source'];
  if (const {
    'external',
    'bodyweight',
    'assistance',
    'band',
    'unknown',
  }.contains(explicit)) {
    return explicit!;
  }
  final vocabulary = {variant.equipmentKind, ...variant.facets.values};
  if (vocabulary.any(
    const {'band', 'elastic_band', 'resistance_band'}.contains,
  )) {
    return 'band';
  }
  if (vocabulary.any(
    const {'assistance', 'assisted', 'counterweight'}.contains,
  )) {
    return 'assistance';
  }
  if (variant.equipmentKind == 'bodyweight') return 'bodyweight';
  if (const {
    'barbell',
    'dumbbell',
    'kettlebell',
    'machine',
    'cable',
    'plate',
    'weight_stack',
    'smith_machine',
    'free_weight',
  }.contains(variant.equipmentKind)) {
    return 'external';
  }
  return 'unknown';
}
