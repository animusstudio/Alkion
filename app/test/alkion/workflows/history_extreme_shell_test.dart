import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';
import 'package:alkion/data/exercise_repository.dart' show DomainRecovery;
import 'package:alkion/data/session_repository.dart';
import 'package:alkion/l10n/app_localizations.dart';
import 'package:alkion/session/session_manager.dart';
import 'package:alkion/session/set_values_editor.dart';
import 'package:alkion/settings/settings_service.dart';
import 'package:alkion/shell/app_shell.dart';
import 'package:alkion/store/local_store.dart';
import 'package:alkion/theme/app_theme.dart';
import 'package:alkion/theme/icons.dart';
import 'package:alkion/theme/tokens.dart';
import 'package:alkion/transfer/transfer_service.dart';
import 'package:alkion/ui/history_screen.dart';
import 'package:alkion/ui/profile_screen.dart';
import 'package:alkion/ui/set_editor_sheet.dart';
import 'package:alkion/units/unit_service.dart';
import 'package:alkion/util/dates.dart';
import 'package:alkion/widgets/fit_label.dart';

import '../../support/layout_expect.dart';
import '../domains/best_load_consumers_test.dart'
    show ConsumerHarness, editLoad, importedBytes, visibility;
import '../domains/local_screen_harness.dart';
import 'compatibility_history_test.dart' show checkpoint;

/// The accepted overflow fixture's set rows on a clock-derived in-window day,
/// plus one working set whose reps are unavailable, on its own exercise. Its
/// set number keeps Progress's default target on the fixture's existing tie.
Uint8List historyExtremeBytes(DateTime now) {
  final export =
      jsonDecode(utf8.decode(importedBytes(includeOverflow: true)))
          as Map<String, dynamic>;
  final data = export['data'] as Map<String, dynamic>;
  for (final session in data['sessions'] as List) {
    (session as Map)['date'] = isoDate(now);
  }
  (data['exercises'] as List).add({
    'id': 'reps-null',
    'name': 'Imported reps-null',
    'slug': 'reps-null',
    'muscle_group': 'chest',
    'compound': 0,
    'plate_step_kg': '2.50',
    'is_template': 0,
  });
  (data['sets'] as List).add({
    'id': 'reps-null',
    'session_id': 'old',
    'exercise_id': 'reps-null',
    'set_number': 0,
    'weight_kg': '12.5',
    'reps': null,
    'rir': null,
    'is_warmup': 0,
    'is_top_set': 1,
    'is_pr': 0,
  });
  return Uint8List.fromList(utf8.encode(jsonEncode(export)));
}

/// A small synthetic full export: one exercise per distinct set exercise.
Uint8List exportBytes(
  List<(String, String)> sessions,
  List<Map<String, Object?>> sets,
) => Uint8List.fromList(
  utf8.encode(
    jsonEncode({
      'format': 'reps-export',
      'version': 1,
      'kind': 'full',
      'settings': <String, Object?>{},
      'data': {
        'exercises': [
          for (final id in {for (final s in sets) s['exercise_id']})
            {
              'id': id,
              'name': 'Synthetic $id',
              'slug': id,
              'muscle_group': 'chest',
              'compound': 0,
              'plate_step_kg': '2.50',
              'is_template': 0,
            },
        ],
        'day_templates': [],
        'day_template_items': [],
        'sessions': [
          for (final (id, date) in sessions)
            {'id': id, 'date': date, 'created_at': '${date}T09:00:00Z'},
        ],
        'sets': sets,
        'bodyweight_logs': [],
        'muscle_targets': [],
      },
    }),
  ),
);

Map<String, Object?> setRow(
  String id,
  String session,
  String load, {
  String exercise = 'lift',
  int number = 1,
  int reps = 1,
  int warmup = 0,
}) => {
  'id': id,
  'session_id': session,
  'exercise_id': exercise,
  'set_number': number,
  'weight_kg': load,
  'reps': reps,
  'rir': null,
  'is_warmup': warmup,
  'is_top_set': 0,
  'is_pr': 0,
};

String daysBefore(int days) {
  final now = DateTime.now();
  return isoDate(DateTime(now.year, now.month, now.day - days));
}

/// Fails if any [FitLabel] showing [text] fell back to an ellipsis. With
/// [cardHeader], only the labels in a History card are checked, and each
/// must also render unshrunk across the card rather than its narrow column.
void expectWhole(WidgetTester tester, String text, {bool cardHeader = false}) {
  final label = find.byWidgetPredicate((w) => w is FitLabel && w.text == text);
  final labels = tester.widgetList<FitLabel>(
    cardHeader
        ? find.descendant(of: find.byType(SessionCard), matching: label)
        : label,
  );
  expect(labels, isNotEmpty, reason: text);
  for (final widget in labels) {
    final found = find.byWidget(widget);
    final fit = tester.renderObject<RenderFitLabel>(found);
    expect(fit.ellipsized, isFalse, reason: '"$text" is ellipsized');
    if (cardHeader) {
      expect(fit.appliedScale, 1.0, reason: '"$text" is shrunk');
      final card = tester.getSize(
        find.ancestor(of: found, matching: find.byType(SessionCard)).first,
      );
      // Laid out against the card's full row, not its narrow column.
      expect(
        fit.constraints.maxWidth,
        greaterThan(card.width * 0.85),
        reason: '"$text" is not full width',
      );
    }
  }
}

/// Every reported Flutter error with its stack; `takeException` keeps one.
class ErrorLog {
  final records = <FlutterErrorDetails>[];
  FlutterExceptionHandler? _previous;
  void start() {
    _previous = FlutterError.onError;
    FlutterError.onError = records.add;
  }

  void stop() => FlutterError.onError = _previous;

  String describe() => [
    for (var i = 0; i < records.length; i++)
      '#$i ${records[i].exceptionAsString()}\n'
          'library: ${records[i].library}\n'
          'context: ${records[i].context}\n'
          '${records[i].stack}',
  ].join('\n---\n');

  Future<void> retain(Directory root) async {
    final text = describe();
    // ignore: avoid_print
    print('HISTORY-EXTREME-ERRORS ${records.length}\n$text');
    await File('${root.path}/errors.txt').writeAsString(text, flush: true);
  }
}

Future<void> importInto(
  LocalStore db,
  Uint8List bytes,
  String namespace,
) async {
  final result = await TransferService(
    db,
  ).importArtifact(bytes, namespace: namespace);
  expect(
    result.status,
    ImportStatus.selected,
    reason: result.toJson().toString(),
  );
}

Future<Map<String, String>> localIds(LocalDatabase db, String kind) async => {
  for (final row in await db.getAll(
    'SELECT external_id,local_id FROM origin_mappings WHERE source_kind=?',
    [kind],
  ))
    row['external_id'] as String: row['local_id'] as String,
};

/// Rows, field presence, raw decimals, IDs, revisions, captured flags, the
/// source artifact and revisions, corrections, operations, every other
/// preserved table, the compatible view and the original export bytes.
Future<Map<String, Object?>> snapshot(LocalStore db, String artifact) async => {
  'inventory': await db.inventory(),
  'compat': await db.getAll(
    'SELECT * FROM reps_compat1_legacy_local ORDER BY id',
  ),
  'original': await TransferService(db).originalBytes(artifact),
};

final _en = lookupAppLocalizations(const Locale('en'));

/// The volume tile's explained `—`.
Finder volumeDash(AppLocalizations l) => find.byWidgetPredicate(
  (w) =>
      w is Text &&
      w.data == '—' &&
      w.semanticsLabel == l.alkionVolumeUnavailableLabel,
);

Finder inHistory(Finder finder) =>
    find.descendant(of: find.byType(HistoryScreen), matching: finder);

/// The expanded rows' visible `weight × reps`, in workout order.
List<String> rowTexts(WidgetTester tester) => [
  for (final r in tester.widgetList<RichText>(
    find.descendant(
      of: find.byType(SessionCardBody),
      matching: find.byType(RichText),
    ),
  ))
    if (r.text.toPlainText(includeSemanticsLabels: false).contains('×'))
      r.text.toPlainText(includeSemanticsLabels: false),
];

/// What a summary tile shows, found through its localized caption.
Finder summaryValue(AppLocalizations l, String label, String value) =>
    find.descendant(
      of: find
          .ancestor(
            of: find.text(l.historySummarySuffix(label)),
            matching: find.byType(Column),
          )
          .first,
      matching: find.text(value),
    );

/// Mounts the shell with Today visible: History builds offstage.
Future<void> mountShell(WidgetTester tester, ConsumerHarness h) async {
  await tester.pumpWidget(h.wrap(const AppShell()));
  await settleReal(tester, ticks: 12);
  final stack = tester.widget<IndexedStack>(
    find
        .descendant(
          of: find.byType(AppShell),
          matching: find.byType(IndexedStack),
        )
        .first,
  );
  expect(stack.index, 0, reason: 'Today visible, History offstage');
  expect(find.byType(HistoryScreen, skipOffstage: false), findsOneWidget);
}

Future<void> showHistory(WidgetTester tester, ConsumerHarness h) async {
  await mountShell(tester, h);
  await openTab(tester, WIcons.history);
  await settleUntilFound(tester, find.byType(SessionCard), where: 'History');
}

Future<void> expandFirstCard(WidgetTester tester) async {
  final card = find.byType(SessionCard).first;
  await tester.ensureVisible(card);
  await tester.tap(card, warnIfMissed: false);
  await settleReal(tester, ticks: 15);
  expect(find.byType(SessionCardBody), findsOneWidget);
}

const kgRows = [
  '12.5kg ×—',
  '60kg ×5',
  '— ×5',
  '— ×5',
  '— ×5',
  '— ×5',
  '— ×5',
  '— ×5',
  '-5.25kg ×5',
  '0kg ×5',
];
const lbRows = [
  '28lb ×—',
  '132lb ×5',
  '— ×5',
  '— ×5',
  '— ×5',
  '— ×5',
  '— ×5',
  '— ×5',
  '-12lb ×5',
  '0lb ×5',
];

/// The repaired extreme History: unavailable tile, explanations, 5/11 known.
void expectExtremeTile(AppLocalizations l, Unit unit) {
  expect(inHistory(volumeDash(l)), findsOneWidget);
  expect(
    inHistory(find.text(l.alkionVolumeOutOfRange(unit.name))),
    findsOneWidget,
  );
  // The four-week line and the card header both read History evidence.
  expect(inHistory(find.text(l.alkionKnownSubtotal(5, 11))), findsNWidgets(2));
  expect(inHistory(find.text(l.alkionKnownSubtotal(4, 11))), findsNothing);
  expect(inHistory(find.text(l.alkionCompatibility)), findsOneWidget);
  expect(inHistory(find.text(l.alkionLegacyFallback)), findsNothing);
}

void expectExtremeRows(WidgetTester tester, AppLocalizations l, Unit unit) {
  expect(rowTexts(tester), unit == Unit.kg ? kgRows : lbRows);
  expect(inHistory(find.text(l.alkionLoadUnavailable)), findsOneWidget);
  expect(
    find.descendant(
      of: find.byType(SessionCardBody),
      matching: find.byIcon(WIcons.bolt),
    ),
    findsNWidgets(9),
  );
  for (final bad in ['Infinity', 'NaN', '9223372036854775807']) {
    expect(
      find.textContaining(bad, findRichText: true, skipOffstage: false),
      findsNothing,
    );
  }
}

/// Opens the set editor on the overflow row and its editing card, checks the
/// unavailable line, seed and caption, then closes without an edit.
Future<void> openOverflowEditor(
  WidgetTester tester,
  AppLocalizations l,
  String overflowSet,
  String exerciseName,
) async {
  await tester.ensureVisible(find.text(exerciseName));
  await tester.tap(find.text(exerciseName));
  await settleReal(tester, ticks: 10);
  final sheet = find.byType(SetEditorSheet);
  expect(sheet, findsOneWidget);
  final line = find.byKey(Key('set-line-$overflowSet'));
  final text = tester
      .widgetList<RichText>(
        find.descendant(of: line, matching: find.byType(RichText)),
      )
      .map((r) => r.text.toPlainText(includeSemanticsLabels: false))
      .join(' | ');
  expect(text, contains('—  ×  5'));
  expect(text, isNot(contains('kg')));
  await tester.tap(line);
  await settleReal(tester, ticks: 8);
  expect(
    tester.widget<SetValuesEditor>(find.byType(SetValuesEditor)).weightKg,
    0,
  );
  final ruler = tester.getSemantics(find.byKey(const Key('live-weight')));
  expect(ruler.value, '0');
  expect(
    find.descendant(of: sheet, matching: find.text(l.alkionLoadUnavailable)),
    findsOneWidget,
  );
}

/// Dismisses the sheet's route without an edit, as its barrier does.
Future<void> closeSheet(WidgetTester tester) async {
  Navigator.of(tester.element(find.byType(SetEditorSheet))).pop();
  await settleReal(tester, ticks: 10);
  expect(find.byType(SetEditorSheet), findsNothing);
}

void main() {
  testWidgets(
    'imported extreme History mounts offstage in the shell without any error',
    (tester) async {
      final h = ConsumerHarness();
      final bytes = historyExtremeBytes(DateTime.now());
      await h.open(
        tester,
        seed: (db) async {
          await importInto(db, bytes, 'history-extreme');
          await File('${h.root.path}/manifest.json').writeAsString(
            jsonEncode({
              'artifact_sha256': sha256.convert(bytes).toString(),
              'artifact_bytes': bytes.length,
              'source_fixture_sha256': sha256
                  .convert(importedBytes(includeOverflow: true))
                  .toString(),
            }),
            flush: true,
          );
        },
      );
      final errors = ErrorLog()..start();
      var described = '';
      try {
        setPhone(tester, width: 412, height: 1400);
        await mountShell(tester, h);
      } finally {
        errors.stop();
        // Described while mounted: diagnostics of unmounted elements throw.
        described = errors.describe();
        await tester.runAsync(() => errors.retain(h.root));
        await h.unmount(tester);
        await h.close(tester);
      }
      expect(errors.records.length, 0, reason: described);
    },
  );

  testWidgets(
    'repaired extreme History reads, opens the set editor and is preserved '
    'across two reopens; unit switches and an ordinary edit refresh it',
    (tester) async {
      final semantics = tester.ensureSemantics();
      final h = ConsumerHarness();
      final l = _en;
      final bytes = historyExtremeBytes(DateTime.now());
      late Map<String, String> sets;
      late String workout, artifact;
      late Map<String, Object?> baseline;
      await h.open(
        tester,
        seed: (db) async {
          await importInto(db, bytes, 'history-extreme');
          sets = await localIds(db, 'sets');
          workout = (await localIds(db, 'sessions'))['old']!;
          artifact =
              (await db.get(
                    'SELECT artifact_id FROM source_artifacts',
                  ))['artifact_id']
                  as String;
          expect(await db.getAll('SELECT * FROM operations'), isEmpty);
          // Before any read.
          baseline = await snapshot(db, artifact);
          await checkpoint(db, h.root, 'imported');
        },
      );
      final errors = ErrorLog()..start();
      var described = '';
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      // Profile's platform reads, pointed at the disposable root.
      messenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (call) async => h.root.path,
      );
      messenger.setMockMethodCallHandler(
        const MethodChannel('dev.fluttercommunity.plus/package_info'),
        (call) async => <String, dynamic>{
          'appName': 'Alkion Dev',
          'packageName': 'dev.animusstudio.alkion.dev',
          'version': '0.0.0',
          'buildNumber': '0',
          'buildSignature': '',
        },
      );
      try {
        setPhone(tester, width: 412, height: 2400);

        // ── Read-only interval ──────────────────────────────────────────
        await showHistory(tester, h);
        expectExtremeTile(l, Unit.kg);
        expect(
          summaryValue(l, l.historySummaryPrs, '9'),
          findsOneWidget,
          reason: 'PR count unchanged',
        );
        await expandFirstCard(tester);
        expectExtremeRows(tester, l, Unit.kg);
        expect(
          find.bySemanticsLabel(RegExp(l.alkionRepsUnavailableLabel)),
          findsWidgets,
        );
        expect(
          find.bySemanticsLabel(RegExp(l.alkionLoadUnavailableLabel)),
          findsWidgets,
        );
        await openOverflowEditor(
          tester,
          l,
          sets['overflow']!,
          'Imported overflow',
        );
        await closeSheet(tester);
        expectExtremeRows(tester, l, Unit.kg);
        // Read-only consumer: Profile counts with the extreme fixture.
        await tester.pumpWidget(
          h.wrap(Scaffold(body: ProfileScreen(onClose: () {}))),
        );
        await settleReal(tester, ticks: 10);
        for (final (label, value) in [
          (l.profileStatSessions, '1'),
          (l.profileStatPrs, '9'),
        ]) {
          expect(
            find.descendant(
              of: find
                  .ancestor(
                    of: find.text(label.toUpperCase()),
                    matching: find.byType(Column),
                  )
                  .first,
              matching: find.text(value),
            ),
            findsOneWidget,
            reason: label,
          );
        }
        expect(errors.records, isEmpty, reason: errors.describe());
        await tester.runAsync(() async {
          expect(await snapshot(h.database, artifact), baseline);
          await checkpoint(h.database, h.root, 'after-read-only');
        });

        // ── Two independent reopens repeat the History results ──────────
        for (var i = 0; i < 2; i++) {
          await h.reopen(tester, i);
          await tester.runAsync(
            () async => expect(await snapshot(h.database, artifact), baseline),
          );
          await showHistory(tester, h);
          expectExtremeTile(l, Unit.kg);
          await expandFirstCard(tester);
          expectExtremeRows(tester, l, Unit.kg);
          await openOverflowEditor(
            tester,
            l,
            sets['overflow']!,
            'Imported overflow',
          );
          await closeSheet(tester);
          expect(errors.records, isEmpty, reason: errors.describe());
          await tester.runAsync(
            () async => expect(await snapshot(h.database, artifact), baseline),
          );
        }

        // ── Outside the read-only interval ──────────────────────────────
        // One stream instance re-listens; History and Summary bases differ.
        await tester.runAsync(() async {
          final stream = SessionRepository.local(
            h.localDatabase,
          ).watchSessionStats();
          for (var i = 0; i < 2; i++) {
            final row = (await stream.first).single;
            final evidence = row.volumeEvidence!;
            expect((evidence.known, evidence.total), (5, 11));
            expect((row.coverage!.known, row.coverage!.total), (4, 11));
            // 5 × 10^400 + 768.75, from the fixture text.
            final ten = BigInt.from(10);
            expect(
              evidence.knownSum.coefficient * BigInt.from(100),
              (BigInt.from(5) * ten.pow(400) * BigInt.from(100) +
                      BigInt.from(76875)) *
                  ten.pow(evidence.knownSum.scale),
            );
            expect(row.exerciseCount, 10);
            expect(row.prCount, 9);
            expect(row.tonnageKg.isFinite, isFalse, reason: 'legacy only');
          }
          expect(
            (await h.database.get(
              'SELECT COUNT(DISTINCT exercise_id) AS n FROM reps_compat1_legacy_local WHERE deleted=0 AND legacy_local_pr=1',
            ))['n'],
            9,
          );
        });

        // Unit preference writes, on the History still shown and expanded
        // from the last reopen.
        expectExtremeRows(tester, l, Unit.kg);
        h.units.setUnit(Unit.lb);
        await settleReal(tester, ticks: 8);
        expectExtremeTile(l, Unit.lb);
        expectExtremeRows(tester, l, Unit.lb);
        h.units.setUnit(Unit.kg);
        await settleReal(tester, ticks: 8);
        expectExtremeTile(l, Unit.kg);
        expectExtremeRows(tester, l, Unit.kg);
        await tester.runAsync(() async {
          await h.units.flushPersistence();
          final after = await snapshot(h.database, artifact);
          final inventory = after['inventory'] as Map;
          final base = baseline['inventory'] as Map;
          for (final table in inventory.keys) {
            if (table == 'local_state') continue;
            expect(inventory[table], base[table], reason: table as String);
          }
          expect(after['original'], baseline['original']);
          expect(
            (inventory['local_state'] as List)
                .map((r) => r['state_key'])
                .toList(),
            contains('units'),
          );
        });

        // The deliberate ordinary edit; the mounted tile refreshes.
        final history = tester.state(find.byType(HistoryScreen));
        await tester.runAsync(
          () =>
              editLoad(h.localDatabase, workout, sets['overflow']!, '20.0000'),
        );
        await settleReal(tester, ticks: 12);
        expect(tester.state(find.byType(HistoryScreen)), same(history));
        expect(inHistory(find.text('874kg')), findsOneWidget);
        expect(inHistory(volumeDash(l)), findsNothing);
        expect(
          inHistory(find.text(l.alkionVolumeOutOfRange('kg'))),
          findsNothing,
        );
        expect(
          inHistory(find.text(l.alkionKnownSubtotal(5, 11))),
          findsNWidgets(2),
        );
        expect(
          rowTexts(tester),
          [for (final row in kgRows) row]..[6] = '20kg ×5',
        );
        expect(summaryValue(l, l.historySummaryPrs, '9'), findsOneWidget);
        expect(
          find.descendant(
            of: find.byType(SessionCardBody),
            matching: find.byIcon(WIcons.bolt),
          ),
          findsNWidgets(9),
        );
        h.units.setUnit(Unit.lb);
        await settleReal(tester, ticks: 8);
        expect(inHistory(find.text('1.9k lb')), findsOneWidget);
        h.units.setUnit(Unit.kg);
        await settleReal(tester, ticks: 8);
        await tester.runAsync(() async {
          final after =
              (await snapshot(h.database, artifact))['inventory'] as Map;
          final base = baseline['inventory'] as Map;
          final changed = sets['overflow'];
          final before = {for (final r in base['sets'] as List) r['id']: r};
          for (final row in after['sets'] as List) {
            if (row['id'] == changed) {
              expect(row['weight_kg'], '20.0000');
              expect(row['revision'], before[changed]['revision'] + 1);
            } else {
              expect(row, before[row['id']], reason: row['id'] as String);
            }
          }
          expect(after['source_revisions'], base['source_revisions']);
          expect(after['source_artifacts'], base['source_artifacts']);
          expect(
            await TransferService(h.database).originalBytes(artifact),
            bytes,
          );
          await checkpoint(h.database, h.root, 'after-edit');
        });

        // A remounted History shows the same evidence.
        await h.unmount(tester);
        await showHistory(tester, h);
        expect(inHistory(find.text('874kg')), findsOneWidget);
        await expandFirstCard(tester);
        expect(rowTexts(tester)[6], '20kg ×5');
      } finally {
        errors.stop();
        described = errors.describe();
        await tester.runAsync(() => errors.retain(h.root));
        for (final channel in [
          'plugins.flutter.io/path_provider',
          'dev.fluttercommunity.plus/package_info',
        ]) {
          messenger.setMockMethodCallHandler(MethodChannel(channel), null);
        }
        await h.unmount(tester);
        await h.close(tester);
        semantics.dispose();
      }
      expect(errors.records.length, 0, reason: described);
    },
  );

  testWidgets(
    'a total safe in kg and unsafe in lb is shown, unavailable, then shown',
    (tester) async {
      final h = ConsumerHarness();
      await h.open(
        tester,
        seed: (db) => importInto(
          db,
          exportBytes(
            [('big', daysBefore(0))],
            [setRow('big', 'big', '5000000000000000')],
          ),
          'history-big',
        ),
      );
      try {
        setPhone(tester, width: 412, height: 1400);
        await showHistory(tester, h);
        await expandFirstCard(tester);
        expect(inHistory(find.text('5000000000000t')), findsOneWidget);
        expect(rowTexts(tester), ['5000000000000000kg ×1']);
        h.units.setUnit(Unit.lb);
        await settleReal(tester, ticks: 8);
        expect(inHistory(volumeDash(_en)), findsOneWidget);
        expect(
          inHistory(find.text(_en.alkionVolumeOutOfRange('lb'))),
          findsOneWidget,
        );
        expect(
          inHistory(find.text(_en.alkionKnownSubtotal(1, 1))),
          findsNothing,
        );
        expect(rowTexts(tester), ['— ×1']);
        h.units.setUnit(Unit.kg);
        await settleReal(tester, ticks: 8);
        expect(inHistory(find.text('5000000000000t')), findsOneWidget);
        expect(inHistory(volumeDash(_en)), findsNothing);
        expect(tester.takeException(), isNull);
      } finally {
        await h.unmount(tester);
        await h.close(tester);
      }
    },
  );

  testWidgets(
    'days 27 and 29 back, warm-ups, a deleted set and a deleted session',
    (tester) async {
      final h = ConsumerHarness();
      late Map<String, String> sets, sessions;
      await h.open(
        tester,
        seed: (db) async {
          await importInto(
            db,
            exportBytes(
              [
                ('in', daysBefore(27)),
                ('out', daysBefore(29)),
                ('gone', daysBefore(1)),
              ],
              [
                setRow('kept', 'in', '10', reps: 3),
                setRow('warm', 'in', '500', number: 2, warmup: 1),
                setRow('dropped', 'in', '300', number: 3),
                setRow('old', 'out', '1000'),
                setRow('later', 'gone', '700'),
              ],
            ),
            'history-window',
          );
          sets = await localIds(db, 'sets');
          sessions = await localIds(db, 'sessions');
        },
      );
      try {
        setPhone(tester, width: 412, height: 1400);
        await showHistory(tester, h);
        // 10 × 3 + 300 + 700; the warm-up and day 29 stay out.
        expect(inHistory(find.text('1t')), findsOneWidget);
        expect(
          summaryValue(_en, _en.historySummarySessions, '2'),
          findsOneWidget,
        );
        await tester.runAsync(() async {
          final db = h.localDatabase;
          final workout = sessions['in']!;
          final parent = await db.get(
            'SELECT revision FROM sessions WHERE id=?',
            [workout],
          );
          final set = await db.get('SELECT revision FROM sets WHERE id=?', [
            sets['dropped'],
          ]);
          final repo = SessionRepository.local(db);
          await repo.commitPrepared(
            repo.prepareHistoryEdit(workout, parent['revision'] as int, {
              'mode': 'delete',
              'set': {'id': sets['dropped'], 'base': set['revision']},
            }),
          );
        });
        await settleReal(tester, ticks: 10);
        expect(inHistory(find.text('730kg')), findsOneWidget);
        await tester.runAsync(
          () => visibility(h.localDatabase, sessions['gone']!, restore: false),
        );
        await settleReal(tester, ticks: 10);
        expect(inHistory(find.text('30kg')), findsOneWidget);
        expect(
          summaryValue(_en, _en.historySummarySessions, '1'),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      } finally {
        await h.unmount(tester);
        await h.close(tester);
      }
    },
  );

  testWidgets('full History evidence beyond the display bound is explained '
      'without a known/total line, though the legacy coverage disagrees', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final h = ConsumerHarness();
    final nines = List.filled(400, '9').join();
    await h.open(
      tester,
      seed: (db) => importInto(
        db,
        exportBytes([('s', daysBefore(0))], [setRow('o', 's', nines, reps: 5)]),
        'history-full-unsafe',
      ),
    );
    try {
      final row = (await tester.runAsync(
        () =>
            SessionRepository.local(h.localDatabase).watchSessionStats().first,
      ))!.single;
      // History: one known set (full); legacy coverage: none known.
      expect((row.volumeEvidence!.known, row.volumeEvidence!.total), (1, 1));
      expect((row.coverage!.known, row.coverage!.total), (0, 1));
      expect(row.coverage!.complete, isFalse);

      setPhone(tester, width: 412, height: 1400);
      await showHistory(tester, h);
      expect(inHistory(volumeDash(_en)), findsOneWidget);
      final tile = tester.getSemantics(
        find.bySemanticsLabel(
          RegExp(
            '(^|\n)${RegExp.escape(_en.alkionVolumeUnavailableLabel)}(\n|\$)',
          ),
        ),
      );
      expect(tile.label, isNot(contains('—')));
      expect(
        inHistory(find.text(_en.alkionVolumeOutOfRange('kg'))),
        findsOneWidget,
      );
      expect(inHistory(find.text(_en.alkionVolumeNoEvidence)), findsNothing);
      // Neither the four-week line nor the card header counts a full set.
      expect(inHistory(find.text(_en.alkionKnownSubtotal(1, 1))), findsNothing);
      expect(inHistory(find.text(_en.alkionKnownSubtotal(0, 1))), findsNothing);
      expect(inHistory(find.textContaining(RegExp(r'\d/\d'))), findsNothing);
      expect(tester.takeException(), isNull);
    } finally {
      await h.unmount(tester);
      await h.close(tester);
      semantics.dispose();
    }
  });

  testWidgets('an infinite legacy tonnage next to valid evidence shows the '
      'evidence', (tester) async {
    final h = ConsumerHarness();
    await h.open(
      tester,
      seed: (db) => importInto(
        db,
        exportBytes([('s', daysBefore(0))], [setRow('a', 's', '80', reps: 5)]),
        'history-tonnage',
      ),
    );
    final database = InfiniteTonnageDatabase(h.database, h.owner);
    try {
      setPhone(tester, width: 412, height: 1400);
      await tester.pumpWidget(
        h.wrap(
          Provider<LocalDatabase>.value(
            value: database,
            child: const Scaffold(body: HistoryScreen()),
          ),
        ),
      );
      await settleUntilFound(
        tester,
        find.byType(SessionCard),
        where: 'History',
      );
      final row = await tester.runAsync(
        () => SessionRepository.local(database).watchSessionStats().first,
      );
      expect(row!.single.tonnageKg, double.infinity);
      expect(find.text('400kg'), findsOneWidget);
      expect(volumeDash(_en), findsNothing);
      expect(tester.takeException(), isNull);
    } finally {
      await h.unmount(tester);
      await h.close(tester);
    }
  });

  for (final (locale, width, scale) in [
    ('en', 320.0, 2.0),
    ('de', 320.0, 2.0),
    ('es', 320.0, 2.0),
    ('it', 320.0, 2.0),
    ('en', 412.0, 1.0),
  ]) {
    final l = lookupAppLocalizations(Locale(locale));
    testWidgets('extreme History and its set editor hold at '
        '${width.toInt()}dp ${scale}x in $locale', (tester) async {
      final h = ConsumerHarness();
      late Map<String, String> sets;
      await h.open(
        tester,
        seed: (db) async {
          await importInto(
            db,
            historyExtremeBytes(DateTime.now()),
            'history-extreme',
          );
          sets = await localIds(db, 'sets');
        },
      );
      try {
        setPhone(tester, width: width, textScale: scale);
        await tester.pumpWidget(localized(h, locale, const AppShell()));
        await settleReal(tester, ticks: 12);
        await openTab(tester, WIcons.history);
        await settleUntilFound(tester, find.byType(SessionCard), where: 'H');
        expect(inHistory(volumeDash(l)), findsOneWidget);
        for (final text in [
          l.alkionVolumeOutOfRange('kg'),
          l.alkionKnownSubtotal(5, 11),
        ]) {
          await scrollIntoView(
            tester,
            find.byType(HistoryScreen),
            find.text(text).first,
          );
        }
        holds(tester, 'tile $locale');
        // Every new label wraps or shrinks whole; none hides the count.
        expectWhole(tester, l.alkionVolumeOutOfRange('kg'));
        await scrollIntoView(
          tester,
          find.byType(HistoryScreen),
          find.byType(SessionCard),
        );
        expectWhole(tester, l.alkionKnownSubtotal(5, 11), cardHeader: true);
        await expandFirstCard(tester);
        await scrollIntoView(
          tester,
          find.byType(HistoryScreen),
          find.text(l.alkionLoadUnavailable),
        );
        expect(rowTexts(tester), kgRows);
        holds(tester, 'rows $locale');
        expectWhole(tester, l.alkionLoadUnavailable);
        await expectLayoutHoldsWhileScrolling(
          tester,
          find.byType(HistoryScreen),
          'History $locale',
        );
        await scrollIntoView(
          tester,
          find.byType(HistoryScreen),
          find.text('Imported overflow'),
        );
        await openOverflowEditor(
          tester,
          l,
          sets['overflow']!,
          'Imported overflow',
        );
        expect(tester.takeException(), isNull);
        expectNoSplitWords(
          tester,
          within: find.byType(SetEditorSheet),
          where: 'set editor $locale',
        );
        expectWhole(tester, l.alkionLoadUnavailable);
        await closeSheet(tester);
      } finally {
        await h.unmount(tester);
        await h.close(tester);
      }
    });

    testWidgets('the longest safe volume strings fit at '
        '${width.toInt()}dp ${scale}x in $locale', (tester) async {
      final h = ConsumerHarness();
      late String workout, set;
      await h.open(
        tester,
        seed: (db) async {
          await importInto(
            db,
            exportBytes(
              [('s', daysBefore(0))],
              [setRow('a', 's', '-9007199254740991')],
            ),
            'history-longest',
          );
          workout = (await localIds(db, 'sessions'))['s']!;
          set = (await localIds(db, 'sets'))['a']!;
        },
      );
      try {
        setPhone(tester, width: width, textScale: scale);
        await tester.pumpWidget(localized(h, locale, const AppShell()));
        await settleReal(tester, ticks: 12);
        await openTab(tester, WIcons.history);
        await settleUntilFound(tester, find.byType(SessionCard), where: 'H');
        for (final (unit, load, shown) in [
          (Unit.kg, '-9007199254740991', '-9007199254740991kg'),
          (Unit.kg, '9007199254740900', '9007199254740.9t'),
          (Unit.lb, '-4085596897510254', '-9007199254740990lb'),
          (Unit.lb, '4085596897510200', '9007199254740.9k lb'),
        ]) {
          if (h.units.unit != unit) {
            h.units.setUnit(unit);
          }
          await tester.runAsync(
            () => editLoad(h.localDatabase, workout, set, load),
          );
          await settleReal(tester, ticks: 10);
          expect(inHistory(find.text(shown)), findsOneWidget, reason: shown);
          final tile = tester.getRect(inHistory(find.text(shown)));
          expect(tile.right, lessThanOrEqualTo(width), reason: shown);
          holds(tester, '$shown $locale');
        }
      } finally {
        await h.unmount(tester);
        await h.close(tester);
      }
    });
  }
}

/// [home] in [locale] over the harness providers, as [ConsumerHarness.wrap]
/// builds them: the app's own locale, so pushed sheets use it too.
Widget localized(ConsumerHarness h, String locale, Widget home) =>
    MultiProvider(
      providers: [
        Provider<LocalDatabase>.value(value: h.localDatabase),
        Provider<DomainRecovery>.value(
          value: DomainRecovery(h.database.recover),
        ),
        ChangeNotifierProvider<UnitService>.value(value: h.units),
        ChangeNotifierProvider<SettingsService>.value(value: h.settings),
        ChangeNotifierProvider<SessionManager>.value(value: h.manager),
      ],
      child: MaterialApp(
        theme: buildTheme(Brightness.dark, accents[0]),
        locale: Locale(locale),
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        home: home,
      ),
    );

/// No exception so far, and no word split on History or an open sheet.
void holds(WidgetTester tester, String where) {
  final error = tester.takeException();
  if (error != null) fail('$where: ${error.toString().split('\n').first}');
  expectNoSplitWords(tester, within: find.byType(HistoryScreen), where: where);
}

/// Returns the legacy `tonnage` column as Infinity on the History stats
/// watch; every other value, including the evidence rows, comes from the
/// actual imported store.
class InfiniteTonnageDatabase extends RealZoneDatabase {
  InfiniteTonnageDatabase(super.database, super.zone);
  @override
  Stream<List<Map<String, dynamic>>> watch(
    String sql, {
    List<Object?> parameters = const [],
  }) {
    final source = super.watch(sql, parameters: parameters);
    if (!sql.startsWith('SELECT se.id, se.revision')) return source;
    return source.map(
      (rows) => [
        for (final row in rows) {...row, 'tonnage': double.infinity},
      ],
    );
  }
}
