import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:alkion/catalog/catalog.dart';
import 'package:alkion/catalog/catalog_development.dart';
import 'package:alkion/catalog_ui/catalog_picker.dart';
import 'package:alkion/catalog_ui/catalog_trial_scope.dart';
import 'package:alkion/data/active_session_draft.dart';
import 'package:alkion/data/day_template_repository.dart';
import 'package:alkion/data/exercise_repository.dart';
import 'package:alkion/data/session_repository.dart';
import 'package:alkion/data/models.dart';
import 'package:alkion/main.dart';
import 'package:alkion/session/active_session_controller.dart';
import 'package:alkion/session/session_summary_screen.dart';
import 'package:alkion/shell/session_launcher.dart';
import 'package:alkion/ui/catalog_history_editor.dart';
import 'package:alkion/ui/history_screen.dart';
import 'package:alkion/ui/day_editor.dart';
import 'package:alkion/widgets/stepper.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

import '../catalog/catalog_fixture.dart';
import '../support/app_fonts.dart';
import '../support/screen_harness.dart'
    show RealZoneDatabase, setPhone, settleReal;
import '../alkion/domains/prepared_intent_retry_test.dart' show FaultDatabase;

void main() {
  setUpAll(preloadAppFonts);
  for (final width in [412.0, 320.0]) {
    testWidgets(
      'normal app picker to typed finish and History correction at ${width}dp',
      (tester) async {
        setPhone(tester, width: width, textScale: width == 320 ? 2 : 1);
        late Directory temporary;
        late AlkionRuntime runtime;
        late RealZoneDatabase database;
        late ActiveSessionController controller;
        await tester.runAsync(() async {
          await initializeDateFormatting();
          temporary = await Directory.systemTemp.createTemp(
            'alkion-normal-ui-',
          );
          runtime = await AlkionRuntime.open(
            Directory('${temporary.path}/dev.animusstudio.alkion.dev'),
            catalogBundle: CatalogBundle.fromJsonString(
              jsonEncode(syntheticCatalog()),
            ),
          );
          database = RealZoneDatabase(runtime.store, Zone.current);
          final drafts = DraftStore.local(database);
          await drafts.load();
          controller = ActiveSessionController(draftStore: drafts)
            ..seedEmpty(name: 'Native catalog journey', focus: '');
          runtime.sessions.register(controller);
        });
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.runAsync(() async {
            await runtime.close();
            await temporary.delete(recursive: true);
          });
        });
        Future<void> tap(Finder finder) async {
          await tester.ensureVisible(finder);
          await Scrollable.ensureVisible(tester.element(finder), alignment: .2);
          await tester.pump();
          await tester.runAsync(() => tester.tap(finder));
          await tester.pump();
          await settleReal(tester, ticks: 10);
        }

        await tester.pumpWidget(
          AlkionApp(runtime: runtime, databaseOverride: database),
        );
        await settleReal(tester, ticks: 5);
        unawaited(
          openActiveSession(appNavigatorKey.currentContext!, runtime.sessions),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));
        await tap(find.text('Add exercise'));
        expect(find.byType(CatalogPicker), findsOneWidget);
        final variant = runtime.catalog!.bundle.variants.values.firstWhere(
          (v) => v.measurementProfileKey == 'duration_distance_optional',
        );
        await tester.enterText(
          find.byKey(const Key('catalog-search')),
          runtime.catalog!.index('en').variantLabel(variant.id),
        );
        await tester.pump();
        await tap(find.byKey(ValueKey('variant:${variant.id}@default')));
        expect(
          controller.draft.blocks.single.workingSets.single.catalog,
          isNotNull,
        );
        await tester.enterText(
          find.byKey(const Key('metric-duration')),
          width == 320 ? '65,000000000000000001' : '65.000000000000000001',
        );
        await tester.pump();
        await tap(find.byKey(const Key('catalog-log-set')));
        expect(controller.canFinish, isTrue);
        await tap(find.text('Finish workout'));
        expect(find.byType(SessionSummaryScreen), findsOneWidget);
        expect(find.textContaining('65.000000000000000001'), findsWidgets);
        final id = runtime.sessions.lastFinished!.sessionId;
        expect(tester.takeException(), isNull);
        if (width == 412) {
          late SessionRepository failing;
          late FaultDatabase fault;
          late ExerciseBlockData block;
          await tester.runAsync(() async {
            fault = FaultDatabase(runtime.store, afterCommit: true);
            failing = SessionRepository.local(
              RealZoneDatabase(fault, database.zone),
            );
            block = failing
                .groupIntoBlocks(await failing.setsForSession(id))
                .single;
          });
          unawaited(
            showModalBottomSheet<void>(
              context: appNavigatorKey.currentContext!,
              isScrollControlled: true,
              isDismissible: false,
              enableDrag: false,
              builder: (_) => CatalogHistoryEditor(
                sessionId: id,
                block: block,
                repository: failing,
              ),
            ),
          );
          await tester.pump();
          await settleReal(tester, ticks: 10);
          await tester.enterText(
            find.byKey(const Key('metric-duration')),
            '75.000000000000000003',
          );
          await tester.pump();
          await tap(find.text('Save changes'));
          expect(find.text("Couldn't save"), findsOneWidget);
          await tap(find.text('OK'));
          expect(
            tester
                .widget<TextField>(find.byKey(const Key('metric-duration')))
                .enabled,
            isFalse,
          );
          final editor = find.byType(CatalogHistoryEditor);
          final add = find.descendant(
            of: editor,
            matching: find.text('Add set'),
          );
          expect(
            tester
                .widget<TextButton>(
                  find
                      .ancestor(
                        of: add,
                        matching: find.byWidgetPredicate(
                          (widget) => widget is TextButton,
                        ),
                      )
                      .first,
                )
                .onPressed,
            isNull,
          );
          expect(
            find
                .descendant(of: editor, matching: find.byType(IconButton))
                .evaluate()
                .every(
                  (element) => (element.widget as IconButton).onPressed == null,
                ),
            isTrue,
          );
          await appNavigatorKey.currentState!.maybePop();
          await tester.pump();
          expect(find.byType(CatalogHistoryEditor), findsOneWidget);
          await tap(find.text('Save changes'));
          expect(fault.actions, hasLength(2));
          expect(
            fault.actions.map((action) => base64Encode(action.bytes)).toSet(),
            hasLength(1),
          );
          await tester.runAsync(() async {
            final rows = await SessionRepository.local(
              database,
            ).setsForSession(id);
            expect(
              rows.single.catalog!.metrics['duration']!.raw,
              '75.000000000000000003',
            );
          });
        }
        await tester.scrollUntilVisible(
          find.text('Done'),
          250,
          scrollable: find.byType(Scrollable).first,
        );
        await tap(find.text('Done'));
        await tap(find.byKey(const ValueKey('destination-2')));
        final card = find.byType(SessionCard);
        if (card.evaluate().isEmpty) {
          await tester.scrollUntilVisible(
            card,
            250,
            scrollable: find.byType(Scrollable).first,
          );
        }
        await tap(find.text('Native catalog journey').last);
        final name = runtime.catalog!.index('en').variantLabel(variant.id);
        await tap(find.text(name).last);
        expect(find.byType(CatalogHistoryEditor), findsOneWidget);
        await tester.enterText(
          find.byKey(const Key('metric-duration')),
          '70.000000000000000009',
        );
        await tester.pump();
        await tap(find.text('Save changes'));
        await tester.runAsync(() async {
          final rows = await SessionRepository.local(
            database,
          ).setsForSession(id);
          expect(
            rows.single.catalog!.metrics['duration']!.raw,
            '70.000000000000000009',
          );
          expect(rows.single.catalog!.metrics.containsKey('distance'), isFalse);
          final raw = await runtime.store.get(
            'SELECT weight_kg,reps FROM sets WHERE id=?',
            [rows.single.id],
          );
          expect(raw['weight_kg'], isNull);
          expect(raw['reps'], isNull);
        });
        expect(tester.takeException(), isNull);
        if (width == 412) {
          late String dayId;
          await tester.runAsync(() async {
            final choice = CatalogChoice.variant(variant.id),
                catalog = runtime.catalog!;
            final selection = catalog.selectionFor(choice)!;
            final days = DayTemplateRepository.local(database);
            final intent = days.prepareDay(
              DayDraft(
                name: 'Typed count plan',
                slots: [
                  SlotDraft(
                    exerciseId: selection.exerciseId,
                    workSets: 1,
                    warmupSets: 0,
                    catalog: selection,
                  ),
                ],
              ),
              dependencies: catalog.dependenciesFor(choice),
            );
            await days.commitPrepared(intent);
            dayId = intent.action.target.id;
          });
          unawaited(
            appNavigatorKey.currentState!.push(
              MaterialPageRoute<void>(
                builder: (routeContext) => Scaffold(
                  body: DayEditor(
                    id: dayId,
                    onBack: () => Navigator.pop(routeContext),
                  ),
                ),
              ),
            ),
          );
          await tester.pump();
          await settleReal(tester, ticks: 10);
          final working = find.byWidgetPredicate(
            (widget) =>
                widget is WStepper && widget.semanticLabel == 'Working sets',
          );
          final warmups = find.byWidgetPredicate(
            (widget) => widget is WStepper && widget.semanticLabel == 'Warmups',
          );
          await tap(
            find.descendant(
              of: working,
              matching: find.byKey(const Key('stepper-inc')),
            ),
          );
          await tap(
            find.descendant(
              of: working,
              matching: find.byKey(const Key('stepper-inc')),
            ),
          );
          await tap(
            find.descendant(
              of: warmups,
              matching: find.byKey(const Key('stepper-inc')),
            ),
          );
          await tester.enterText(
            find.byKey(const Key('metric-duration')),
            '25.000000000000000001',
          );
          await tester.pump();
          await tap(find.text('Save changes'));
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.runAsync(() async {
            final support = runtime.supportRoot;
            await runtime.close();
            runtime = await AlkionRuntime.open(
              support,
              catalogLoader: () async => const CatalogDevelopmentInput(),
            );
            final day = (await DayTemplateRepository.local(
              runtime.store,
            ).byId(dayId))!;
            expect(day.slots.single.workSets, 3);
            expect(day.slots.single.warmupSets, 1);
            expect(
              day.slots.single.catalogTargets['duration']!.raw,
              '25.000000000000000001',
            );
            final cold = ActiveSessionController();
            await cold.buildFromTemplate(
              day,
              exerciseRepo: ExerciseRepository.local(runtime.store),
              sessionRepo: SessionRepository.local(runtime.store),
            );
            expect(cold.draft.blocks.single.workingSets, hasLength(3));
            expect(cold.draft.blocks.single.warmupSets, hasLength(1));
            expect(
              cold.originSlotIdFor(cold.draft.blocks.single),
              day.slots.single.id,
            );
            cold.dispose();
          });
        }
      },
    );
  }
}
