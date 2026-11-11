import 'dart:io';

import 'package:alkion/data/workflow_state_quarantine.dart';
import 'package:alkion/identity/alkion_profile.dart';
import 'package:alkion/store/local_store.dart';
import 'package:alkion/store/schema.dart';
import 'package:flutter_test/flutter_test.dart';

/// Disposable subprocess only, run by `workflow_state_quarantine_test.dart`
/// through `make -C app test`. The quarantine imports Flutter, so the child
/// runs under the Flutter tester instead of `dart run`. It deliberately exits
/// without closing SQLite inside the uncommitted quarantine transaction, or
/// right after its COMMIT.
void main() {
  test('workflow quarantine process cut', () async {
    final root = Platform.environment['ALKION_WQ_ROOT'] ?? '';
    final cut = Platform.environment['ALKION_WQ_CUT'] ?? '';
    if (!root.contains('/alkion-workflow-quarantine-') ||
        !const [
          'quarantine-review-written',
          'quarantine-committed',
        ].contains(cut)) {
      throw ArgumentError('Explicit disposable quarantine fixture and cut');
    }
    final profile = await AlkionProfile.open(
      supportRoot: Directory('$root/dev.animusstudio.alkion.dev'),
    );
    final store = await LocalStore.open(
      profile: profile,
      expectedProfileId: profile.profileId,
      schema: prescriptionSchemaRegistry(),
    );
    await quarantineUnreadableWorkflowState(
      store,
      checkpoint: (phase) async {
        if (phase != cut) return;
        File('$root/cut-$cut').writeAsStringSync(cut, flush: true);
        exit(86);
      },
    );
    throw StateError('Quarantine cut was not reached');
  });
}
