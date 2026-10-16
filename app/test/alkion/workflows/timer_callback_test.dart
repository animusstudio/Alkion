import 'package:alkion/domain/evidence.dart';
import 'package:alkion/session/workout_notification.dart';
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
  schema: workflowSchemaRegistry(),
);

void main() {
  test(
    'production background +30 uses same owner and generation/session/rest fences; SQL timer survives two reopens',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'alkion-workflow-timer-',
      );
      final support = Directory('${root.path}/dev.animusstudio.alkion.dev');
      final profile = await AlkionProfile.open(supportRoot: support);
      var store = await reopen(profile);
      try {
        final start = DateTime.now().toUtc().toIso8601String();
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
        final generation = store.token.generation;
        Future<void> extend({int? gen, String id = 'draft', String? rest}) =>
            extendRestInBackground(
              supportRoot: support,
              expectedProfileId: profile.profileId,
              generation: gen ?? generation,
              draftId: id,
              restStart: rest ?? start,
            );
        final before = await store.inventory();
        await expectLater(
          extend(),
          throwsA(
            isA<StoreException>().having(
              (e) => e.category,
              'same profile owner',
              'profile_in_use',
            ),
          ),
        );
        expect(await store.inventory(), before);
        await store.close();
        await expectLater(
          extend(gen: generation + 1),
          throwsA(isA<StoreException>()),
        );
        await expectLater(
          extend(id: 'stale-session'),
          throwsA(isA<StoreException>()),
        );
        await expectLater(
          extend(
            rest: DateTime.now()
                .subtract(const Duration(seconds: 1))
                .toUtc()
                .toIso8601String(),
          ),
          throwsA(isA<StoreException>()),
        );
        await extend();
        store = await reopen(profile);
        final rows = await store.getAll(
          "SELECT * FROM local_state WHERE state_kind IN ('draft','timer')",
        );
        expect(rows.length, 2);
        for (final row in rows) {
          expect(row['revision'], 2);
          final value =
              jsonDecode(
                    utf8.decode((row['payload_bytes'] as List).cast<int>()),
                  )
                  as Map;
          expect(value['restTotal'], 150);
          expect(value['restStart'], start);
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
