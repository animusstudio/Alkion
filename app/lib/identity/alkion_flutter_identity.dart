import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as paths;

import 'alkion_identity.dart';

/// Storage attested by this app's native Context, never by a selected file/root.
final class AlkionAndroidStorage {
  AlkionAndroidStorage._(this._filesDirectory, this._canonicalFilesDirectory);
  final String _filesDirectory;
  final String _canonicalFilesDirectory;

  static AlkionAndroidStorage _fromNative(Map<String, dynamic>? native) {
    AlkionIdentity.current.requireNativeIdentity(native);
    String absolutePath(String key) {
      final value = native![key];
      if (value is! String ||
          !paths.isAbsolute(value) ||
          paths.normalize(value) != value) {
        throw const FormatException('Invalid Android storage attestation');
      }
      return value;
    }

    final dataDirectory = absolutePath('dataDirectory');
    final canonicalParent = absolutePath('dataParentCanonical');
    final filesDirectory = absolutePath('filesDirectory');
    if (paths.basename(dataDirectory) != AlkionIdentity.applicationId ||
        filesDirectory != paths.join(dataDirectory, 'files')) {
      throw const FormatException('Foreign Android storage attestation');
    }
    return AlkionAndroidStorage._(
      filesDirectory,
      paths.join(canonicalParent, AlkionIdentity.applicationId, 'files'),
    );
  }

  /// Substitute only the native OS-owned parent after matching path_provider.
  /// App data/files/profile components remain literal for normal link checks.
  Directory checkedSupportDirectory(Directory supplied) {
    if (supplied.path != _filesDirectory) {
      throw const FormatException('Android support directory mismatch');
    }
    return Directory(_canonicalFilesDirectory);
  }

  Future<void> _checkAppOwnedDirectories() async {
    final dataType = await FileSystemEntity.type(
      paths.dirname(_canonicalFilesDirectory),
      followLinks: false,
    );
    if (dataType != FileSystemEntityType.directory) {
      throw const FormatException('Invalid or linked Android app directory');
    }
    final filesType = await FileSystemEntity.type(
      _canonicalFilesDirectory,
      followLinks: false,
    );
    if (filesType != FileSystemEntityType.directory &&
        filesType != FileSystemEntityType.notFound) {
      throw const FormatException('Invalid or linked Android app directory');
    }
  }
}

/// UI startup guard kept outside the core used by direct-Dart recovery tools.
abstract final class AlkionFlutterIdentity {
  /// [isAndroid] lets host tests exercise the actual platform-channel guard.
  static Future<AlkionAndroidStorage?> verifyPlatformIdentity({
    bool? isAndroid,
  }) async {
    if (!(isAndroid ?? Platform.isAndroid)) return null;
    final native = await const MethodChannel(
      'dev.animusstudio.alkion/identity',
    ).invokeMapMethod<String, dynamic>('identity');
    final storage = AlkionAndroidStorage._fromNative(native);
    // path_provider may create filesDir. Refuse app-owned links before it runs.
    await storage._checkAppOwnedDirectories();
    return storage;
  }
}
