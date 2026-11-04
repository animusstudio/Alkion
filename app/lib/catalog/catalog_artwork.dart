import 'catalog_bundle.dart';

part 'catalog_artwork_data.dart';

/// A reviewed recognition illustration, separate from muscle/technique evidence.
class CatalogExerciseArtwork {
  const CatalogExerciseArtwork({required this.asset, required this.sha256});

  final String asset;
  final String sha256;
}

/// Only an exact admitted catalog identity can resolve an owner illustration.
/// Custom choices, future revisions and missing/extra facets fail closed.
CatalogExerciseArtwork? catalogArtworkForVariant(CatalogVariant? variant) {
  if (variant == null) return null;
  final entry = _artwork[variant.key];
  if (entry == null ||
      entry.revision != variant.revision ||
      entry.equipmentKind != variant.equipmentKind ||
      entry.facets.length != variant.facets.length) {
    return null;
  }
  for (final facet in entry.facets.entries) {
    if (variant.facets[facet.key] != facet.value) return null;
  }
  return entry.artwork;
}

class _ArtworkRegistration {
  const _ArtworkRegistration({
    required this.revision,
    required this.equipmentKind,
    required this.facets,
    required this.artwork,
  });

  final int revision;
  final String equipmentKind;
  final Map<String, String> facets;
  final CatalogExerciseArtwork artwork;
}
