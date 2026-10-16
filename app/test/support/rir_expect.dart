import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/data/models.dart';

/// Expects every RIR chip on screen (`rir-<rirMin>`…`rir-<rirMax>`) to be a
/// slot of at least 48×48dp, and returns how many rows the chips sit in.
int expectRirChipsAtLeast48(WidgetTester tester, {String where = ''}) {
  final tops = <double>{};
  for (var n = rirMin; n <= rirMax; n++) {
    final slot = tester.getRect(find.byKey(Key('rir-$n')));
    expect(slot.width, greaterThanOrEqualTo(48), reason: '$where rir-$n width');
    expect(
      slot.height,
      greaterThanOrEqualTo(48),
      reason: '$where rir-$n height',
    );
    tops.add(slot.top);
  }
  return tops.length;
}

/// Expects the host's [caption] to sit level with the first chip row, as it
/// must when the chips wrap to two rows.
void expectCaptionOnFirstRirRow(WidgetTester tester, Finder caption) {
  expect(
    tester.getCenter(caption).dy,
    moreOrLessEquals(
      tester.getCenter(find.byKey(Key('rir-$rirMin'))).dy,
      epsilon: 0.01,
    ),
  );
}
