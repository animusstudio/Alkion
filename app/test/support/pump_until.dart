import 'package:flutter_test/flutter_test.dart';

/// Pumps until [finder] matches, allowing REAL async work (database IO,
/// isolate spawn) to progress between frames.
///
/// `pumpAndSettle` advances fake time only, so it never waits for a real
/// PowerSync emission. A fixed delay would be a CI flake waiting to happen:
/// this returns as soon as the condition holds and only fails after
/// [timeout], so a loaded machine is slow, not red.
Future<void> pumpUntilFound(
  WidgetTester tester,
  Finder finder, {
  Duration timeout = const Duration(seconds: 10),
  Duration step = const Duration(milliseconds: 25),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (finder.evaluate().isNotEmpty) return;
    await tester.runAsync(() => Future<void>.delayed(step));
    await tester.pump();
  }
  throw TestFailure(
    'Timed out after ${timeout.inSeconds}s waiting for: $finder',
  );
}
