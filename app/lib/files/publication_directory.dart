import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../identity/alkion_flutter_identity.dart';
import 'document_access.dart';
import 'private_directory.dart';

/// Reuse startup's native attestation before path_provider can create filesDir.
/// Only the native OS-owned parent alias is substituted. Reject app-owned
/// support/child links before creating or publishing any document bytes.
Future<Directory> checkedAndroidPublicationDirectory(
  String child, {
  Future<AlkionAndroidStorage?> Function()? verifyIdentity,
  Future<Directory> Function()? supportDirectory,
}) async {
  if (!RegExp(r'^document-(backups|exports)$').hasMatch(child)) {
    throw const DocumentException('document_publication_directory_invalid');
  }
  final storage =
      await (verifyIdentity ?? AlkionFlutterIdentity.verifyPlatformIdentity)();
  if (storage == null) {
    throw const DocumentException('document_storage_unattested');
  }
  final supplied = await (supportDirectory ?? getApplicationSupportDirectory)();
  final support = storage.checkedSupportDirectory(supplied);
  refuseDirectoryLinks(support.path);
  if (FileSystemEntity.typeSync(support.path, followLinks: false) !=
      FileSystemEntityType.directory) {
    throw const DocumentException('document_publication_directory_invalid');
  }
  final path = p.join(support.path, child);
  refuseDirectoryLinks(path);
  final type = FileSystemEntity.typeSync(path, followLinks: false);
  if (type == FileSystemEntityType.notFound) return claimPrivateDirectory(path);
  if (type != FileSystemEntityType.directory) {
    throw const DocumentException('document_publication_directory_invalid');
  }
  return Directory(path);
}
