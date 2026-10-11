// A second OS process that drives the SAME native gate code as the app.
//
// The Linux plugin library exports one C entry point,
// `reps_capture_native_call`, which its method channel handler also uses.
// This helper loads that very library (from the running test bundle) into a
// separate `python3` process through ctypes and forwards commands to it, so
// cross-process exclusion is exercised through the native mechanism itself,
// never through a Dart-side flag. The process can be SIGKILLed to simulate
// the loss of a hold owner.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

const _helperSource = r'''
import ctypes, sys
lib = ctypes.CDLL(sys.argv[1])
call = lib.reps_capture_native_call
call.argtypes = [ctypes.c_char_p] * 6 + [ctypes.c_size_t]
call.restype = ctypes.c_int
print("ready", flush=True)
for line in sys.stdin:
    parts = line.rstrip("\n").split("\t")
    parts += [""] * (5 - len(parts))
    out = ctypes.create_string_buffer(1024)
    args = [p.encode() if p else None for p in parts[:5]]
    call(*args, out, 1024)
    print(out.value.decode(), flush=True)
''';

/// The plugin library inside the running Linux bundle.
String bundledPluginLibrary() {
  final bundle = File(Platform.resolvedExecutable).parent.path;
  return '$bundle/lib/libreps_capture_platform_plugin.so';
}

class GateHelperProcess {
  GateHelperProcess._(this._process, this._lines);

  final Process _process;
  final StreamIterator<String> _lines;

  int get pid => _process.pid;

  static Future<GateHelperProcess> start() async {
    final library = bundledPluginLibrary();
    if (!File(library).existsSync()) {
      throw StateError('plugin library not found at $library');
    }
    final process = await Process.start(
      'python3',
      ['-I', '-c', _helperSource, library],
      environment: {'LD_LIBRARY_PATH': File(library).parent.path},
    );
    process.stderr
        .transform(utf8.decoder)
        .listen((e) => stderr.write('[gate helper] $e'));
    final lines = StreamIterator(
      process.stdout.transform(utf8.decoder).transform(const LineSplitter()),
    );
    final helper = GateHelperProcess._(process, lines);
    final ready = await helper._next();
    if (ready != 'ready') throw StateError('gate helper failed: $ready');
    return helper;
  }

  /// Runs one native gate method in the helper process and returns its
  /// result fields (`code`, and `ticket`/`generation` where applicable).
  Future<Map<String, String>> call(
    String method,
    String dir, [
    String a1 = '',
    String a2 = '',
    String a3 = '',
  ]) async {
    _process.stdin.writeln([method, dir, a1, a2, a3].join('\t'));
    await _process.stdin.flush();
    final line = await _next();
    return {
      for (final field in line.split(';').where((f) => f.contains('=')))
        field.substring(0, field.indexOf('=')): field.substring(
          field.indexOf('=') + 1,
        ),
    };
  }

  Future<String> _next() async {
    if (!await _lines.moveNext().timeout(const Duration(seconds: 20))) {
      throw StateError('gate helper exited');
    }
    return _lines.current;
  }

  /// Process loss: the kernel drops its file locks; durable files stay.
  Future<void> kill() async {
    _process.kill(ProcessSignal.sigkill);
    await _process.exitCode;
  }

  Future<void> close() async {
    await _process.stdin.close();
    await _process.exitCode.timeout(
      const Duration(seconds: 5),
      onTimeout: () {
        _process.kill(ProcessSignal.sigkill);
        return -1;
      },
    );
  }
}
