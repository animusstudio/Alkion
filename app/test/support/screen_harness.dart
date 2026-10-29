import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:provider/provider.dart';
import 'package:provider/single_child_widget.dart';
import 'package:alkion/data/active_session_draft.dart';
import 'package:alkion/data/finished_session_store.dart';
import 'package:alkion/data/exercise_repository.dart';
import 'package:alkion/domain/local_action.dart';
import 'package:alkion/domain/evidence.dart';
import 'package:alkion/identity/alkion_profile.dart';
import 'package:alkion/store/local_store.dart';
import 'package:alkion/store/schema.dart';
import 'package:alkion/data/models.dart';
import 'package:alkion/identity/identity_service.dart';
import 'package:alkion/l10n/app_localizations.dart';
import 'package:alkion/session/active_session_controller.dart';
import 'package:alkion/session/session_manager.dart';
import 'package:alkion/settings/settings_service.dart';
import 'package:alkion/settings/bodyweight_goal.dart';
import 'package:alkion/shell/w_tab_bar.dart';
import 'package:alkion/theme/icons.dart';
import 'package:alkion/theme/app_theme.dart';
import 'package:alkion/theme/tokens.dart';
import 'package:alkion/units/unit_service.dart';
import 'package:alkion/util/dates.dart';
import 'app_fonts.dart';
import 'layout_expect.dart';

// ── Long names: the seeds that broke the layout in the critique ─────────────

const longExercise =
    'Single-Arm Cable Lateral Raise with Wrist Strap (Behind Back)';
const longExercise2 =
    'Kurzhantel-Schrägbankdrücken mit neutralem Griff und Pause';
const longDay = 'Oberkörper Schwerpunkt Brust & Schultern';
const longFocus = 'Brust · Schultern · Trizeps · Vorderer Delta';
const unscheduledLongDay = 'Beine und Gesäß mit Schwerpunkt Hinterseite';

// ── Conditions the layout must hold at ──────────────────────────────────────

typedef LayoutCondition = ({double width, double textScale, Locale locale});

final List<LayoutCondition> layoutConditions = [
  for (final width in const [320.0, 412.0])
    for (final textScale in const [1.0, 2.0])
      for (final code in const ['en', 'de', 'it'])
        (width: width, textScale: textScale, locale: Locale(code)),
];

String describeCondition(LayoutCondition c) =>
    '${c.width.round()}dp ${c.textScale}x ${c.locale.languageCode}';

class ScreenHarness {
  Directory? _dir;
  WidgetTester? _tester;
  FixtureDatabase? _db;
  late Zone _zone;
  FixtureDatabase get database => _db!;
  late UnitService units;
  late SettingsService settings;
  late IdentityService _identity;
  SessionManager? _manager;
  SessionManager get manager => _manager!;
  Future<void> open(
    WidgetTester tester, {
    Map<String, Object> prefs = const {},
    Future<void> Function(FixtureDatabase) seed = seedLong,
    DateTime? lastSyncedAt,
  }) async {
    _tester = tester;
    await tester.runAsync(() async {
      _zone = Zone.current;
      final dir = await Directory.systemTemp.createTemp('alkion-screen-');
      _dir = dir;
      final d = await FixtureDatabase.open(dir);
      _db = d;
      await seed(d);
      final local = RealZoneDatabase(d, _zone);
      units = UnitService.local(local);
      settings = SettingsService.local(local);
      await units.load();
      await settings.load();
      if (prefs['unit'] == 'lb' || prefs['units.unit'] == 'lb') {
        units.setUnit(Unit.lb);
        await units.flushPersistence();
      }
      if (prefs['settings.profile_name'] case final String name) {
        await settings.setProfileName(name);
      }
      if (prefs['settings.bodyweight_goal'] case final String name) {
        await settings.setBodyweightGoal(
          BodyweightGoal.values.singleWhere((goal) => goal.name == name),
        );
      }
      _identity = IdentityService.local(local);
      await _identity.load();
      await _identity.completeOnboarding();
      _manager = SessionManager(
        draftStore: DraftStore.local(local),
        finishedStore: FinishedSessionStore.local(local),
      );
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (call) async => dir.path,
      );
      messenger.setMockMethodCallHandler(
        const MethodChannel('dev.fluttercommunity.plus/package_info'),
        (call) async => <String, dynamic>{
          'appName': 'Alkion Dev',
          'packageName': 'dev.animusstudio.alkion.dev',
          'version': '0.16.0',
          'buildNumber': '34',
          'buildSignature': '',
        },
      );
      await initializeDateFormatting();
      await preloadAppFonts();
    });
  }

  Widget wrap(
    Widget home, {
    Locale locale = const Locale('en'),
    List<SingleChildWidget> extra = const [],
  }) => MultiProvider(
    providers: [
      Provider<LocalDatabase>.value(value: RealZoneDatabase(database, _zone)),
      Provider<DomainRecovery>.value(
        value: DomainRecovery(() => _zone.run(database.store.recover)),
      ),
      ChangeNotifierProvider<UnitService>.value(value: units),
      ChangeNotifierProvider<SettingsService>.value(value: settings),
      ChangeNotifierProvider<IdentityService>.value(value: _identity),
      ChangeNotifierProvider<SessionManager>.value(value: _manager!),
      ...extra,
    ],
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildTheme(Brightness.dark, accents[0]),
      locale: locale,
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
  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await settleReal(tester, ticks: 5);
  }

  Future<void> close() async {
    Future<void> closeOwned() async {
      _manager?.dispose();
      _manager = null;
      final archive = Platform.environment['ALKION_FIXTURE_ARCHIVE'];
      if (archive != null && _db != null && _dir != null) {
        await File(
          '${_dir!.path}/final.inventory.json',
        ).writeAsString(jsonEncode(await _db!.store.inventory()), flush: true);
      }
      await _db?.close();
      _db = null;
      if (_dir != null) {
        if (archive != null) {
          final root = _dir!;
          if (!root.path.startsWith(
            '${Directory.systemTemp.path}/alkion-screen-',
          )) {
            throw StateError('Unowned fixture directory');
          }
          final destination = Directory(
            '$archive/${root.uri.pathSegments.where((s) => s.isNotEmpty).last}',
          );
          if (await destination.exists()) {
            throw StateError('Fixture archive already exists');
          }
          final hashes = <String, Object?>{};
          Future<void> copy(Directory from, Directory to) async {
            await to.create(recursive: true);
            await for (final item in from.list(followLinks: false)) {
              final name = item.uri.pathSegments
                  .where((s) => s.isNotEmpty)
                  .last;
              if (item is Directory) {
                await copy(item, Directory('${to.path}/$name'));
              } else if (item is File) {
                final original = await item.readAsBytes();
                final target = await item.copy('${to.path}/$name');
                final written = await target.readAsBytes();
                final hash = sha256.convert(original).toString(),
                    copied = sha256.convert(written).toString();
                if (hash != copied || original.length != written.length) {
                  throw StateError('Fixture archive verification failed');
                }
                hashes[item.path.substring(root.path.length + 1)] = {
                  'bytes': original.length,
                  'sha256': hash,
                  'verified_archive_sha256': copied,
                };
              } else {
                throw StateError('Unexpected fixture artifact');
              }
            }
          }

          await copy(root, destination);
          await File(
            '${destination.path}/archive-verification.json',
          ).writeAsString(jsonEncode(hashes), flush: true);
        }
        await _dir!.delete(recursive: true);
      }
      _dir = null;
    }

    final tester = _tester;
    _tester = null;
    if (tester != null) {
      await tester.runAsync(closeOwned);
    } else {
      await closeOwned();
    }
  }
}

const syncOnPrefs = <String, Object>{};
Future<Object> signedInAuth(WidgetTester tester) async => Object();

/// Synthetic fixture builder over the production store. It executes each legacy
/// seed statement against a temporary table, then publishes revisioned records.
/// Runtime mutations must use the production repositories, never this adapter.
class FixtureDatabase extends RealZoneDatabase {
  FixtureDatabase(this.store) : super(store, Zone.current);
  final LocalStore store;
  static Future<FixtureDatabase> open(Directory root) async {
    final profile = await AlkionProfile.open(
      supportRoot: Directory('${root.path}/dev.animusstudio.alkion.dev'),
    );
    return FixtureDatabase(
      await LocalStore.open(
        profile: profile,
        expectedProfileId: profile.profileId,
        schema: prescriptionSchemaRegistry(),
      ),
    );
  }

  Future<void> initialize() async {}
  Future<T> writeLock<T>(Future<T> Function(LocalTransaction) body) =>
      writeTransaction(body);
  Future<void> close() => store.close();
  Future<void> execute(
    String sql, [
    List<Object?> args = const [],
  ]) => writeTransaction((tx) async {
    final match = RegExp(
      r'^(?:INSERT(?: OR REPLACE)? INTO|UPDATE|DELETE FROM)\s+(\w+)',
      caseSensitive: false,
    ).firstMatch(sql.trim());
    if (match == null) {
      throw StateError('Unsupported synthetic fixture statement: $sql');
    }
    final table = match[1]!, index = domainTables.indexOf(table);
    if (index < 0) {
      throw StateError('Only synthetic domain seed statements are supported');
    }
    final name = 'fixture_$table';
    await tx.execute('CREATE TEMP TABLE $name AS SELECT * FROM $table');
    final insert = sql.trimLeft().startsWith('INSERT');
    if (insert) {
      await tx.execute('DELETE FROM $name');
    }
    await tx.execute(sql.replaceFirst(RegExp('\\b$table\\b'), name), args);
    final rows = await tx.getAll('SELECT * FROM $name');
    final prior = await tx.getAll('SELECT * FROM $table');
    for (final row in rows) {
      final ref = LocalRef(
        tx.profileId,
        RecordKind.values[index],
        row['id'] as String,
      );
      final fields = projectionFields(row);
      if (table == 'sets') {
        final ex = LocalRef(
          tx.profileId,
          RecordKind.exercise,
          row['exercise_id'] as String,
        );
        if (await tx.record(ex) == null) {
          await _putFixture(tx, ex, {
            'name': ex.id,
            'is_template': 0,
            'plate_step_kg': '2.50',
          });
        }
      }
      if (table == 'sessions' && row['day_template_id'] != null) {
        final day = LocalRef(
          tx.profileId,
          RecordKind.trainingDay,
          row['day_template_id'] as String,
        );
        if (await tx.record(day) == null) {
          fields['day_template_id'] = null;
        }
      }
      fields.removeWhere(
        (k, v) => v == null && {'ancestry_bytes', 'evidence_bytes'}.contains(k),
      );
      await _putFixture(tx, ref, fields, deleted: row['deleted'] == 1);
    }
    if (!insert) {
      final ids = rows.map((r) => r['id']).toSet();
      for (final row in prior.where((r) => !ids.contains(r['id']))) {
        await _putFixture(
          tx,
          LocalRef(tx.profileId, RecordKind.values[index], row['id'] as String),
          projectionFields(row),
          deleted: true,
        );
      }
    }
    await tx.execute('DROP TABLE $name');
  });
}

// ── Tester helpers ──────────────────────────────────────────────────────────

/// A phone of [width]×[height] logical px at 2× density with status/nav
/// insets, at the given system text scale.
void setPhone(
  WidgetTester tester, {
  required double width,
  double height = 915,
  double textScale = 1.0,
}) {
  tester.view.devicePixelRatio = 2;
  tester.view.physicalSize = Size(width * 2, height * 2);
  tester.view.padding = const FakeViewPadding(top: 64, bottom: 32);
  tester.view.viewPadding = const FakeViewPadding(top: 64, bottom: 32);
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
}

/// Pumps real-async ticks so isolate-backed database work lands.
Future<void> settleReal(WidgetTester tester, {int ticks = 30}) async {
  for (var i = 0; i < ticks; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 30)),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// Text or rich text under [within] that contains any of [needles].
Finder textWithAnyOf(Finder within, List<String> needles) => find.descendant(
  of: within,
  matching: find.byWidgetPredicate((w) {
    final text = switch (w) {
      Text(:final data?) => data,
      Text(:final textSpan?) => textSpan.toPlainText(),
      RichText(:final text) => text.toPlainText(),
      _ => null,
    };
    return text != null && needles.any(text.contains);
  }),
);

/// Pumps real-async ticks until [marker] is built (at most [maxTicks]), then
/// asserts it is: a layout check on a still-loading screen proves nothing.
Future<void> settleUntilFound(
  WidgetTester tester,
  Finder marker, {
  required String where,
  int maxTicks = 150,
}) async {
  for (var i = 0; i < maxTicks && marker.evaluate().isEmpty; i++) {
    await settleReal(tester, ticks: 1);
  }
  expect(marker, findsWidgets, reason: '$where: seeded content never rendered');
}

/// Taps the bottom-nav tab showing [icon] (locale-independent).
Future<void> openTab(WidgetTester tester, IconData icon) async {
  final index = {
    WIcons.home: 0,
    WIcons.chart: 1,
    WIcons.history: 2,
    WIcons.plan: 3,
    WIcons.user: 4,
  }[icon];
  if (index == null) throw ArgumentError.value(icon, 'icon');
  await tester.tap(
    find.descendant(
      of: find.byType(WTabBar),
      matching: find.byKey(ValueKey('destination-$index')),
    ),
  );
  await settleReal(tester, ticks: 10);
}

Finder verticalScrollableIn(Finder within) => find
    .descendant(
      of: within,
      matching: find.byWidgetPredicate(
        (w) =>
            w is Scrollable &&
            axisDirectionToAxis(w.axisDirection) == Axis.vertical,
      ),
    )
    .first;

/// Scrolls the vertical list under [within] until [target] is built, then
/// brings it on screen.
Future<void> scrollIntoView(
  WidgetTester tester,
  Finder within,
  Finder target,
) async {
  final position = tester
      .state<ScrollableState>(verticalScrollableIn(within))
      .position;
  for (
    var i = 0;
    i < 40 &&
        target.evaluate().isEmpty &&
        position.pixels < position.maxScrollExtent;
    i++
  ) {
    position.jumpTo(
      math.min(
        position.pixels + position.viewportDimension / 2,
        position.maxScrollExtent,
      ),
    );
    await settleReal(tester, ticks: 2);
  }
  expect(target, findsWidgets, reason: 'scrolled $within without finding it');
  await tester.ensureVisible(target.first);
  await settleReal(tester, ticks: 2);
}

/// No overflow or build exception so far, and no word split on screen.
void expectLayoutHolds(WidgetTester tester, String where) {
  final error = tester.takeException();
  if (error != null) {
    fail('$where: ${error.toString().split('\n').first}');
  }
  expectNoSplitWords(tester, where: where);
}

/// [expectLayoutHolds] at the top of the vertical list under [within] and at
/// every 80%-of-a-screen step to its end; leaves the list back at the top.
Future<void> expectLayoutHoldsWhileScrolling(
  WidgetTester tester,
  Finder within,
  String where,
) async {
  expectLayoutHolds(tester, where);
  final scrollable = verticalScrollableIn(within);
  if (scrollable.evaluate().isEmpty) {
    return;
  }
  final position = tester.state<ScrollableState>(scrollable).position;
  for (
    var step = 1;
    step <= 20 && position.pixels < position.maxScrollExtent;
    step++
  ) {
    position.jumpTo(
      math.min(
        position.pixels + position.viewportDimension * 0.8,
        position.maxScrollExtent,
      ),
    );
    await settleReal(tester, ticks: 3);
    expectLayoutHolds(tester, '$where, scrolled $step');
  }
  position.jumpTo(0);
  await settleReal(tester, ticks: 2);
}

// ── Seeds ───────────────────────────────────────────────────────────────────

Future<void> seedExercise(
  FixtureDatabase d,
  String id,
  String name, {
  String muscle = 'chest',
  bool compound = true,
}) {
  return d.execute(
    'INSERT INTO exercises (id, slug, name, muscle_group, equip, compound, '
    'base_weight_kg, plate_step_kg, default_rep_low, default_rep_high, '
    'default_warmup_sets, default_working_sets, default_rir_low, '
    'default_rir_high, created_by, is_template, created_at) '
    "VALUES (?, ?, ?, ?, 'barbell', ?, '20.00', '2.50', 6, 10, 1, 3, 1, 2, 'u1', 0, ?)",
    [
      id,
      '$id-slug',
      name,
      muscle,
      compound ? 1 : 0,
      DateTime.now().toUtc().toIso8601String(),
    ],
  );
}

Future<void> seedDay(
  FixtureDatabase d,
  String id,
  String name, {
  required int position,
  String focus = '',
  List<String> exerciseIds = const [],
  int? weekday,
}) async {
  await d.execute(
    'INSERT INTO day_templates (id, slug, name, notes, position, is_template, '
    "created_by, created_at, focus, scheduled_weekday) VALUES (?, ?, ?, '', ?, 0, 'u1', ?, ?, ?)",
    [
      id,
      '$id-slug',
      name,
      position,
      DateTime.now().toUtc().toIso8601String(),
      focus,
      weekday,
    ],
  );
  for (var p = 0; p < exerciseIds.length; p++) {
    await d.execute(
      'INSERT INTO day_template_items (id, day_template_id, exercise_id, position, '
      'target_warmup_sets, target_working_sets, target_rep_low, target_rep_high, '
      'target_rir_low, target_rir_high, is_template, created_by, created_at) '
      "VALUES (?, ?, ?, ?, 1, 3, 6, 10, 1, 2, 0, 'u1', ?)",
      [
        '$id-i$p',
        id,
        exerciseIds[p],
        p,
        DateTime.now().toUtc().toIso8601String(),
      ],
    );
  }
}

/// One finished session; [sets] = (exerciseId, kg, reps, rir, warmup).
Future<void> seedSession(
  FixtureDatabase d,
  String id, {
  required DateTime date,
  required String label,
  String? dayId,
  int durationMin = 62,
  required List<(String, double, int, int?, bool)> sets,
}) async {
  await d.execute(
    'INSERT INTO sessions (id, user_id, date, split_label, notes, day_template_id, '
    "created_at, duration_min) VALUES (?, 'u1', ?, ?, '', ?, ?, ?)",
    [
      id,
      isoDate(date),
      label,
      dayId,
      date.toUtc().toIso8601String(),
      durationMin,
    ],
  );
  final top = <String, int>{};
  for (var i = 0; i < sets.length; i++) {
    final s = sets[i];
    if (s.$5) {
      continue;
    }
    final cur = top[s.$1];
    if (cur == null || sets[cur].$2 < s.$2) {
      top[s.$1] = i;
    }
  }
  for (var i = 0; i < sets.length; i++) {
    final s = sets[i];
    await d.execute(
      'INSERT INTO sets (id, session_id, exercise_id, user_id, set_number, weight_kg, '
      "reps, rir, is_warmup, is_top_set, is_pr, created_at, updated_at) VALUES (?, ?, ?, 'u1', ?, ?, ?, ?, ?, ?, 0, ?, ?)",
      [
        '$id-s$i',
        id,
        s.$1,
        i + 1,
        s.$2.toStringAsFixed(2),
        s.$3,
        s.$4,
        s.$5 ? 1 : 0,
        top[s.$1] == i ? 1 : 0,
        date.toUtc().toIso8601String(),
        date.toUtc().toIso8601String(),
      ],
    );
  }
}

Future<void> seedBodyweight(
  FixtureDatabase d,
  DateTime date,
  double kg,
) => d.execute(
  "INSERT INTO bodyweight_logs (id, user_id, date, weight_kg, created_at) VALUES (?, 'u1', ?, ?, ?)",
  [
    'bw-${isoDate(date)}',
    isoDate(date),
    kg.toStringAsFixed(2),
    date.toUtc().toIso8601String(),
  ],
);

/// Long exercise and day names, four sessions (one with a PR) and twelve
/// bodyweight entries over the last weeks.
Future<void> seedLong(FixtureDatabase d) async {
  await seedExercise(
    d,
    'ex1',
    longExercise,
    muscle: 'shoulders',
    compound: false,
  );
  await seedExercise(d, 'ex2', longExercise2, muscle: 'chest');
  await seedExercise(d, 'ex3', 'Bench Press', muscle: 'chest');
  await seedExercise(d, 'ex4', 'Brand New Movement', muscle: 'back');
  await seedDay(
    d,
    'd1',
    longDay,
    position: 0,
    focus: longFocus,
    exerciseIds: ['ex1', 'ex2', 'ex3', 'ex4'],
  );
  await seedDay(
    d,
    'd2',
    'Pull',
    position: 1,
    focus: 'Back',
    exerciseIds: ['ex3'],
  );
  await seedDay(d, 'd3', unscheduledLongDay, position: 2, exerciseIds: ['ex2']);
  final now = DateTime.now();
  for (var w = 0; w < 4; w++) {
    await seedSession(
      d,
      's$w',
      date: now.subtract(Duration(days: 2 + w * 3)),
      label: w.isEven ? longDay : 'Pull',
      dayId: w.isEven ? 'd1' : 'd2',
      durationMin: 71,
      sets: [
        ('ex1', 12.5, 12, null, true),
        ('ex1', 17.5 + w, 10, 1, false),
        ('ex1', 17.5 + w, 9, 1, false),
        ('ex2', 42.5 - w, 8, 2, false),
        ('ex2', 42.5 - w, 7, 1, false),
        ('ex3', 102.5 - w * 2.5, 5, 0, false),
      ],
    );
  }
  await d.execute(
    "UPDATE sets SET is_pr = 1 WHERE session_id = 's0' AND is_top_set = 1",
  );
  for (var i = 0; i < 12; i++) {
    await seedBodyweight(
      d,
      now.subtract(Duration(days: i * 2)),
      82.4 - i * 0.3,
    );
  }
}

/// A live workout with the long names: a started block, a collapsed one and
/// a brand-new exercise.
SessionDraft longDraft() {
  Exercise ex(String id, String name, {bool compound = true}) => Exercise(
    id: id,
    name: name,
    slug: id,
    muscleGroup: 'chest',
    compound: compound,
    plateStepKg: 2.5,
    isTemplate: false,
  );
  SetState setOf(
    String id,
    double kg,
    int reps, {
    bool warm = false,
    bool done = false,
  }) => SetState(
    id: id,
    weightKg: kg,
    reps: reps,
    rir: warm ? null : 1,
    isWarmup: warm,
    done: done,
  );
  BlockState block(
    Exercise e, {
    required List<SetState> warm,
    required List<SetState> work,
    bool expanded = true,
  }) => BlockState(
    exercise: e,
    resolved: ResolvedSlot(
      exercise: e,
      workSets: work.length,
      warmupSets: warm.length,
      repLow: 8,
      repHigh: 12,
      rirLow: 1,
      rirHigh: 2,
    ),
    warmupSets: warm,
    workingSets: work,
    expanded: expanded,
    lastTop: (
      weight: 17.5,
      reps: 10,
      date: isoDate(DateTime.now().subtract(const Duration(days: 2))),
    ),
    bestKg: 17.5,
  );
  return SessionDraft(
    templateId: 'd1',
    name: longDay,
    focus: longFocus,
    startedAt: DateTime.now().subtract(const Duration(minutes: 23)),
    blocks: [
      block(
        ex('ex1', longExercise, compound: false),
        warm: [setOf('w1', 7.5, 12, warm: true, done: true)],
        work: [
          setOf('l1', 17.5, 10, done: true),
          setOf('l2', 17.5, 9),
          setOf('l3', 17.5, 8),
        ],
      ),
      block(
        ex('ex2', longExercise2),
        warm: [],
        work: [setOf('k1', 42.5, 8), setOf('k2', 42.5, 8)],
        expanded: false,
      ),
      block(
        ex('ex4', 'Brand New Movement'),
        warm: [],
        work: [setOf('n1', 20, 10), setOf('n2', 20, 10)],
      ),
    ],
  );
}

/// Flutter fake timers must not own production SQLite queue/watch lifetimes.
/// Every operation, callback and subscription still executes the actual store.
class RealZoneDatabase implements LocalDatabase {
  RealZoneDatabase(this.database, this.zone);
  final LocalDatabase database;
  final Zone zone;
  @override
  String get profileId => database.profileId;
  @override
  StoreToken get token => database.token;
  @override
  Future<LocalActionResult> apply(
    LocalAction action,
    Future<Object?> Function(LocalTransaction) mutate, {
    StoreToken? expected,
  }) => zone.run(() => database.apply(action, mutate, expected: expected));
  @override
  Future<List<Map<String, dynamic>>> getAll(
    String sql, [
    List<Object?> parameters = const [],
  ]) => zone.run(() => database.getAll(sql, parameters));
  @override
  Future<Map<String, dynamic>> get(
    String sql, [
    List<Object?> parameters = const [],
  ]) => zone.run(() => database.get(sql, parameters));
  @override
  Future<Map<String, dynamic>?> getOptional(
    String sql, [
    List<Object?> parameters = const [],
  ]) => zone.run(() => database.getOptional(sql, parameters));
  @override
  Future<T> readTransaction<T>(
    Future<T> Function(LocalRead) callback, {
    StoreToken? expected,
  }) => zone.run(() => database.readTransaction(callback, expected: expected));
  @override
  Future<T> writeTransaction<T>(
    Future<T> Function(LocalTransaction) callback, {
    StoreToken? expected,
  }) => zone.run(() => database.writeTransaction(callback, expected: expected));
  @override
  Stream<List<Map<String, dynamic>>> watch(
    String sql, {
    List<Object?> parameters = const [],
  }) => Stream.multi((controller) {
    final subscription = zone.run(
      () => database
          .watch(sql, parameters: parameters)
          .listen(
            controller.add,
            onError: controller.addError,
            onDone: controller.close,
          ),
    );
    controller.onCancel = () => zone.run(subscription.cancel);
  });
}

/// Seed snapshots are synthetic source-selection revisions, never authored
/// user commands. The production authored-action admission remains enforced.
Future<void> _putFixture(
  LocalTransaction tx,
  LocalRef ref,
  Map<String, Object?> fields, {
  bool deleted = false,
}) async {
  final revision = await tx.writeRevision(
    ref,
    localBytes(fields),
    deleted: deleted,
    layer: 'sourceSelection',
  );
  await tx.putRecord(ref, revision, fields, deleted: deleted);
}
