import '../catalog/catalog_browse.dart';

/// The muscle groups an exercise with no legacy `muscle_group` counts for:
/// the reviewed target groups of its linked catalog variant, or none.
///
/// [variantId] is the variant the caller already knows (a live block's
/// catalog selection, or a saved tracking context); otherwise the lookup
/// resolves the exercise's link itself.
typedef VolumeTargets =
    Set<String> Function(String exerciseId, String? variantId);

/// Catalog namespace whose variant ids the bundle's browse data describes.
const volumeCatalogNamespace = 'alkion-exercises';

/// The reviewed target groups of [variantId]. Secondary and activity groups
/// never count; an unreviewed or unknown variant has none.
Set<String> reviewedTargetGroups(CatalogBrowse? browse, String? variantId) {
  if (browse == null || variantId == null) return const {};
  final membership = browse.variants[variantId];
  if (membership == null || membership.status != 'reviewed') return const {};
  return membership.targetGroups;
}

/// [VolumeTargets] over the current [browse] classification. A variant the
/// caller passes wins; else [variantOf] supplies the exercise's link (for
/// example the catalog state's exercise → choice map).
VolumeTargets catalogVolumeTargets(
  CatalogBrowse? browse, {
  String? Function(String exerciseId)? variantOf,
}) =>
    (exerciseId, variantId) =>
        reviewedTargetGroups(browse, variantId ?? variantOf?.call(exerciseId));

/// Whether a legacy `muscle_group` names a group. Empty and blank labels
/// don't: those sets go to catalog targets or the unknown note.
bool hasLegacyGroup(String? muscle) =>
    muscle != null && muscle.trim().isNotEmpty;
