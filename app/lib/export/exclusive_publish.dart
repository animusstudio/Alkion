import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

/// Atomically publishes the closed owned temporary [from] under [to] without
/// replacing any existing name. Returns false on collision; other errors throw.
/// Android consumes [from] with renameat2(RENAME_NOREPLACE); Linux retains it
/// with link(2). Callers may remove only their own temporary if it still exists.
/// Directory flush and final-byte verification remain the caller's obligation.
bool publishExclusive(String from, String to) {
  if (!Platform.isLinux && !Platform.isAndroid) {
    throw UnsupportedError('Exclusive publish is unsupported on this platform');
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
  final publish =
      (Platform.isAndroid ? DynamicLibrary.open('libalkion_fileops.so') : libc)
          .lookupFunction<
            Int32 Function(Pointer<Uint8>, Pointer<Uint8>),
            int Function(Pointer<Uint8>, Pointer<Uint8>)
          >(Platform.isAndroid ? 'alkion_publish_noreplace' : 'link');
  Pointer<Uint8> cString(String value) {
    final bytes = utf8.encode(value);
    final pointer = malloc(bytes.length + 1).cast<Uint8>();
    if (pointer.address == 0) {
      throw const FileSystemException('Publish allocation failed');
    }
    pointer.asTypedList(bytes.length + 1).setAll(0, [...bytes, 0]);
    return pointer;
  }

  final source = cString(from);
  try {
    final target = cString(to);
    try {
      final result = publish(source, target);
      if (result == 0) return true;
      if (Platform.isAndroid) {
        if (result == 17) return false; // Android/Linux EEXIST.
        throw FileSystemException(
          'Exclusive publish failed',
          to,
          OSError('Atomic no-replace publication failed', result),
        );
      }
    } finally {
      free(target.cast<Void>());
    }
  } finally {
    free(source.cast<Void>());
  }
  if (FileSystemEntity.typeSync(to, followLinks: false) !=
      FileSystemEntityType.notFound) {
    return false;
  }
  throw FileSystemException('Exclusive publish failed', to);
}
