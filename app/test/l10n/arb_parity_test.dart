import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('all ARB locales have the same data keys as the template', () {
    Set<String> keysOf(String path) {
      final json =
          jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;
      return json.keys.where((k) => !k.startsWith('@')).toSet();
    }

    const dir = 'lib/l10n';
    final en = keysOf('$dir/app_en.arb');
    for (final loc in ['it', 'de', 'es']) {
      final k = keysOf('$dir/app_$loc.arb');
      expect(
        k.difference(en),
        isEmpty,
        reason: '$loc extra: ${k.difference(en)}',
      );
      expect(
        en.difference(k),
        isEmpty,
        reason: '$loc missing: ${en.difference(k)}',
      );
    }
  });
}
