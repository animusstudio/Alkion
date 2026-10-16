import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/data/re_listenable.dart';

void main() {
  // A single-subscription source, matching what PowerSync's db.watch() returns.
  // Stream.fromIterable is NOT usable here — as of Dart 3.12 it is built on
  // Stream.multi and can be listened to repeatedly, which would make the
  // control test below pass for the wrong reason.
  Stream<int> singleSub(int value) {
    final ctrl = StreamController<int>();
    ctrl.add(value);
    return ctrl.stream;
  }

  // A lazy ListView child that scrolls far enough out of view is UNMOUNTED
  // (disposing its StreamBuilder subscription) and re-created on the way back,
  // which re-listens to the same stream instance. A zero cache extent makes
  // the recycle deterministic instead of viewport-height dependent.
  Widget host(Stream<int> stream, ScrollController ctrl) => MaterialApp(
    home: Scaffold(
      body: SizedBox(
        height: 200,
        child: ListView.builder(
          controller: ctrl,
          // cacheExtent (double) is deprecated on this SDK in favor of
          // scrollCacheExtent; pixels(0) is the same "no cache" behaviour.
          scrollCacheExtent: const ScrollCacheExtent.pixels(0),
          itemCount: 12,
          itemExtent: 200,
          itemBuilder: (_, i) => i == 0
              ? StreamBuilder<int>(
                  stream: stream,
                  builder: (_, snap) => Text('v=${snap.data ?? 0}'),
                )
              : Text('row $i'),
        ),
      ),
    ),
  );

  testWidgets(
    'a naked cached stream crashes when its child recycles (control)',
    (tester) async {
      final ctrl = ScrollController();
      final naked = singleSub(1);

      await tester.pumpWidget(host(naked, ctrl));
      await tester.pumpAndSettle();

      ctrl.jumpTo(1200); // item 0 well outside the (zero) cache window
      await tester.pumpAndSettle();
      ctrl.jumpTo(0); // item 0 re-created → second listen()
      await tester.pumpAndSettle();

      expect(
        tester.takeException(),
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('already been listened'),
        ),
      );
    },
  );

  testWidgets('a reListenable cached stream survives its child recycling', (
    tester,
  ) async {
    final ctrl = ScrollController();
    final stream = reListenable<int>(() => singleSub(42));

    await tester.pumpWidget(host(stream, ctrl));
    await tester.pumpAndSettle();
    expect(find.text('v=42'), findsOneWidget);

    ctrl.jumpTo(1200);
    await tester.pumpAndSettle();
    ctrl.jumpTo(0);
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    // The replayed last value means no loading flash on the way back.
    expect(find.text('v=42'), findsOneWidget);
  });
}
