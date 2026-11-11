import 'package:alkion/recovery/recovery_host.dart';
import 'package:alkion/recovery/stored_copies.dart';
import 'package:alkion/ui/profile_screen.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import '../support/screen_harness.dart';

/// Only the read-only last-backup query is used here.
final class _Host implements RecoveryHost {
  _Host(this.last);
  final DateTime? last;
  var reads = 0;
  @override
  Future<DateTime?> lastBackupCreated() async {
    reads++;
    return last;
  }

  @override
  Future<StoredCopySizes> storedCopies() async => const StoredCopySizes();
  @override
  bool get workoutActive => false;
  @override
  String get profileId => 'synthetic-profile';
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('${invocation.memberName}');
}

void main() {
  final harness = ScreenHarness();
  tearDown(harness.close);

  for (final last in [DateTime.utc(2026, 11, 5, 12), null]) {
    testWidgets('the Backup row names the last backup: $last', (tester) async {
      await harness.open(tester);
      setPhone(tester, width: 320, textScale: 2);
      final host = _Host(last);
      await tester.pumpWidget(
        harness.wrap(
          ProfileScreen(onClose: () {}),
          extra: [Provider<RecoveryHost?>.value(value: host)],
        ),
      );
      await settleReal(tester);
      final row = find.text('Backup & restore');
      await scrollIntoView(tester, find.byType(ProfileScreen), row);
      final expected = last == null
          ? find.text('No backup yet')
          : find.textContaining('Last backup created: Nov 5, 2026');
      expect(expected, findsOneWidget);
      expect(
        find.text('Save a backup or restore your Alkion data.'),
        findsNothing,
      );
      expect(host.reads, 1);
      expect(tester.takeException(), isNull);
      await harness.unmount(tester);
    });
  }
}
