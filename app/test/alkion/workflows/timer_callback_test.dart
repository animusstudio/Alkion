import 'package:alkion/domain/evidence.dart';
import 'package:alkion/session/notification_action.dart';
import 'package:alkion/session/notification_envelope.dart';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/data/session_writer.dart';
import 'package:alkion/domain/local_action.dart';
import 'package:alkion/identity/alkion_profile.dart';
import 'package:alkion/store/local_store.dart';
import 'package:alkion/store/schema.dart';

Future<void> archiveOwned(Directory root) async {
  final archive = Platform.environment['ALKION_FIXTURE_ARCHIVE'];
  if (archive != null) {
    final dest = Directory(
      '$archive/${root.uri.pathSegments.where((s) => s.isNotEmpty).last}',
    );
    expect(await dest.exists(), isFalse);
    final files = <String, Object?>{};
    Future<void> copy(Directory from, Directory to) async {
      await to.create(recursive: true);
      await for (final item in from.list(followLinks: false)) {
        final name = item.uri.pathSegments.where((s) => s.isNotEmpty).last;
        if (item is Directory) {
          await copy(item, Directory('${to.path}/$name'));
        } else if (item is File) {
          final bytes = await item.readAsBytes();
          final target = await item.copy('${to.path}/$name');
          final written = await target.readAsBytes();
          expect(written, bytes);
          files[item.path.substring(root.path.length + 1)] = {
            'bytes': bytes.length,
            'sha256': sha256.convert(bytes).toString(),
            'verified_archive_sha256': sha256.convert(written).toString(),
          };
        } else {
          throw StateError('Unexpected synthetic fixture artifact');
        }
      }
    }

    await copy(root, dest);
    await File(
      '${dest.path}/archive-verification.json',
    ).writeAsString(jsonEncode(files), flush: true);
  }
  expect(
    root.path.startsWith('${Directory.systemTemp.path}/alkion-workflow-'),
    isTrue,
  );
  await root.delete(recursive: true);
}

Future<void> checkpoint(LocalStore store, Directory root, String name) async {
  await File(
    '${root.path}/$name.inventory.json',
  ).writeAsString(jsonEncode(await store.inventory()), flush: true);
  await store.backupTo('${root.path}/$name.sqlite');
}

Future<void> seed(
  LocalStore store,
  RecordKind kind,
  String id,
  Map<String, Object?> fields,
) => store.writeTransaction((tx) async {
  final ref = LocalRef(tx.profileId, kind, id);
  final revision = await tx.writeRevision(
    ref,
    localBytes(fields),
    layer: 'sourceSelection',
  );
  await tx.putRecord(ref, revision, fields);
});
Future<LocalStore> reopen(AlkionProfile p) => LocalStore.open(
  profile: p,
  expectedProfileId: p.profileId,
  schema: prescriptionSchemaRegistry(),
);

NotificationIntent _tap(
  IssuedNotificationToken token,
  String id,
  NotificationIntentKind kind,
  DateTime tappedAt,
) => NotificationIntent(
  intentId: id,
  actionId: kind == NotificationIntentKind.add
      ? 'alkion.dev.add_30s'
      : 'alkion.dev.skip_rest',
  kind: kind,
  tappedAt: tappedAt.toUtc(),
  payload: NotificationEnvelope(action: token.action, step: token.step),
);

void main() {
  test(
    'visible +30s, +30s and Skip decide once each on the selected owner; SQL timer survives two reopens',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'alkion-workflow-timer-',
      );
      final support = Directory('${root.path}/dev.animusstudio.alkion.dev');
      final profile = await AlkionProfile.open(supportRoot: support);
      var store = await reopen(profile);
      try {
        final startAt = DateTime.now().toUtc();
        final start = startAt.toIso8601String();
        await commitWorkflowState(
          store,
          PreparedWorkflowState(
            store,
            {
              'draftId': 'draft',
              'restStart': start,
              'restTotal': 120,
              'blocks': [],
            },
            {'draftId': 'draft', 'restStart': start, 'restTotal': 120},
            0,
          ),
        );
        final first = (await issueNotificationToken(store))!;
        expect(first.step, 1);
        final before = await store.inventory();
        await expectLater(reopen(profile), throwsA(isA<StoreException>()));
        expect(await store.inventory(), before);
        final one = _tap(
          first,
          '00000000-0000-4000-8000-000000000001',
          NotificationIntentKind.add,
          startAt.add(const Duration(seconds: 10)),
        );
        expect(
          (await consumeNotificationIntent(store, one)).outcome,
          NotificationOutcome.applied,
        );
        final committed = await store.inventory();
        final redelivered = await consumeNotificationIntent(store, one);
        expect(redelivered.outcome, NotificationOutcome.duplicate);
        expect(redelivered.change!.restTotal, 150);
        expect(await store.inventory(), committed);

        final second = (await issueNotificationToken(store))!;
        expect(second.action.encode(), first.action.encode());
        expect(second.step, 2);
        expect(
          (await consumeNotificationIntent(
            store,
            _tap(
              second,
              '00000000-0000-4000-8000-000000000002',
              NotificationIntentKind.add,
              startAt.add(const Duration(seconds: 20)),
            ),
          )).outcome,
          NotificationOutcome.applied,
        );
        final third = (await issueNotificationToken(store))!;
        expect(third.step, 3);
        final skippedAt = startAt.add(const Duration(seconds: 30));
        final skip = await consumeNotificationIntent(
          store,
          _tap(
            third,
            '00000000-0000-4000-8000-000000000003',
            NotificationIntentKind.skip,
            skippedAt,
          ),
        );
        expect(skip.outcome, NotificationOutcome.applied);
        expect(skip.change!.restStart, isNull);
        expect(skip.change!.restEndedAt, skippedAt);

        final fourth = (await issueNotificationToken(store))!;
        expect(fourth.step, 4);
        final decided = await store.inventory();
        final late = await consumeNotificationIntent(
          store,
          _tap(
            fourth,
            '00000000-0000-4000-8000-000000000004',
            NotificationIntentKind.add,
            startAt.add(const Duration(seconds: 40)),
          ),
        );
        expect(late.marker, 'refused late');
        expect(await store.inventory(), decided);

        final rows = await store.getAll(
          "SELECT * FROM local_state WHERE state_kind IN ('draft','timer') AND state_key='active'",
        );
        expect(rows.length, 2);
        for (final row in rows) {
          expect(row['revision'], 4);
          final value =
              jsonDecode(
                    utf8.decode((row['payload_bytes'] as List).cast<int>()),
                  )
                  as Map;
          expect(value['restTotal'], 0);
          expect(value['restStart'], isNull);
          expect(value['restEndedAt'], skippedAt.toIso8601String());
          expect(value['draftId'], 'draft');
        }
        expect(await store.getAll('SELECT * FROM operations'), isEmpty);
        await checkpoint(store, root, 'extended');
        final expected = await store.inventory();
        await store.close();
        for (var i = 0; i < 2; i++) {
          store = await reopen(profile);
          expect(await store.inventory(), expected);
          await checkpoint(store, root, 'reopen-$i');
          await store.close();
        }
      } finally {
        await store.close();
        await archiveOwned(root);
      }
    },
  );
}
