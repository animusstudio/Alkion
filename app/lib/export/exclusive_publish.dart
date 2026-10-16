import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

/// Publishes [from] under [to] with libc `link(2)`, which fails instead of
/// replacing an existing name (unlike `rename(2)`). Returns false when [to]
/// already exists; any other failure throws. Linux/Android libc only.
bool linkExclusive(String from, String to) {
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
  final link = libc
      .lookupFunction<
        Int32 Function(Pointer<Uint8>, Pointer<Uint8>),
        int Function(Pointer<Uint8>, Pointer<Uint8>)
      >('link');
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
      if (link(source, target) == 0) return true;
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
