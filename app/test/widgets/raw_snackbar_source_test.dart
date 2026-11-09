import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Every toast goes through `showWToast` (`widgets/w_toast.dart`): it alone
/// passes the messenger the shared animation style, and a `showSnackBar`
/// call with another style (or none, as the messenger's first call) would
/// replace the controller under a toast that is still up.
void main() {
  test('no lib file but w_toast.dart calls showSnackBar', () {
    final lib = Directory('lib');
    expect(lib.existsSync(), isTrue, reason: 'run from the app directory');
    final offenders = <String>[];
    for (final entity in lib.listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final path = entity.path.replaceAll(r'\', '/');
      if (path == 'lib/widgets/w_toast.dart') continue;
      final lines = entity.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        if (lines[i].contains('showSnackBar')) {
          offenders.add('$path:${i + 1}');
        }
      }
    }
    expect(offenders, isEmpty, reason: 'use showWToast instead');
  });

  test('w_toast.dart itself still calls showSnackBar', () {
    // Guards the scan above against a path or rename that would make it
    // pass vacuously.
    final helper = File('lib/widgets/w_toast.dart');
    expect(helper.readAsStringSync(), contains('showSnackBar('));
  });
}
