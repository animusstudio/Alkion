import 'dart:io';

import 'package:alkion/recovery/stored_copies.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

const _profile = '0123abcd-0000-4000-8000-000000000001';
const _other = 'ffff9999-0000-4000-8000-000000000002';

String _name(String profile, String stamp, [String nonce = 'a1b2c3']) =>
    'alkion-backup-${profile.substring(0, 8)}-${stamp}Z-$nonce.alkionbackup';

Future<File> _write(String path, int bytes) async {
  final file = File(path);
  await file.parent.create(recursive: true);
  return file.writeAsBytes(List.filled(bytes, 7));
}

/// Every path and size under [root], to prove nothing was created or removed.
Map<String, int> _tree(Directory root) => {
  for (final e in root.listSync(recursive: true, followLinks: false))
    p.relative(e.path, from: root.path): e is File ? e.lengthSync() : -1,
};

void main() {
  late Directory temp;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('alkion-stored-copies-');
  });
  tearDown(() => temp.delete(recursive: true));

  group('last backup', () {
    test('none: a missing, empty or null directory', () async {
      expect(await newestBackupCreated(null, _profile), isNull);
      expect(
        await newestBackupCreated(Directory(p.join(temp.path, 'no')), _profile),
        isNull,
      );
      expect(await newestBackupCreated(temp, _profile), isNull);
    });

    test(
      'the newest of this profile wins; other profiles and bad names are ignored',
      () async {
        await _write(p.join(temp.path, _name(_profile, '20261101T080000')), 3);
        await _write(p.join(temp.path, _name(_profile, '20261105T193012')), 3);
        // Newer, but another profile's backup.
        await _write(p.join(temp.path, _name(_other, '20261108T120000')), 3);
        // Newer, but unparseable or not a published backup of this profile.
        for (final bad in [
          _name(_profile, '20261309T120000'), // month 13
          _name(_profile, '20261107T250000'), // hour 25
          _name(_profile, '20261107T120000', 'XYZ123'),
          'alkion-backup-${_profile.substring(0, 8)}-20261107T120000Z.alkionbackup',
          '.${_name(_profile, '20261107T120000')}.partial-0011223344556677',
          '${_name(_profile, '20261107T120000')}.txt',
          'notes-20261107T120000Z.alkionbackup',
        ]) {
          await _write(p.join(temp.path, bad), 1);
        }
        // A directory or a link with a backup name is not a backup file.
        await Directory(
          p.join(temp.path, _name(_profile, '20261107T130000')),
        ).create();
        await Link(
          p.join(temp.path, _name(_profile, '20261107T140000')),
        ).create(p.join(temp.path, _name(_profile, '20261101T080000')));
        final before = _tree(temp);
        expect(
          await newestBackupCreated(temp, _profile),
          DateTime.utc(2026, 11, 5, 19, 30, 12),
        );
        expect(
          await newestBackupCreated(temp, _other),
          DateTime.utc(2026, 11, 8, 12),
        );
        expect(_tree(temp), before, reason: 'read only');
      },
    );

    test('name parsing rejects rolled-over dates and short profile ids', () {
      expect(
        backupCreatedFromName(_name(_profile, '20260229T000000'), _profile),
        isNull,
        reason: '2026 is not a leap year',
      );
      expect(
        backupCreatedFromName(_name(_profile, '20240229T235959'), _profile),
        DateTime.utc(2024, 2, 29, 23, 59, 59),
      );
      expect(backupCreatedFromName('alkion-backup-x', 'short'), isNull);
    });
  });

  group('stored copies', () {
    test(
      'sizes count backups by name, exports and staging recursively, and delete nothing',
      () async {
        final backups = Directory(p.join(temp.path, 'documents'));
        final exports = Directory(p.join(temp.path, 'document-exports'));
        final staging = Directory(p.join(temp.path, 'alkion-documents'));
        await _write(
          p.join(backups.path, _name(_profile, '20261101T080000')),
          1000,
        );
        await _write(
          p.join(backups.path, _name(_other, '20261102T080000')),
          500,
        );
        // The writer's leftovers count; unrelated documents do not.
        await _write(
          p.join(
            backups.path,
            '.alkion-backup-work-0011223344556677',
            'snapshot.sqlite',
          ),
          40,
        );
        await _write(p.join(backups.path, 'unrelated-thesis.pdf'), 99999);
        await _write(p.join(exports.path, 'export-1', 'history.csv'), 250);
        await _write(p.join(exports.path, 'export-2', 'history.json'), 750);
        await _write(p.join(staging.path, 'uuid-1', 'source.complete'), 2048);
        // A link inside a counted directory is never followed.
        await Link(p.join(exports.path, 'outside')).create(backups.path);
        final before = _tree(temp);
        final sizes = await measureStoredCopies(
          StoredCopyRoots(backups: backups, exports: exports, staging: staging),
        );
        expect(sizes.backups, 1540);
        expect(sizes.exports, 1000);
        expect(sizes.staging, 2048);
        expect(_tree(temp), before, reason: 'nothing is created or deleted');
      },
    );

    test(
      'a missing root is empty; an unresolved or linked root is omitted',
      () async {
        final real = await Directory(p.join(temp.path, 'real')).create();
        await _write(p.join(real.path, 'a'), 10);
        final linked = Link(p.join(temp.path, 'linked'));
        await linked.create(real.path);
        final sizes = await measureStoredCopies(
          StoredCopyRoots(
            backups: Directory(p.join(temp.path, 'missing')),
            exports: Directory(linked.path),
          ),
        );
        expect(sizes.backups, 0);
        expect(sizes.exports, isNull);
        expect(sizes.staging, isNull);
        expect(Directory(p.join(temp.path, 'missing')).existsSync(), isFalse);
      },
    );
  });
}
