import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/data/re_listenable.dart';

void main() {
  // A single-subscription source, which is what PowerSync's db.watch() returns.
  // Do NOT use Stream.fromIterable here: as of Dart 3.12 it is implemented via
  // Stream.multi (dart-sdk/lib/async/stream.dart:354) and CAN be listened to
  // more than once, so it would silently make these tests prove nothing.
  Stream<int> singleSub(int value) {
    final ctrl = StreamController<int>();
    ctrl.add(value);
    return ctrl.stream;
  }

  test(
    'a naked single-subscription stream throws on re-listen (control)',
    () async {
      final naked = singleSub(1);
      expect(await naked.first, 1);
      expect(() => naked.listen((_) {}), throwsStateError);
    },
  );

  test('reListenable can be listened to again after a cancel', () async {
    var creations = 0;
    final s = reListenable<int>(() {
      creations++;
      return singleSub(creations);
    });

    expect(await s.first, 1);
    expect(await s.first, 1); // replayed last value, no throw
    expect(creations, 2); // upstream recreated for the second listener
  });

  test('reListenable replays the last value to a late listener', () async {
    // A BROADCAST controller here on purpose: the factory must be able to
    // return a usable source on every call, and a single-subscription
    // controller's stream can only ever be listened to once, factory or not.
    final ctrl = StreamController<int>.broadcast();
    final s = reListenable<int>(() => ctrl.stream);

    final seen = <int>[];
    final sub = s.listen(seen.add);
    ctrl.add(7);
    await Future<void>.delayed(Duration.zero);
    await sub.cancel();

    // A brand-new listener sees 7 immediately, before any new upstream event.
    expect(await s.first, 7);
    await ctrl.close();
  });

  test('reListenable forwards errors', () async {
    final s = reListenable<int>(() => Stream<int>.error(StateError('boom')));
    expect(s.first, throwsStateError);
  });

  test(
    'reListenable cancels the upstream when the last listener leaves',
    () async {
      var cancels = 0;
      final s = reListenable<int>(() {
        final ctrl = StreamController<int>(onCancel: () => cancels++);
        return ctrl.stream;
      });

      final sub = s.listen((_) {});
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();
      expect(cancels, 1);
    },
  );
}
