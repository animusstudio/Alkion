import 'dart:io';

import 'package:alkion/identity/alkion_identity.dart';
import 'package:alkion/main.dart';
import 'package:alkion/session/workout_notification.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// The owner's crash cuts: inside the consume transaction (before COMMIT),
/// and after the outcome is durable (before the journal entry is deleted).
const notificationIntentCrashCuts = ['intent-consume-open', 'intent-committed'];

/// Disposable subprocess only, run by `notification_intent_launch_test.dart`
/// through `make -C app test`. It opens the real runtime over a prepared
/// disposable root whose journal holds one tap, and exits at the cut during
/// the open's first drain, without closing SQLite.
void main() {
  test('notification intent owner process cut', () async {
    final root = Platform.environment['ALKION_NI_ROOT'] ?? '';
    final cut = Platform.environment['ALKION_NI_CUT'] ?? '';
    if (!root.contains('/alkion-notification-intent-crash-') ||
        !notificationIntentCrashCuts.contains(cut)) {
      throw ArgumentError('Explicit disposable intent fixture and cut');
    }
    await AlkionRuntime.open(
      Directory(p.join(root, AlkionIdentity.applicationId)),
      notifications: WorkoutNotification(isAndroid: false),
      openCheckpoint: (phase) async {
        if (phase != cut) return;
        File('$root/cut-$cut').writeAsStringSync(cut, flush: true);
        exit(86);
      },
    );
    throw StateError('Intent cut was not reached');
  });
}
