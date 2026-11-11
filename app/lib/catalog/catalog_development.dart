import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/services.dart';

import '../identity/alkion_identity.dart';
import 'catalog.dart';

/// The private staged catalog's asset directory. It keeps its historical name
/// because owner-staged inputs and packaged Dev APKs already use this path.
const _assets = 'assets/catalog_trial';

/// Explicitly enabled private content in the ordinary Dev application. The
/// application identity and selected profile are never changed by this loader.
class CatalogDevelopmentInput {
  const CatalogDevelopmentInput({this.bundle, this.unavailable = false});
  final CatalogBundle? bundle;
  final bool unavailable;
}

Future<CatalogDevelopmentInput> loadDevelopmentCatalog({
  bool enabled = const bool.fromEnvironment('ALKION_CATALOG_DEV'),
  bool? isAndroid,
  Future<Map<String, dynamic>?> Function()? nativeIdentity,
  Future<List<int>> Function(String)? loadBytes,
}) async {
  if (!enabled) return const CatalogDevelopmentInput();
  try {
    if (!(isAndroid ?? Platform.isAndroid)) {
      throw const FormatException('Private catalog requires the Dev app');
    }
    final native =
        await (nativeIdentity ??
            () => const MethodChannel(
              'dev.animusstudio.alkion/identity',
            ).invokeMapMethod<String, dynamic>('identity'))();
    AlkionVariant.dev.requireNativeIdentity(native);
    if (AlkionIdentity.current != AlkionVariant.dev ||
        native?['privateCatalogDev'] != true) {
      throw const FormatException('Private catalog is not enabled');
    }
    Future<List<int>> asset(String path) async {
      if (loadBytes != null) return loadBytes(path);
      final data = await rootBundle.load(path);
      return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    }

    final manifest = jsonDecode(
      utf8.decode(await asset('$_assets/manifest.dev.json')),
    );
    if (manifest is! Map<String, dynamic> ||
        manifest['format'] != 'alkion-catalog-development-manifest' ||
        ![3, 4].contains(manifest['schema_version']) ||
        manifest['private_development_only'] != true ||
        manifest['redistribution_cleared'] != false ||
        manifest['media_included'] != false ||
        manifest.containsKey('private_trial_only') ||
        manifest['projection_sha256'] is! String) {
      throw const FormatException('Unsupported development catalog manifest');
    }
    final browse = manifest['browse'];
    List<int>? browseBytes;
    if (browse is Map<String, dynamic>) {
      try {
        browseBytes = await asset('$_assets/browse.dev.json');
      } on Object {
        // Classification is optional; name search remains usable.
      }
    }
    final muscle = manifest['muscle_bundle'];
    final scopes = manifest['scope_registry'];
    List<int>? muscleBytes, scopeBytes;
    if (manifest['schema_version'] == 4) {
      if (muscle is! Map || scopes is! Map) {
        throw const FormatException('Missing muscle manifest');
      }
      muscleBytes = await asset('$_assets/muscles.dev.json');
      scopeBytes = await asset('$_assets/muscle-scopes.dev.json');
    }
    final catalogBytes = await asset('$_assets/catalog.dev.json');
    // Hashing and validating the large muscle bundle takes seconds on a phone;
    // keep it off the UI thread so startup frames still draw.
    final bundle = await Isolate.run(
      () => _verifiedBundle(
        catalogBytes,
        manifest,
        browseBytes,
        muscleBytes,
        scopeBytes,
      ),
    );
    if (bundle.catalogRevision != manifest['catalog_revision'] ||
        bundle.searchRevision != manifest['search_revision'] ||
        (bundle.schemaVersion == 2) != (manifest['schema_version'] == 4)) {
      throw const FormatException('Development catalog revision mismatch');
    }
    if (bundle.schemaVersion == 2) {
      final profile = bundle.muscleProfiles.values.first;
      final registryRef = profile.snapshot['scopeRegistryRef'] as Map;
      if (muscle is! Map ||
          scopes is! Map ||
          muscle.keys.toSet().difference({
            'namespace',
            'revision',
            'source_sha256',
          }).isNotEmpty ||
          scopes.keys.toSet().difference({
            'revision',
            'source_sha256',
            'canonical_sha256',
          }).isNotEmpty ||
          muscle['namespace'] != profile.sourceNamespace ||
          muscle['revision'] != profile.sourceRevision ||
          muscle['source_sha256'] != profile.sourceBundleDigest ||
          scopes['revision'] != registryRef['revision'] ||
          scopes['canonical_sha256'] != registryRef['sha256']) {
        throw const FormatException('Muscle manifest reference mismatch');
      }
    }
    return CatalogDevelopmentInput(bundle: bundle);
  } on Object {
    // A rejected private asset never prevents ordinary local app startup.
    return const CatalogDevelopmentInput(unavailable: true);
  }
}

CatalogBundle _verifiedBundle(
  List<int> catalogBytes,
  Map<String, dynamic> manifest,
  List<int>? browseBytes,
  List<int>? muscleBytes,
  List<int>? scopeBytes,
) {
  final browse = manifest['browse'];
  if (manifest['schema_version'] == 4) {
    final muscle = manifest['muscle_bundle'] as Map,
        scopes = manifest['scope_registry'] as Map;
    if (catalogHash(utf8.decode(muscleBytes!)) != muscle['source_sha256'] ||
        catalogHash(utf8.decode(scopeBytes!)) != scopes['source_sha256']) {
      throw const FormatException('Muscle manifest digest mismatch');
    }
  }
  return CatalogBundle.fromBytes(
    muscleBundleBytes: muscleBytes,
    trustedScopeRegistryBytes: scopeBytes,
    catalogBytes,
    expectedSha256: manifest['projection_sha256'] as String,
    browseBytes: browseBytes,
    browseSha256: browse is Map && browse['projection_sha256'] is String
        ? browse['projection_sha256'] as String
        : null,
    browseRevision: browse is Map && browse['classification_revision'] is String
        ? browse['classification_revision'] as String
        : null,
    sourceSha256: manifest['source_sha256'] is String
        ? manifest['source_sha256'] as String
        : null,
  );
}
