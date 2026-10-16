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
import 'package:alkion/domain/local_action.dart';
import 'package:alkion/identity/alkion_profile.dart';
import 'package:alkion/store/local_store.dart';
import 'package:alkion/store/schema.dart';
import 'package:alkion/data/exercise_repository.dart';
import 'package:alkion/data/day_template_repository.dart';
import 'package:alkion/l10n/app_localizations.dart';
import 'package:alkion/session/session_manager.dart';
import 'package:alkion/settings/settings_service.dart';
import 'package:alkion/units/unit_service.dart';
import 'package:alkion/theme/app_theme.dart';
import 'package:alkion/theme/tokens.dart';
import 'package:alkion/shell/w_tab_bar.dart';
import '../../support/app_fonts.dart';
import '../../support/layout_expect.dart';

const longExercise =
    'Single-Arm Cable Lateral Raise with Wrist Strap (Behind Back)';
const longExercise2 =
    'Kurzhantel-Schrägbankdrücken mit neutralem Griff und Pause';
const longDay = 'Oberkörper Schwerpunkt Brust & Schultern';
const longFocus = 'Brust · Schultern · Trizeps · Vorderer Delta';

class ScreenHarness {
  Directory? _dir;
  WidgetTester? _tester;
  late Zone _ownerZone;
  LocalDatabase get localDatabase =>
      RealZoneDatabase(overrideDatabase ?? database, _ownerZone);
  LocalStore? _store;
  LocalStore get database => _store!;
  late UnitService units;
  late SettingsService settings;
  final SessionManager manager = SessionManager();
  LocalDatabase? overrideDatabase;
  Future<void> open(
    WidgetTester tester, {
    Map<String, Object> prefs = const {},
    Future<void> Function(LocalStore) seed = seedLong,
  }) async {
    _tester = tester;
    await tester.runAsync(() async {
      _ownerZone = Zone.current;
      final dir = await Directory.systemTemp.createTemp('alkion-domains');
      _dir = dir;
      final profile = await AlkionProfile.open(
        supportRoot: Directory('${dir.path}/dev.animusstudio.alkion.dev'),
      );
      _store = await LocalStore.open(
        profile: profile,
        expectedProfileId: profile.profileId,
        schema: domainSchemaRegistry(),
      );
      await seed(database);
      units = UnitService.local(localDatabase);
      settings = SettingsService.local(localDatabase);
      await units.load();
      await settings.load();
      if (prefs['unit'] == 'lb') {
        units.setUnit(Unit.lb);
        await units.flushPersistence();
      }
      await initializeDateFormatting();
      await preloadAppFonts();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (call) async => dir.path,
          );
    });
  }

  Widget wrap(
    Widget home, {
    Locale locale = const Locale('en'),
    List<SingleChildWidget> extra = const [],
  }) => MultiProvider(
    providers: [
      Provider<LocalDatabase>.value(value: localDatabase),
      Provider<DomainRecovery>.value(
        value: DomainRecovery(() => _ownerZone.run(database.recover)),
      ),
      ChangeNotifierProvider<UnitService>.value(value: units),
      ChangeNotifierProvider<SettingsService>.value(value: settings),
      ChangeNotifierProvider<SessionManager>.value(value: manager),
      ...extra,
    ],
    child: MaterialApp(
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
    await settleReal(tester, ticks: 3);
  }

  Future<void> close() async {
    final tester = _tester;
    _tester = null;
    if (tester != null) {
      await tester.runAsync(_closeStore);
    } else {
      await _closeStore();
    }
  }

  Future<void> _closeStore() async {
    final store = _store;
    _store = null;
    await store?.close();
    final dir = _dir;
    _dir = null;
    if (dir != null) {
      final archive = Platform.environment['ALKION_FIXTURE_ARCHIVE'];
      if (archive != null) {
        if (!dir.path.startsWith(
          '${Directory.systemTemp.path}/alkion-domains',
        )) {
          throw StateError('Unowned fixture directory');
        }
        final destination = Directory(
          '$archive/${dir.uri.pathSegments.where((s) => s.isNotEmpty).last}',
        );
        if (await destination.exists()) {
          throw StateError('Fixture archive already exists');
        }
        final hashes = <String, Object?>{};
        Future<void> copy(Directory from, Directory to) async {
          await to.create(recursive: true);
          await for (final item in from.list(followLinks: false)) {
            final name = item.uri.pathSegments.where((s) => s.isNotEmpty).last;
            if (item is Directory) {
              await copy(item, Directory('${to.path}/$name'));
            } else if (item is File) {
              final original = await item.readAsBytes();
              final target = await item.copy('${to.path}/$name');
              final written = await target.readAsBytes();
              final hash = sha256.convert(original).toString();
              final copied = sha256.convert(written).toString();
              if (hash != copied || original.length != written.length) {
                throw StateError('Fixture archive verification failed');
              }
              hashes[item.path.substring(dir.path.length + 1)] = {
                'bytes': original.length,
                'sha256': hash,
                'verified_archive_sha256': copied,
              };
            } else {
              throw StateError('Unexpected fixture artifact');
            }
          }
        }

        await copy(dir, destination);
        await File(
          '${destination.path}/archive-verification.json',
        ).writeAsString(jsonEncode(hashes), flush: true);
      }
      await dir.delete(recursive: true);
    }
  }
}

Future<LocalStore> openDomainStore(Directory root) async {
  final profile = await AlkionProfile.open(
    supportRoot: Directory('${root.path}/dev.animusstudio.alkion.dev'),
  );
  return LocalStore.open(
    profile: profile,
    expectedProfileId: profile.profileId,
    schema: domainSchemaRegistry(),
  );
}

Future<void> seedExercise(
  LocalDatabase db,
  String id,
  String name, {
  String muscle = 'chest',
  bool compound = true,
  String base = '20.00',
}) async {
  final intent = prepareDomain(
    db,
    RecordKind.exercise,
    LocalActionKind.definitionCreate,
    id,
    0,
    {
      'fields': {
        'name': name,
        'muscle_group': muscle,
        'equip': 'barbell',
        'compound': compound ? 1 : 0,
        'base_weight_kg': base,
        'plate_step_kg': '2.50',
        'default_rep_low': 6,
        'default_rep_high': 10,
        'default_warmup_sets': 1,
        'default_working_sets': 3,
        'default_rir_low': 1,
        'default_rir_high': 2,
      },
    },
  );
  await ExerciseRepository.local(db).commitPrepared(intent);
}

Future<void> seedDay(
  LocalDatabase db,
  String id,
  String name, {
  required int position,
  String focus = '',
  List<String> exerciseIds = const [],
  int? weekday,
}) async {
  final intent = prepareDomain(
    db,
    RecordKind.trainingDay,
    LocalActionKind.planCreate,
    id,
    0,
    {
      'fields': {'name': name, 'focus': focus, 'scheduled_weekday': weekday},
      'slots': [
        for (var i = 0; i < exerciseIds.length; i++)
          {
            'id': '$id-i$i',
            'base': 0,
            'position': i + 1,
            'fields': {
              'exercise_id': exerciseIds[i],
              'target_warmup_sets': 1,
              'target_working_sets': 3,
              'target_rep_low': 6,
              'target_rep_high': 10,
              'target_rir_low': 1,
              'target_rir_high': 2,
            },
          },
      ],
    },
  );
  await DayTemplateRepository.local(db).commitPrepared(intent);
}

Future<void> seedLong(LocalStore db) async {
  await seedExercise(
    db,
    'ex1',
    longExercise,
    muscle: 'shoulders',
    compound: false,
  );
  await seedExercise(db, 'ex2', longExercise2);
  await seedExercise(db, 'ex3', 'Bench Press');
  await seedExercise(db, 'ex4', 'Brand New Movement', muscle: 'back');
  await seedDay(
    db,
    'd1',
    longDay,
    position: 1,
    focus: longFocus,
    exerciseIds: ['ex1', 'ex2', 'ex3', 'ex4'],
  );
  await seedDay(
    db,
    'd2',
    'Pull',
    position: 2,
    focus: 'Back',
    exerciseIds: ['ex3'],
  );
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
  await tester.tap(
    find.descendant(of: find.byType(WTabBar), matching: find.byIcon(icon)),
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
  if (error != null) fail('$where: ${error.toString().split('\n').first}');
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
  if (scrollable.evaluate().isEmpty) return;
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
