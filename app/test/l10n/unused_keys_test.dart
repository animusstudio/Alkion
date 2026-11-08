import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const _dir = 'lib/l10n';
const _locales = ['en', 'it', 'de', 'es'];

Set<String> _keys(String locale) {
  final json =
      jsonDecode(File('$_dir/app_$locale.arb').readAsStringSync())
          as Map<String, dynamic>;
  return json.keys.where((k) => !k.startsWith('@')).toSet();
}

/// Every member name accessed in app code, generated localizations excluded.
Set<String> _accessedMembers() {
  final generated = RegExp(r'^app_localizations.*\.dart$');
  final access = RegExp(r'\.\s*([A-Za-z_][A-Za-z0-9_]*)');
  final names = <String>{};
  for (final entity in Directory('lib').listSync(recursive: true)) {
    if (entity is! File || !entity.path.endsWith('.dart')) continue;
    final name = entity.uri.pathSegments.last;
    if (entity.parent.path == _dir && generated.hasMatch(name)) continue;
    for (final match in access.allMatches(entity.readAsStringSync())) {
      names.add(match.group(1)!);
    }
  }
  return names;
}

void main() {
  test('every ARB key is used by app code', () {
    final used = _accessedMembers();
    final unused = _keys('en').difference(used).toList()..sort();
    expect(unused, isEmpty, reason: 'unused ARB keys: $unused');
  });

  test('all four locales keep the same key set', () {
    final en = _keys('en');
    for (final locale in _locales.skip(1)) {
      final keys = _keys(locale);
      expect(
        keys.difference(en),
        isEmpty,
        reason: '$locale extra: ${keys.difference(en)}',
      );
      expect(
        en.difference(keys),
        isEmpty,
        reason: '$locale missing: ${en.difference(keys)}',
      );
    }
  });
}
