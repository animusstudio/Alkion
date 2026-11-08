import 'package:flutter/widgets.dart';
import 'package:uuid/uuid.dart';

import '../data/models.dart';
import 'catalog_runtime_state.dart';

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

/// Provides the app's [CatalogRuntimeState] to the catalog-aware screens.
class CatalogScope extends InheritedNotifier<CatalogRuntimeState> {
  const CatalogScope({
    super.key,
    required CatalogRuntimeState state,
    required super.child,
  }) : super(notifier: state);
  static CatalogRuntimeState? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<CatalogScope>()?.notifier;
}
