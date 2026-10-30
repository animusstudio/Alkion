import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import '../identity/alkion_identity.dart';
import 'catalog.dart';

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
      utf8.decode(await asset('assets/catalog_trial/manifest.dev.json')),
    );
    if (manifest is! Map<String, dynamic> ||
        manifest['format'] != 'alkion-catalog-development-manifest' ||
        manifest['schema_version'] != 3 ||
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
        browseBytes = await asset('assets/catalog_trial/browse.dev.json');
      } on Object {
        // Classification is optional; name search remains usable.
      }
    }
    final bundle = CatalogBundle.fromBytes(
      await asset('assets/catalog_trial/catalog.dev.json'),
      expectedSha256: manifest['projection_sha256'] as String,
      browseBytes: browseBytes,
      browseSha256: browse is Map && browse['projection_sha256'] is String
          ? browse['projection_sha256'] as String
          : null,
      browseRevision:
          browse is Map && browse['classification_revision'] is String
          ? browse['classification_revision'] as String
          : null,
      sourceSha256: manifest['source_sha256'] is String
          ? manifest['source_sha256'] as String
          : null,
    );
    if (bundle.catalogRevision != manifest['catalog_revision'] ||
        bundle.searchRevision != manifest['search_revision']) {
      throw const FormatException('Development catalog revision mismatch');
    }
    return CatalogDevelopmentInput(bundle: bundle);
  } on Object {
    // A rejected private asset never prevents ordinary local app startup.
    return const CatalogDevelopmentInput(unavailable: true);
  }
}
