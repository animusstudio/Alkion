import 'dart:convert';

import 'package:alkion/catalog/catalog.dart';
import 'package:alkion/catalog_ui/catalog_scope.dart';
import '../support/memory_catalog_state.dart';
import 'package:alkion/catalog_ui/catalog_picker.dart';
import 'package:alkion/data/day_template_repository.dart';
import 'package:alkion/data/exercise_repository.dart';
import 'package:alkion/data/models.dart';
import 'package:alkion/ui/day_editor.dart';
import 'package:alkion/ui/exercise_library_tab.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../catalog/catalog_fixture.dart';
import '../support/screen_harness.dart';

void main() {
  testWidgets(
    'query changes preserve canonical execution names across downstream surfaces',
    (tester) async {
      final h = ScreenHarness();
      await h.open(tester, seed: (_) async {});
      addTearDown(h.close);
      final source = syntheticCatalog();
      final seated = source['variants'][5];
      source['aliases'].add({
        'id': 'synthetic-seated-familiar',
        'text': 'Lento avanti',
        'locale': 'it',
        'target': {'kind': 'variant', 'id': seated['id']},
      });
      final state = MemoryCatalogState(
        CatalogBundle.fromJsonString(jsonEncode(source)),
      );
      addTearDown(state.dispose);
      final standing = CatalogChoice.variant(source['variants'][4]['id']);
      final sitting = CatalogChoice.variant(seated['id']);
      final setup = state.newSetup(standing, 'La mia macchina 💪');
      for (final query in [
        'Lento avanti',
        'RDL',
        'Shoulder press',
        'standing',
      ]) {
        state.remember(standing, locale: 'it', query: query);
        expect(
          state.label(standing, 'it', query: query),
          'Distensioni in piedi con bilanciere',
        );
        expect(
          state.identifyingLabel(standing, 'it'),
          'Distensioni in piedi con bilanciere',
        );
        expect(
          state.identifyingLabel(sitting, 'it'),
          'Distensioni sedute con manubri',
        );
      }
      expect(state.label(setup, 'it'), 'Distensioni in piedi con bilanciere');
      expect(state.distinction(setup, 'it'), 'La mia macchina 💪');
      final custom = CatalogChoice.custom('Il mio nome esatto 💪', 'load_reps');
      for (final locale in ['en', 'it', 'de', 'es']) {
        expect(state.identifyingLabel(custom, locale), 'Il mio nome esatto 💪');
      }
      late DayTemplate day;
      await tester.runAsync(() async {
        final repo = ExerciseRepository.local(h.database);
        final first = await state.materialize(standing, repo, locale: 'it');
        final second = await state.materialize(sitting, repo, locale: 'it');
        final same = await state.materialize(setup, repo, locale: 'en');
        expect(same.id, first.id);
        expect(first.name, 'Distensioni in piedi con bilanciere');
        expect(second.name, 'Distensioni sedute con manubri');
        expect((await repo.all()).length, 2);
        final days = DayTemplateRepository.local(h.database);
        await days.saveDay(
          draft: DayDraft(
            name: 'Synthetic names',
            slots: [
              SlotDraft(exerciseId: first.id),
              SlotDraft(exerciseId: second.id),
            ],
          ),
        );
        day = (await days.allDays()).single;
      });
      for (final route in ['library', 'day']) {
        await tester.pumpWidget(
          CatalogScope(
            state: state,
            child: h.wrap(
              Scaffold(
                body: route == 'library'
                    ? LibraryTab(onOpenEditor: (_) {})
                    : DayEditor(id: day.id, onBack: () {}),
              ),
              locale: const Locale('it'),
            ),
          ),
        );
        await settleReal(tester, ticks: 8);
        if (route == 'library') {
          final family = find.byKey(
            ValueKey(
              'catalog-navigation-family-${source['families'][1]['id']}',
            ),
          );
          await tester.scrollUntilVisible(
            family,
            120,
            scrollable: find
                .descendant(
                  of: find.byType(CatalogBrowser),
                  matching: find.byType(Scrollable),
                )
                .first,
          );
          await tester.tap(family);
          await settleReal(tester, ticks: 4);
        }
        if (route == 'library') {
          expect(
            find.text('Distensioni in piedi con bilanciere'),
            findsOneWidget,
          );
          expect(find.text('Distensioni sedute con manubri'), findsOneWidget);
          expect(find.text('Bilanciere'), findsOneWidget);
          expect(find.text('Manubri'), findsOneWidget);
        } else {
          expect(
            find.text('Distensioni in piedi con bilanciere'),
            findsWidgets,
          );
          expect(find.text('Distensioni sedute con manubri'), findsWidgets);
        }
        expect(tester.takeException(), isNull);
        await h.unmount(tester);
      }
    },
  );
}
