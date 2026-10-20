import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'document_access.dart';

/// Inspect literal components. Selected paths are never canonicalized/adopted.
void refuseDirectoryLinks(String path) {
  var current = p.rootPrefix(path);
  for (final part in p.split(path).skip(1)) {
    current = p.join(current, part);
    if (FileSystemEntity.typeSync(current, followLinks: false) ==
        FileSystemEntityType.link) {
      throw const DocumentException('document_symlink_refused');
    }
  }
}

/// Atomically claim the requested directory with owner-only permissions.
/// mkdir(2) fails on every existing final component, including links and a
/// directory created by a competing inspection. Nothing inside is opened
/// until this exclusive claim succeeds. Linux receiving route; Android uses
/// the same POSIX primitive only after native storage attestation.
Directory claimPrivateDirectory(String path) {
  if ((!Platform.isLinux && !Platform.isAndroid) ||
      !p.isAbsolute(path) ||
      p.normalize(path) != path ||
      path.contains('\u0000')) {
    throw const DocumentException('document_private_directory_unsupported');
  }
  refuseDirectoryLinks(path);
  if (FileSystemEntity.typeSync(p.dirname(path), followLinks: false) !=
      FileSystemEntityType.directory) {
    throw const DocumentException('document_output_requires_fresh_directory');
  }
  final libc = DynamicLibrary.open(
    Platform.isAndroid ? 'libc.so' : 'libc.so.6',
  );
  final malloc = libc
      .lookupFunction<
        Pointer<Void> Function(IntPtr),
        Pointer<Void> Function(int)
      >('malloc');
  final free = libc
      .lookupFunction<
        Void Function(Pointer<Void>),
        void Function(Pointer<Void>)
      >('free');
  final mkdir = libc
      .lookupFunction<
        Int32 Function(Pointer<Uint8>, Uint32),
        int Function(Pointer<Uint8>, int)
      >('mkdir');
  final bytes = utf8.encode(path);
  final pointer = malloc(bytes.length + 1).cast<Uint8>();
  if (pointer.address == 0) {
    throw const DocumentException('document_private_directory_allocation');
  }
  try {
    pointer.asTypedList(bytes.length + 1).setAll(0, [...bytes, 0]);
    if (mkdir(pointer, 448) != 0) {
      // 0700, subject only to a stricter umask.
      throw const DocumentException('document_output_requires_fresh_directory');
    }
  } finally {
    free(pointer.cast<Void>());
  }
  return Directory(path);
}
