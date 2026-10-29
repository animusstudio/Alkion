import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as paths;
import 'package:path_provider/path_provider.dart' as platform_paths;

const catalogTrialApplicationId = 'dev.animusstudio.alkion.catalogtrial.dev';

/// Trial-only cache selection from this installed app's native Context. The
/// ordinary app identity checks and profile link rejection remain unchanged.
abstract final class CatalogTrialStorage {
  static Future<Directory> createTemporaryDirectory({
    Future<Directory> Function()? temporaryDirectory,
  }) async {
    final native = await const MethodChannel(
      'dev.animusstudio.alkion/identity',
    ).invokeMapMethod<String, dynamic>('identity');
    if (native == null ||
        native['applicationId'] != catalogTrialApplicationId ||
        native['flavor'] != 'dev' ||
        native['displayName'] != 'Alkion Exercise Trial') {
      throw const FormatException('Foreign catalog trial installation');
    }
    String absolutePath(String key) {
      final value = native[key];
      if (value is! String ||
          !paths.isAbsolute(value) ||
          paths.normalize(value) != value) {
        throw const FormatException(
          'Invalid catalog trial storage attestation',
        );
      }
      return value;
    }

    final data = absolutePath('dataDirectory');
    final parent = absolutePath('dataParentCanonical');
    if (paths.basename(data) != catalogTrialApplicationId ||
        absolutePath('filesDirectory') != paths.join(data, 'files')) {
      throw const FormatException('Foreign catalog trial storage attestation');
    }
    // Substitute only the native-attested OS parent. App-owned data/cache
    // components stay literal and are checked before any directory creation.
    final cache = Directory(
      paths.join(parent, catalogTrialApplicationId, 'cache'),
    );
    await _requireUnlinkedDirectories(cache.path);
    // Android's native Context cache is the attested location. Dart's VM temp
    // location may instead be the engine's code_cache directory.
    final supplied =
        await (temporaryDirectory ?? platform_paths.getTemporaryDirectory)();
    if (supplied.path != paths.join(data, 'cache')) {
      throw const FormatException('Catalog trial cache directory mismatch');
    }
    final temporary = await cache.createTemp('alkion-catalog-trial-');
    await _requireUnlinkedDirectories(temporary.path);
    return temporary;
  }

  static Future<void> _requireUnlinkedDirectories(String path) async {
    var current = paths.rootPrefix(path);
    for (final part in paths.split(path).skip(1)) {
      current = paths.join(current, part);
      if (await FileSystemEntity.type(current, followLinks: false) !=
          FileSystemEntityType.directory) {
        throw const FormatException('Invalid or linked catalog trial cache');
      }
    }
  }
}
