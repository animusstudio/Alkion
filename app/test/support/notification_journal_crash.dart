import 'dart:io';

import 'package:alkion/identity/alkion_identity.dart';
import 'package:alkion/session/notification_background.dart';
import 'package:alkion/session/notification_envelope.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// The synthetic tap the crash child delivers: +30s at step 1 on a 90 s rest.
const crashIntentId = '00000000-0000-4000-8000-0000000000c1';
final crashTappedAt = DateTime.utc(2026, 6, 3, 10, 30);

NotificationEnvelope crashEnvelope() => NotificationEnvelope(
  action: NotificationAction(
    applicationId: AlkionIdentity.applicationId,
    profileId: 'synthetic-profile',
    generation: 1,
    draftId: 'synthetic-draft',
    restStart: '2026-06-03T10:29:30.000Z',
    timerRevision: 2,
    token: 'synthetic-crash-token',
  ),
  step: 1,
  view: NotificationView(
    title: 'Upper A',
    restBody: 'Next · Row',
    elapsedBody: 'Next · Row',
    startedAt: DateTime.utc(2026, 6, 3, 10),
    restStart: DateTime.utc(2026, 6, 3, 10, 29, 30),
    restTotal: 90,
    locale: 'en',
  ),
);

/// The journal directory the child writes under its disposable root.
Directory crashJournalDirectory(String root) => notificationJournalDirectory(
  Directory(p.join(root, 'files', AlkionIdentity.applicationId)),
);

/// Disposable subprocess only, run by `notification_background_test.dart`
/// through `make -C app test`. It delivers one tap through the real handler
/// and exits at the journal's crash cut, before any render: with the entry
/// written and flushed but not renamed, or renamed and the directory flushed.
void main() {
  test('notification journal process cut', () async {
    final root = Platform.environment['ALKION_NJ_ROOT'] ?? '';
    final cut = Platform.environment['ALKION_NJ_CUT'] ?? '';
    if (!root.contains('/alkion-notification-journal-crash-') ||
        !const ['journal-partial-written', 'journal-renamed'].contains(cut)) {
      throw ArgumentError('Explicit disposable journal fixture and cut');
    }
    await deliverNotificationResponse(
      NotificationResponse(
        notificationResponseType:
            NotificationResponseType.selectedNotificationAction,
        id: 4101,
        actionId: AlkionIdentity.addRestAction,
        payload: crashEnvelope().encode(),
      ),
      background: NotificationBackground(
        journalDirectory: () async => crashJournalDirectory(root),
        wakeOwner: () => false,
        render: (_) async =>
            File('$root/rendered').writeAsStringSync('rendered', flush: true),
        exact: () async => true,
        clock: () => crashTappedAt,
        newIntentId: () => crashIntentId,
        checkpoint: (phase) async {
          if (phase != cut) return;
          File('$root/cut-$cut').writeAsStringSync(cut, flush: true);
          exit(86);
        },
      ),
    );
    throw StateError('Journal cut was not reached');
  });
}
