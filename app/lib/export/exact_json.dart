import 'dart:convert';
import 'dart:typed_data';

/// A JSON token emitted verbatim (an exact preserved source lexeme).
final class RawJson {
  const RawJson(this.lexeme);
  final String lexeme;
}

/// Deterministic JSON writer that keeps map insertion order, never rounds
/// decimal TEXT and emits [RawJson] lexemes unchanged.
Uint8List encodeExactJson(Object? value) {
  final out = StringBuffer();
  void write(Object? v, String indent) {
    final inner = '$indent  ';
    switch (v) {
      case null:
        out.write('null');
      case final bool b:
        out.write(b ? 'true' : 'false');
      case final int i:
        out.write(i);
      case final double d:
        if (!d.isFinite) throw const FormatException('Non-finite export value');
        out.write(jsonEncode(d));
      case final String s:
        out.write(jsonEncode(s));
      case final RawJson r:
        out.write(r.lexeme);
      case final Uint8List bytes:
        out.write(jsonEncode({'blob_base64': base64.encode(bytes)}));
      case final Map<String, Object?> m:
        if (m.isEmpty) {
          out.write('{}');
          return;
        }
        out.write('{\n');
        var first = true;
        for (final e in m.entries) {
          if (!first) out.write(',\n');
          first = false;
          out
            ..write(inner)
            ..write(jsonEncode(e.key))
            ..write(': ');
          write(e.value, inner);
        }
        out.write('\n$indent}');
      case final List<Object?> l:
        if (l.isEmpty) {
          out.write('[]');
          return;
        }
        out.write('[\n');
        for (var i = 0; i < l.length; i++) {
          if (i > 0) out.write(',\n');
          out.write(inner);
          write(l[i], inner);
        }
        out.write('\n$indent]');
      default:
        throw FormatException('Unsupported export value ${v.runtimeType}');
    }
  }

  write(value, '');
  out.write('\n');
  return Uint8List.fromList(utf8.encode(out.toString()));
}
