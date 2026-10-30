import 'dart:convert';

import 'package:alkion/catalog/catalog.dart';
import 'package:alkion/catalog_ui/catalog_trial_scope.dart';
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
    'query changes cannot rename shared familiar executions downstream',
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
      final state = CatalogTrialState(
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
        expect(state.label(standing, 'it', query: query), 'Lento avanti');
        expect(
          state.identifyingLabel(standing, 'it'),
          'Lento avanti · Bilanciere',
        );
        expect(state.identifyingLabel(sitting, 'it'), 'Lento avanti · Manubri');
      }
      expect(state.label(setup, 'it'), 'Lento avanti · Bilanciere');
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
        expect(first.name, 'Lento avanti · Bilanciere');
        expect(second.name, 'Lento avanti · Manubri');
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
          CatalogTrialScope(
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
        expect(
          find.text('Lento avanti · Bilanciere'),
          findsWidgets,
          reason: route,
        );
        expect(
          find.text('Lento avanti · Manubri'),
          findsWidgets,
          reason: route,
        );
        expect(tester.takeException(), isNull);
        await h.unmount(tester);
      }
    },
  );
}
