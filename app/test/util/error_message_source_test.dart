import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The files whose user-facing error text goes through `userMessage`.
const _owned = [
  'lib/util/error_message.dart',
  'lib/widgets/w_dialog.dart',
  'lib/widgets/w_toast.dart',
  'lib/ui/day_editor.dart',
  'lib/ui/exercise_editor.dart',
  'lib/session/session_summary_screen.dart',
  'lib/ui/profile_screen.dart',
  'lib/ui/split_tab.dart',
  'lib/ui/exercise_library_tab.dart',
  'lib/session/exercise_picker_sheet.dart',
];

void main() {
  test('owned files interpolate an exception only into debug logs', () {
    final interpolation = RegExp(r'\$(\{\s*)?(e|error|err|exception)\b');
    final offenders = <String>[];
    for (final path in _owned) {
      final lines = File(path).readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final line = lines[i];
        if (!interpolation.hasMatch(line)) continue;
        if (line.trimLeft().startsWith('//')) continue;
        if (line.contains('debugPrint(')) continue;
        offenders.add('$path:${i + 1}: ${line.trim()}');
      }
    }
    expect(offenders, isEmpty);
  });
}
