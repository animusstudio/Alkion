import 'dart:convert';
import 'dart:io';

import 'package:alkion/identity/alkion_identity.dart';
import 'package:alkion/main.dart' show checkedAlkionSupportRoot;
import 'package:alkion/session/notification_envelope.dart';
import 'package:alkion/session/notification_journal.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

final _t0 = DateTime.utc(2026, 6, 3, 10, 30);

NotificationAction _action({String token = 'synthetic-token'}) =>
    NotificationAction(
      applicationId: AlkionIdentity.applicationId,
      profileId: 'synthetic-profile',
      generation: 1,
      draftId: 'synthetic-draft',
      restStart: '2026-06-03T10:29:30.000Z',
      timerRevision: 2,
      token: token,
    );

NotificationView _view({String title = 'Upper A'}) => NotificationView(
  title: title,
  restBody: 'Next · Row',
  elapsedBody: 'Next · Row',
  startedAt: DateTime.utc(2026, 6, 3, 10),
  restStart: DateTime.utc(2026, 6, 3, 10, 29, 30),
  restTotal: 90,
  locale: 'en',
);

String _id(int n) =>
    '00000000-0000-4000-8000-${n.toRadixString(16).padLeft(12, '0')}';

NotificationIntent _intent(
  int n, {
  NotificationIntentKind kind = NotificationIntentKind.add,
  int step = 1,
  String token = 'synthetic-token',
  Duration after = Duration.zero,
  NotificationView? view,
}) => NotificationIntent(
  intentId: _id(n),
  actionId: notificationActionIdFor(kind),
  kind: kind,
  tappedAt: _t0.add(after),
  payload: NotificationEnvelope(
    action: _action(token: token),
    step: step,
    view: view ?? _view(),
  ),
);

void main() {
  late Directory root, journalDir;
  late List<String> flushed;
  late DateTime now;

  NotificationJournal journal({Future<void> Function(String)? checkpoint}) =>
      NotificationJournal(
        journalDir,
        checkpoint: checkpoint,
        clock: () => now,
        flushDirectory: flushed.add,
      );

  setUp(() async {
    root = await Directory.systemTemp.createTemp(
      'alkion-notification-journal-',
    );
    journalDir = notificationJournalDirectory(
      Directory(p.join(root.path, 'files', AlkionIdentity.applicationId)),
    );
    flushed = [];
    now = _t0;
  });
  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  File write(String name, List<int> bytes) {
    journalDir.createSync(recursive: true);
    return File(p.join(journalDir.path, name))..writeAsBytesSync(bytes);
  }

  test('the action identifiers map to their kinds and nothing else', () {
    expect(
      notificationIntentKindFor(AlkionIdentity.addRestAction),
      NotificationIntentKind.add,
    );
    expect(
      notificationIntentKindFor(AlkionIdentity.skipRestAction),
      NotificationIntentKind.skip,
    );
    expect(
      AlkionIdentity.skipRestAction,
      '${AlkionIdentity.preferencePrefix}skip_rest',
    );
    for (final other in [null, '', 'add_30s', 'skip_rest', 'other']) {
      expect(notificationIntentKindFor(other), isNull, reason: other);
    }
  });

  group('append', () {
    test(
      'writes a partial, flushes, renames, then flushes the directory',
      () async {
        final phases = <String>[];
        final intent = _intent(1);
        final name = notificationJournalEntryName(intent);
        expect(name, '${_t0.microsecondsSinceEpoch}-${_id(1)}.json');
        final appended = await journal(
          checkpoint: (phase) async {
            phases.add(phase);
            final names = journalDir.listSync().map((e) => p.basename(e.path));
            if (phase == 'journal-partial-written') {
              expect(names, ['$name.partial']);
              expect(flushed, [p.dirname(journalDir.path)]);
            } else {
              expect(names, [name]);
              expect(flushed.last, journalDir.path);
            }
          },
        ).append(intent);
        final file = appended.file;
        expect(appended.directoryFlushed, isTrue);
        expect(phases, ['journal-partial-written', 'journal-renamed']);
        expect(p.basename(file.path), name);
        expect(file.readAsStringSync(), intent.encode());
        // Created once: the parent is flushed after creating the directory.
        expect(flushed, [p.dirname(journalDir.path), journalDir.path]);
        final entries = await journal().read();
        expect(entries.single.intent!.encode(), intent.encode());
        expect(entries.single.problem, isNull);
        expect(entries.single.bytes, utf8.encode(intent.encode()));
      },
    );

    test(
      'a failed directory flush after the rename still commits the entry',
      () async {
        final phases = <String>[];
        final appended = await NotificationJournal(
          journalDir,
          clock: () => now,
          checkpoint: (phase) async => phases.add(phase),
          flushDirectory: (path) {
            if (path == journalDir.path) {
              throw const FileSystemException('synthetic fsync failure');
            }
          },
        ).append(_intent(1));
        expect(appended.directoryFlushed, isFalse);
        expect(phases, ['journal-partial-written', 'journal-renamed']);
        expect((await journal().read()).single.intent!.intentId, _id(1));
      },
    );

    test('the default directory flush works on the host', () async {
      await NotificationJournal(journalDir).append(_intent(1));
      expect(await NotificationJournal(journalDir).read(), hasLength(1));
    });

    test(
      'refuses at the cap; undecodable entries count, partials do not',
      () async {
        for (var n = 1; n < notificationJournalMaxEntries; n++) {
          await journal().append(_intent(n, after: Duration(seconds: n)));
        }
        write('garbage.json', [0xff, 0x00]);
        write('${_t0.microsecondsSinceEpoch}-${_id(999)}.json.partial', [1]);
        await expectLater(
          journal().append(_intent(100)),
          throwsA(
            isA<NotificationJournalRefused>().having(
              (e) => e.reason,
              'reason',
              'full',
            ),
          ),
        );
        expect(
          journalDir.listSync().where((e) => !e.path.endsWith('.partial')),
          hasLength(notificationJournalMaxEntries),
        );
        await journal().delete((await journal().read()).first);
        await journal().append(_intent(100));
      },
    );

    test('refuses an entry over the byte bound and writes nothing', () async {
      await expectLater(
        journal().append(_intent(1, view: _view(title: 'x' * 9000))),
        throwsA(
          isA<NotificationJournalRefused>().having(
            (e) => e.reason,
            'reason',
            'entry_oversize',
          ),
        ),
      );
      expect(journalDir.existsSync(), isFalse);
    });

    test('refuses a journal path that is a link or a file', () async {
      final real = Directory(p.join(root.path, 'elsewhere'))..createSync();
      Link(journalDir.path).createSync(real.path, recursive: true);
      for (final action in [
        () => journal().append(_intent(1)),
        () => journal().read(),
      ]) {
        await expectLater(action(), throwsA(isA<NotificationJournalRefused>()));
      }
      expect(real.listSync(), isEmpty);
      Link(journalDir.path).deleteSync();
      File(journalDir.path).writeAsStringSync('x');
      await expectLater(
        journal().append(_intent(1)),
        throwsA(isA<NotificationJournalRefused>()),
      );
    });
  });

  group('read', () {
    test(
      'a missing directory is an empty journal and is not created',
      () async {
        expect(await journal().read(), isEmpty);
        expect(journalDir.existsSync(), isFalse);
        expect(journal().removeStalePartials(), 0);
      },
    );

    test(
      'orders unreadable entries first, then by token, step, time, id',
      () async {
        final intents = [
          _intent(5, token: 'b-token', step: 1),
          _intent(4, step: 2, after: const Duration(seconds: 1)),
          _intent(3, step: 1, after: const Duration(seconds: 3)),
          _intent(2, step: 1, after: const Duration(seconds: 3)),
          _intent(1, step: 1, after: const Duration(seconds: 9)),
          _intent(6, token: 'a-token', step: 7),
        ];
        for (final intent in intents) {
          await journal().append(intent);
        }
        write('zz.json', utf8.encode('{}'));
        write('aa.json', utf8.encode('[]'));
        final entries = await journal().read();
        expect(entries.take(2).map((e) => e.name), ['aa.json', 'zz.json']);
        expect(
          entries.take(2).map((e) => e.problem),
          everyElement('name_mismatch'),
        );
        expect(entries.skip(2).map((e) => e.intent!.intentId), [
          _id(6),
          _id(5),
          _id(2),
          _id(3),
          _id(1),
          _id(4),
        ]);
      },
    );

    group('bounds and consistency are enforced before decoding', () {
      Future<NotificationJournalEntry> readOne() async =>
          (await journal().read()).single;

      test('an entry over 8 KiB is unreadable even if it would decode', () async {
        final intent = _intent(1);
        final source = intent.encode();
        final padded =
            '${' ' * (notificationJournalMaxEntryBytes + 1 - utf8Length(source))}$source';
        expect(
          utf8.encode(padded).length,
          notificationJournalMaxEntryBytes + 1,
        );
        expect(NotificationIntent.decode(padded), isNotNull);
        write(notificationJournalEntryName(intent), utf8.encode(padded));
        final entry = await readOne();
        expect(entry.intent, isNull);
        expect(entry.problem, 'entry_oversize');
        expect(entry.bytes, utf8.encode(padded));
        // Exactly at the bound it is readable.
        final atBound = padded.substring(1);
        write(notificationJournalEntryName(intent), utf8.encode(atBound));
        expect((await readOne()).intent, isNotNull);
      });

      test('an embedded payload over 4096 bytes is unreadable', () async {
        String withTitle(String title) =>
            _intent(1, view: _view(title: title)).encode();
        var title = 'é' * 1000;
        while (utf8Length(
              jsonEncode((jsonDecode(withTitle(title)) as Map)['payload']),
            ) <=
            notificationPayloadByteLimit) {
          title += 'a';
        }
        final source = withTitle(title);
        expect(
          utf8.encode(source).length,
          lessThan(notificationJournalMaxEntryBytes),
        );
        expect(NotificationIntent.decode(source), isNotNull);
        write(notificationJournalEntryName(_intent(1)), utf8.encode(source));
        final entry = await readOne();
        expect(entry.problem, 'payload_oversize');
        expect(entry.bytes, utf8.encode(source));
        final fits = withTitle(title.substring(0, title.length - 1));
        write(notificationJournalEntryName(_intent(1)), utf8.encode(fits));
        expect((await readOne()).intent, isNotNull);
      });

      test(
        'a kind that disagrees with its action identifier is unreadable',
        () async {
          for (final (kind, actionId) in [
            ('add', AlkionIdentity.skipRestAction),
            ('skip', AlkionIdentity.addRestAction),
            ('add', '${AlkionIdentity.preferencePrefix}other'),
            ('other', AlkionIdentity.addRestAction),
          ]) {
            final json = _intent(1).toJson()
              ..['kind'] = kind
              ..['action_id'] = actionId;
            final bytes = utf8.encode(jsonEncode(json));
            write(notificationJournalEntryName(_intent(1)), bytes);
            final entry = await readOne();
            expect(entry.problem, 'kind_mismatch', reason: '$kind $actionId');
            expect(entry.bytes, bytes);
          }
        },
      );

      test('a name that disagrees with the content is unreadable', () async {
        final intent = _intent(1);
        for (final name in [
          '${_t0.microsecondsSinceEpoch + 1}-${_id(1)}.json',
          '${_t0.microsecondsSinceEpoch}-${_id(2)}.json',
          'intent.json',
          '${_t0.microsecondsSinceEpoch}-${_id(1)}.txt',
        ]) {
          journalDir.createSync(recursive: true);
          for (final e in journalDir.listSync()) {
            e.deleteSync();
          }
          write(name, utf8.encode(intent.encode()));
          final entry = await readOne();
          expect(entry.problem, 'name_mismatch', reason: name);
          expect(entry.name, name);
        }
      });

      test('undecodable bytes are kept exactly', () async {
        final name = notificationJournalEntryName(_intent(1));
        for (final bytes in [
          <int>[0xff, 0xfe, 0x00, 0x7b],
          utf8.encode('{"format":"alkion-notification-intent/1"'),
          utf8.encode(
            '{"payload":{},"kind":"add","action_id":"${AlkionIdentity.addRestAction}"}',
          ),
          <int>[],
        ]) {
          write(name, bytes);
          final entry = await readOne();
          expect(entry.intent, isNull);
          expect(entry.problem, isNotNull);
          expect(entry.bytes, bytes);
        }
      });
    });

    test(
      'ignores partials, subdirectories and links without following them',
      () async {
        await journal().append(_intent(1));
        final outside = File(p.join(root.path, 'outside.json'))
          ..writeAsStringSync(_intent(2).encode());
        Link(
          p.join(journalDir.path, notificationJournalEntryName(_intent(2))),
        ).createSync(outside.path);
        Directory(p.join(journalDir.path, 'nested.json')).createSync();
        write('${notificationJournalEntryName(_intent(3))}.partial', [1, 2]);
        final entries = await journal().read();
        expect(entries.map((e) => e.intent?.intentId), [_id(1)]);
      },
    );

    test('a file that vanishes while being read is skipped', () async {
      await journal().append(_intent(1));
      await journal().append(_intent(2, after: const Duration(seconds: 1)));
      // read() lists both files and yields at its first read; the owner then
      // deletes both. Files are read in turn, so at least the second one is
      // already gone when its read starts.
      final reading = journal().read();
      for (final file in journalDir.listSync()) {
        file.deleteSync();
      }
      final entries = await reading;
      expect(entries.length, lessThanOrEqualTo(1));
      expect(entries.every((e) => e.readable), isTrue);
    });

    test(
      'a directory that vanishes after the existence check reads as empty',
      () async {
        expect(journalDir.existsSync(), isFalse);
        final overrides = _VanishedDirectory(journalDir.path);
        final entries = await IOOverrides.runWithIOOverrides(
          () => journal().read(),
          overrides,
        );
        expect(overrides.reported, isTrue);
        expect(entries, isEmpty);
        expect(
          IOOverrides.runWithIOOverrides(
            () => journal().removeStalePartials(),
            overrides,
          ),
          0,
        );
      },
    );

    test('an entry that cannot be read is reported without bytes', () async {
      if (Platform.isWindows) return;
      final file = write(notificationJournalEntryName(_intent(1)), [1]);
      Process.runSync('chmod', ['000', file.path]);
      addTearDown(() => Process.runSync('chmod', ['600', file.path]));
      if (await file.readAsBytes().then((_) => true, onError: (_) => false)) {
        markTestSkipped('running with permission bypass');
        return;
      }
      final entry = (await journal().read()).single;
      expect(entry.problem, 'io');
      expect(entry.bytes, isNull);
      expect(entry.intent, isNull);
    });
  });

  test(
    'delete removes an entry and treats a missing file as removed',
    () async {
      await journal().append(_intent(1));
      final entry = (await journal().read()).single;
      await journal().delete(entry);
      expect(await journal().read(), isEmpty);
      await journal().delete(entry);
    },
  );

  test(
    'stale partials older than 60 s are removed, younger ones kept',
    () async {
      final old = write('${notificationJournalEntryName(_intent(1))}.partial', [
        1,
      ]);
      final young = write(
        '${notificationJournalEntryName(_intent(2))}.partial',
        [2],
      );
      final committed = write(
        notificationJournalEntryName(_intent(3)),
        utf8.encode(_intent(3).encode()),
      );
      now = DateTime.now().toUtc();
      old.setLastModifiedSync(now.subtract(const Duration(seconds: 61)));
      young.setLastModifiedSync(now.subtract(const Duration(seconds: 59)));
      committed.setLastModifiedSync(now.subtract(const Duration(hours: 1)));
      expect(journal().removeStalePartials(), 1);
      expect(old.existsSync(), isFalse);
      expect(young.existsSync(), isTrue);
      expect(committed.existsSync(), isTrue);
      // Append cleans up as well.
      young.setLastModifiedSync(now.subtract(const Duration(minutes: 2)));
      await journal().append(_intent(4));
      expect(young.existsSync(), isFalse);
    },
  );

  test(
    'owner and background name one journal through different path strings',
    () async {
      // Android: the owner's checked root is canonical (/data/data/...),
      // path_provider in the background starts /data/user/0, an alias.
      final canonical = Directory(
        p.join(root.path, 'data', 'data', 'pkg', 'files'),
      )..createSync(recursive: true);
      Directory(p.join(root.path, 'data', 'user')).createSync(recursive: true);
      Link(
        p.join(root.path, 'data', 'user', '0'),
      ).createSync(p.join(root.path, 'data', 'data'));
      final alias = Directory(
        p.join(root.path, 'data', 'user', '0', 'pkg', 'files'),
      );
      final owner = await checkedAlkionSupportRoot(
        verifyIdentity: () async => null,
        supportDirectory: () async => canonical,
      );
      final background = notificationSupportRoot(alias);
      final ownerJournal = notificationJournalDirectory(owner);
      final backgroundJournal = notificationJournalDirectory(background);
      expect(ownerJournal.path, isNot(backgroundJournal.path));
      final intent = _intent(1);
      await NotificationJournal(backgroundJournal).append(intent);
      expect(
        await FileSystemEntity.identical(
          ownerJournal.path,
          backgroundJournal.path,
        ),
        isTrue,
      );
      final entries = await NotificationJournal(ownerJournal).read();
      expect(entries.single.intent!.encode(), intent.encode());
      // The journal stays outside the support root.
      expect(p.isWithin(owner.path, ownerJournal.path), isFalse);
    },
  );
}

/// Reports a missing [path] as a directory once, so the listing that follows
/// finds it gone.
final class _VanishedDirectory extends IOOverrides {
  _VanishedDirectory(this.path);
  final String path;
  bool reported = false;
  @override
  FileSystemEntityType fseGetTypeSync(String path, bool followLinks) {
    if (path == this.path) {
      reported = true;
      return FileSystemEntityType.directory;
    }
    return super.fseGetTypeSync(path, followLinks);
  }
}
