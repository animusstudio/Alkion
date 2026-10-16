import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

/// Bounded Linux/Android libc directory fsync. Linux is qualified in this phase;
/// availability on Android is not installed-device or power-loss qualification.
void flushDirectory(String path) {
  if (!Platform.isLinux && !Platform.isAndroid) {
    throw UnsupportedError(
      'Directory durability is unsupported on this platform',
    );
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
  final open = libc
      .lookupFunction<
        Int32 Function(Pointer<Uint8>, Int32),
        int Function(Pointer<Uint8>, int)
      >('open');
  final fsync = libc.lookupFunction<Int32 Function(Int32), int Function(int)>(
    'fsync',
  );
  final close = libc.lookupFunction<Int32 Function(Int32), int Function(int)>(
    'close',
  );
  final bytes = utf8.encode(path);
  final pointer = malloc(bytes.length + 1).cast<Uint8>();
  if (pointer.address == 0) {
    throw const FileSystemException('Directory allocation failed');
  }
  var descriptor = -1;
  try {
    pointer.asTypedList(bytes.length + 1).setAll(0, [...bytes, 0]);
    descriptor = open(pointer, 65536); // O_RDONLY | O_DIRECTORY, never create.
    if (descriptor < 0 || fsync(descriptor) != 0) {
      throw FileSystemException(
        'Directory fsync failed; state preserved',
        path,
      );
    }
  } finally {
    if (descriptor >= 0) {
      close(descriptor);
    }
    free(pointer.cast<Void>());
  }
}

/// flock uses an open-file description, unlike process-scoped POSIX record
/// locks. Independent handles in another isolate of this process are refused.
final class ProfileOwnership {
  ProfileOwnership._(this._descriptor, this._close);
  final int _descriptor;
  final int Function(int) _close;
  bool _closed = false;
  static ProfileOwnership acquire(String path) {
    if (!Platform.isLinux && !Platform.isAndroid) {
      throw UnsupportedError('Profile ownership is unsupported');
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
    final open = libc
        .lookupFunction<
          Int32 Function(Pointer<Uint8>, Int32, Int32),
          int Function(Pointer<Uint8>, int, int)
        >('open');
    final flock = libc
        .lookupFunction<Int32 Function(Int32, Int32), int Function(int, int)>(
          'flock',
        );
    final close = libc.lookupFunction<Int32 Function(Int32), int Function(int)>(
      'close',
    );
    final bytes = utf8.encode(path);
    final pointer = malloc(bytes.length + 1).cast<Uint8>();
    if (pointer.address == 0) {
      throw const FileSystemException('Ownership allocation failed');
    }
    var descriptor = -1;
    try {
      pointer.asTypedList(bytes.length + 1).setAll(0, [...bytes, 0]);
      descriptor = open(
        pointer,
        66,
        384,
      ); // O_RDWR|O_CREAT; owner-only mode 0600.
      if (descriptor < 0 || flock(descriptor, 6) != 0) {
        // LOCK_EX|LOCK_NB.
        if (descriptor >= 0) {
          close(descriptor);
        }
        throw FileSystemException(
          'Profile is already owned or unavailable',
          path,
        );
      }
      return ProfileOwnership._(descriptor, close);
    } finally {
      free(pointer.cast<Void>());
    }
  }

  void close() {
    if (!_closed) {
      _closed = true;
      _close(_descriptor);
    }
  }
}
