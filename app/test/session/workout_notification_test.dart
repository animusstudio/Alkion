import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/session/workout_notification.dart';

void main() {
  final started = DateTime(2026, 6, 3, 10, 0);
  final now = DateTime(2026, 6, 3, 10, 30);

  test('elapsed mode when not resting', () {
    final p = notificationPayloadFor(
      sessionName: 'Upper A',
      startedAt: started,
      now: now,
    );
    expect(p.title, 'Upper A');
    expect(p.body, 'Workout in progress');
    expect(p.countdown, isFalse);
    expect(p.when, started);
  });

  test('countdown mode while resting, when = rest end', () {
    final restStart = DateTime(2026, 6, 3, 10, 29, 30);
    final p = notificationPayloadFor(
      sessionName: 'Upper A',
      startedAt: started,
      restStart: restStart,
      restTotal: 90,
      now: now, // 30s in, 60s remaining
    );
    expect(p.title, 'Upper A');
    expect(p.body, 'Rest');
    expect(p.countdown, isTrue);
    expect(p.when, restStart.add(const Duration(seconds: 90)));
  });

  test('expired rest falls back to elapsed mode', () {
    final restStart = DateTime(2026, 6, 3, 10, 28, 0);
    final p = notificationPayloadFor(
      sessionName: 'Upper A',
      startedAt: started,
      restStart: restStart,
      restTotal: 90, // ended at 10:29:30, now is 10:30
      now: now,
    );
    expect(p.countdown, isFalse);
    expect(p.when, started);
    expect(p.body, 'Workout in progress');
  });

  test('restRevertAt = restStart + restTotal', () {
    expect(
      restRevertAt(DateTime(2026, 1, 1, 10, 0, 0), 90),
      DateTime(2026, 1, 1, 10, 1, 30),
    );
  });
}
