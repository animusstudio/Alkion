import 'package:alkion/session/notification_envelope.dart';
import 'package:alkion/session/workout_notification.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// One `showFor` the owner made, with the payload the real mirror posts.
final class ShownMirror {
  ShownMirror({
    required this.restStart,
    required this.restTotal,
    required this.action,
    required this.step,
    required this.alert,
    required this.force,
    required this.payload,
  });
  final DateTime? restStart;
  final int restTotal, step;
  final NotificationAction? action;
  final bool alert, force;
  final String? payload;
}

/// The owner's mirror without a platform: records every render request and
/// computes the exact payload [WorkoutNotification] would post. Hooks let a
/// test tap at the open's phases.
class RecordingNotification extends WorkoutNotification {
  RecordingNotification({this.onInit, this.onShow, this.onClose})
    : super(isAndroid: true);
  Future<void> Function()? onInit, onClose;
  Future<void> Function(ShownMirror mirror)? onShow;
  final mirrors = <ShownMirror>[];
  int cancels = 0, closes = 0;

  String? get payload => mirrors.last.payload;

  @override
  Future<NotificationResponse?> init({
    required void Function(NotificationResponse) onResponse,
  }) async {
    await onInit?.call();
    return null;
  }

  @override
  Future<void> showFor({
    required String name,
    required DateTime startedAt,
    DateTime? restStart,
    int restTotal = 0,
    NotificationAction? action,
    int step = 1,
    String? nextName,
    bool alertAtRestEnd = false,
    bool force = false,
  }) async {
    final mirror = ShownMirror(
      restStart: restStart,
      restTotal: restTotal,
      action: action,
      step: step,
      alert: alertAtRestEnd,
      force: force,
      payload: workoutNotificationPayload(
        action,
        step,
        workoutNotificationView(
          name: name,
          startedAt: startedAt,
          restStart: restStart,
          restTotal: restTotal,
          nextName: nextName,
          locale: 'en',
        ),
      ),
    );
    mirrors.add(mirror);
    await onShow?.call(mirror);
  }

  @override
  Future<void> cancel() async => cancels++;

  @override
  Future<void> close() async {
    closes++;
    await onClose?.call();
  }
}
