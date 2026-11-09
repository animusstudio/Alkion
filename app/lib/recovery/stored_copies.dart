import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../identity/alkion_flutter_identity.dart';
import 'stored_copy_sizes.dart';

export 'stored_copy_sizes.dart';

/// This device's stored-copy roots, resolved through the Flutter platform
/// plugins. The Flutter-free sizes and backup-name helpers live in
/// `stored_copy_sizes.dart`, so command-line tools can import them.

/// The Android native document staging root, a sibling of the publication
/// directories under the checked files directory (`AndroidDocuments.kt`).
const androidDocumentStagingName = 'alkion-documents';

/// This device's roots, resolved without creating anything. Android uses the
/// attested files directory; Linux development keeps backups in the
/// documents directory and has no picker staging.
Future<StoredCopyRoots> platformStoredCopyRoots() async {
  try {
    final supplied = await getApplicationSupportDirectory();
    if (Platform.isAndroid) {
      final storage = await AlkionFlutterIdentity.verifyPlatformIdentity();
      if (storage == null) return const StoredCopyRoots();
      final support = storage.checkedSupportDirectory(supplied).path;
      return StoredCopyRoots(
        backups: Directory(p.join(support, 'document-backups')),
        exports: Directory(p.join(support, 'document-exports')),
        staging: Directory(p.join(support, androidDocumentStagingName)),
      );
    }
    return StoredCopyRoots(
      backups: await getApplicationDocumentsDirectory(),
      exports: Directory(p.join(supplied.path, 'document-exports')),
    );
  } on Object {
    return const StoredCopyRoots();
  }
}
