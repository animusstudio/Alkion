import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/store/local_store.dart';
import 'package:alkion/data/exercise_repository.dart';
import '../alkion/domains/local_screen_harness.dart'
    show openDomainStore, RealZoneDatabase;
import 'package:provider/provider.dart';
import 'package:alkion/ui/add_weight_sheet.dart';
import 'package:alkion/units/unit_service.dart';
import 'package:alkion/util/dates.dart';
import 'package:alkion/theme/alkion_icon.dart';

import '../support/l10n_harness.dart';
import '../support/pump_until.dart';
import '../support/icon_finders.dart';

final _hint = find.byKey(const Key('bodyweight-range-hint'));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  late LocalStore database;
  late RealZoneDatabase realDatabase;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('reps-add-weight');
    database = await openDomainStore(dir);
    realDatabase = RealZoneDatabase(database, Zone.current);
  });

  tearDown(
    () => realDatabase.zone.run(() async {
      await database.close();
      await dir.delete(recursive: true);
    }),
  );

  Widget host() => wrapL10n(
    Builder(
      builder: (context) => ElevatedButton(
        onPressed: () => showAddWeightSheet(context),
        child: const Text('open'),
      ),
    ),
  );

  Widget wrapped({Unit unit = Unit.kg}) => MultiProvider(
    providers: [
      Provider<LocalDatabase>.value(value: realDatabase),
      Provider<DomainRecovery>.value(
        value: DomainRecovery(() => realDatabase.zone.run(database.recover)),
      ),
      ChangeNotifierProvider<UnitService>(
        create: (_) => unit == Unit.kg
            ? UnitService.local(realDatabase)
            // Display-only: the lb tests never persist the preference.
            : (UnitService()..setUnit(Unit.lb)),
      ),
    ],
    child: host(),
  );

  Future<void> cleanUp(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
  }

  /// Opens the sheet on an empty log and waits for the seed query to answer.
  Future<void> openEmpty(WidgetTester tester, {Unit unit = Unit.kg}) async {
    addTearDown(() => cleanUp(tester));
    await tester.pumpWidget(wrapped(unit: unit));
    await tester.pumpAndSettle();
    await tester.runAsync(() => tester.tap(find.text('open')));
    await tester.pumpAndSettle();
    // The hint shows once the (empty) seed query has answered.
    await pumpUntilFound(tester, _hint);
    await tester.pumpAndSettle();
  }

  Future<List<Map<String, dynamic>>> rows(WidgetTester tester) async =>
      (await tester.runAsync(
        () => database
            .getAll('SELECT weight_kg FROM bodyweight_logs')
            .timeout(const Duration(seconds: 5)),
      ))!;

  Future<void> waitClosed(WidgetTester tester) async {
    for (
      var i = 0;
      i < 100 && find.text('Save entry').evaluate().isNotEmpty;
      i++
    ) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 25)),
      );
      await tester.pump(const Duration(milliseconds: 25));
    }
    expect(find.text('Save entry'), findsNothing);
  }

  VoidCallback? saveAction(WidgetTester tester) => tester
      .widget<TextButton>(find.widgetWithText(TextButton, 'Save entry'))
      .onPressed;

  Future<void> typeValue(WidgetTester tester, String text) async {
    if (find.byType(TextField).evaluate().isEmpty) {
      await tester.tap(find.text('—'));
      await tester.pumpAndSettle();
    }
    await tester.enterText(find.byType(TextField), text);
    await tester.pump();
  }

  testWidgets(
    'a first entry starts empty with Save disabled, and Save writes nothing',
    (tester) async {
      await openEmpty(tester);
      expect(find.text('—'), findsOneWidget);
      expect(find.text('70.0'), findsNothing);
      expect(saveAction(tester), isNull);
      expect(find.text('Enter a weight from 20 to 500 kg'), findsOneWidget);
      await tester.runAsync(() => tester.tap(find.text('Save entry')));
      await tester.pumpAndSettle();
      expect(find.text('Save entry'), findsOneWidget);
      expect(await rows(tester), isEmpty);
    },
  );

  testWidgets('the sheet is titled for logging, with today\'s date', (
    tester,
  ) async {
    await openEmpty(tester);
    expect(find.text('Log bodyweight'), findsOneWidget);
    expect(find.text('Edit entry'), findsNothing);
    expect(find.text('Delete entry'), findsNothing);
    expect(
      find.text(fmtDate(isoDate(DateTime.now()), 'en', weekday: true)),
      findsOneWidget,
    );
  });

  testWidgets('tapping the empty number opens an empty field', (tester) async {
    await openEmpty(tester);
    await tester.tap(find.text('—'));
    await tester.pumpAndSettle();
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.controller!.text, isEmpty);
  });

  testWidgets('typing a value and submitting shows it', (tester) async {
    await openEmpty(tester);
    await typeValue(tester, '81.4');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(find.text('81.4'), findsOneWidget);
    expect(saveAction(tester), isNotNull);
    expect(_hint, findsNothing);
  });

  for (final reducedMotion in [false, true]) {
    testWidgets(
      reducedMotion
          ? 'reduced motion direct Save commits 81.4 before close'
          : 'tapping Save while a field is open persists the typed value',
      (tester) async {
        if (reducedMotion) {
          tester.platformDispatcher.accessibilityFeaturesTestValue =
              FakeAccessibilityFeatures(disableAnimations: true);
          addTearDown(
            tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
          );
        }
        // THE critical regression: nothing on Android unfocuses a TextField
        // from a tap outside it, and Save's own tap handler never requests
        // focus either — so without flushing the in-flight edit as the FIRST
        // statement of _save, the typed value would be lost. Save follows the
        // open field's text, so it is enabled while 81.4 is still typed.
        await openEmpty(tester);
        await typeValue(tester, '81.4');
        expect(saveAction(tester), isNotNull);

        await tester.runAsync(() => tester.tap(find.text('Save entry')));
        await tester.pump();
        await waitClosed(tester);
        final saved = await rows(tester);
        expect(saved, hasLength(1));
        expect(saved.single['weight_kg'], '81.40');
      },
    );
  }

  testWidgets(
    'tapping + while a differing edit is open builds on the typed value',
    (tester) async {
      // The ± buttons are always visible (unlike WStepper's, which hide behind
      // the field), so without committing the in-flight edit first, tapping +
      // silently discards it.
      await openEmpty(tester);
      await typeValue(tester, '81.4');

      await tester.tap(findGlyph(AlkionGlyph.add));
      await tester.pumpAndSettle();

      // kg mode steps by 0.1: one step above the TYPED 81.4.
      expect(find.text('81.5'), findsOneWidget);
    },
  );

  testWidgets('a minus sign is rejected as it is typed', (tester) async {
    await openEmpty(tester);
    await typeValue(tester, '-5');
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      isEmpty,
    );
    await typeValue(tester, '5');
    await typeValue(tester, '5-');
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      '5',
    );
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(saveAction(tester), isNull);
    expect(_hint, findsOneWidget);
  });

  for (final unit in Unit.values) {
    final lb = unit == Unit.lb;
    final rejected = lb
        ? ['0', '43.9', '1100.1', '99999']
        : ['0', '19.9', '500.1', '99999'];
    final accepted = lb ? ['44', '1100'] : ['20', '500'];
    final hint = lb
        ? 'Enter a weight from 44 to 1100 lb'
        : 'Enter a weight from 20 to 500 kg';
    testWidgets(
      'in ${unit.name}, zero, huge and out-of-range values cannot be saved',
      (tester) async {
        await openEmpty(tester, unit: unit);
        for (final text in rejected) {
          await typeValue(tester, text);
          expect(saveAction(tester), isNull, reason: text);
          expect(find.text(hint), findsOneWidget, reason: text);
          await tester.testTextInput.receiveAction(TextInputAction.done);
          await tester.pumpAndSettle();
          expect(saveAction(tester), isNull, reason: '$text committed');
          await tester.runAsync(() => tester.tap(find.text('Save entry')));
          await tester.pumpAndSettle();
          expect(await rows(tester), isEmpty, reason: text);
          await tester.tap(find.text(double.parse(text).toStringAsFixed(1)));
          await tester.pumpAndSettle();
        }
        for (final text in accepted) {
          await tester.enterText(find.byType(TextField), text);
          await tester.pump();
          expect(saveAction(tester), isNotNull, reason: text);
          expect(find.text(hint), findsNothing, reason: text);
        }
      },
    );
  }

  testWidgets('an in-range lb value saves in kg', (tester) async {
    await openEmpty(tester, unit: Unit.lb);
    await typeValue(tester, '150');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    await tester.runAsync(() => tester.tap(find.text('Save entry')));
    await tester.pump();
    await waitClosed(tester);
    expect((await rows(tester)).single['weight_kg'], '68.04');
    expect(UnitService.toKg(150, Unit.lb).toStringAsFixed(2), '68.04');
  });

  testWidgets('stepping from an out-of-range value lands inside the range', (
    tester,
  ) async {
    await openEmpty(tester);
    await typeValue(tester, '900');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    await tester.tap(findGlyph(AlkionGlyph.minus));
    await tester.pumpAndSettle();
    expect(find.text('500.0'), findsOneWidget);
    expect(saveAction(tester), isNotNull);
  });

  group('dismissing', () {
    Future<void> change(WidgetTester tester) async {
      await typeValue(tester, '81.4');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
    }

    Future<void> backPress(WidgetTester tester) async {
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
    }

    Future<void> scrim(WidgetTester tester) async {
      await tester.tapAt(const Offset(20, 20));
      await tester.pumpAndSettle();
    }

    Future<void> drag(WidgetTester tester) async {
      await tester.drag(find.text('Log bodyweight'), const Offset(0, 500));
      await tester.pumpAndSettle();
    }

    final paths = {'back': backPress, 'scrim': scrim, 'drag': drag};
    for (final MapEntry(key: name, value: dismiss) in paths.entries) {
      testWidgets('an unchanged sheet closes silently by $name', (
        tester,
      ) async {
        await openEmpty(tester);
        await dismiss(tester);
        expect(find.text('Discard changes?'), findsNothing);
        expect(find.text('Save entry'), findsNothing);
        expect(await rows(tester), isEmpty);
      });

      testWidgets(
        'a changed sheet asks before closing by $name; Keep editing returns',
        (tester) async {
          await openEmpty(tester);
          await change(tester);
          await dismiss(tester);
          expect(find.text('Discard changes?'), findsOneWidget);
          await tester.tap(find.text('Keep editing'));
          await tester.pumpAndSettle();
          expect(find.text('Discard changes?'), findsNothing);
          expect(find.text('81.4'), findsOneWidget);
          expect(find.text('Save entry'), findsOneWidget);

          await dismiss(tester);
          expect(find.text('Discard changes?'), findsOneWidget);
          await tester.tap(find.text('Discard'));
          await tester.pumpAndSettle();
          expect(find.text('Save entry'), findsNothing);
          expect(await rows(tester), isEmpty);
        },
      );
    }

    testWidgets('a typed but uncommitted value also asks first', (
      tester,
    ) async {
      await openEmpty(tester);
      await typeValue(tester, '81.4');
      await scrim(tester);
      expect(find.text('Discard changes?'), findsOneWidget);
      await tester.tap(find.text('Keep editing'));
      await tester.pumpAndSettle();
      expect(find.text('Save entry'), findsOneWidget);
    });
  });
}
