import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  // google_fonts registers one family per weight (`SpaceMono_regular`) and
  // nothing registers a plain name like 'SpaceMono', so a style that
  // names a family itself silently draws in the platform font. Every style
  // goes through WorkoutType instead.
  test('no lib file names a font family', () {
    final pattern = RegExp(r'\bfontFamily\s*:');
    final hits = <String>[];
    final files = Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'));
    for (final file in files) {
      final source = file.readAsStringSync();
      for (final m in pattern.allMatches(source)) {
        final line = '\n'.allMatches(source.substring(0, m.start)).length + 1;
        hits.add('${file.path}:$line');
      }
    }
    expect(hits, isEmpty);
  });
}
