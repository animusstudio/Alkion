import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/data/models.dart';
import 'package:alkion/session/resume.dart';
import 'package:alkion/theme/app_theme.dart';
import 'package:alkion/theme/tokens.dart';
import 'package:alkion/settings/settings_service.dart' show RirControls;
import 'package:alkion/ui/day_editor.dart';
import 'package:alkion/ui/day_slot_card.dart';
import 'package:alkion/ui/history_screen.dart';
import 'package:alkion/ui/split_tab.dart';
import 'package:alkion/units/unit_service.dart';
import 'package:intl/date_symbol_data_local.dart';

import '../support/l10n_harness.dart';
import 'history_session_card_test.dart'
    show FakeSessionRepository, sessionRow, logged, catalog;

Widget _wrap(Widget child, Brightness brightness, Locale locale) => wrapL10n(
  Theme(data: buildTheme(brightness, defaultWorkoutAccent), child: child),
  locale: locale,
);

Future<void> _tabTo(WidgetTester tester, Finder target) async {
  for (var i = 0; i < 12; i++) {
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    if (tester.getSemantics(target).flagsCollection.isFocused ==
        Tristate.isTrue) {
      return;
    }
  }
  fail('The action never received keyboard focus');
}

void main() {
  setUpAll(() => initializeDateFormatting());

  for (final (brightness, locale) in [
    (Brightness.dark, const Locale('en')),
    (Brightness.light, const Locale('es')),
  ]) {
    testWidgets('day expansion and remove are independent keyboard targets '
        '${brightness.name}/${locale.languageCode}', (tester) async {
      final semantics = tester.ensureSemantics();
      try {
        await tester.binding.setSurfaceSize(const Size(412, 900));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        var expanded = 0;
        var removed = 0;
        final slot = DaySlotState(draft: SlotDraft(exerciseId: 'bench'));
        await tester.pumpWidget(
          _wrap(
            ReorderableListView(
              buildDefaultDragHandles: false,
              onReorderItem: (_, _) {},
              children: [
                DaySlotCard(
                  key: const ValueKey('card'),
                  instanceKey: slot.instanceKey,
                  draft: slot.draft,
                  exercise: catalog['bench']!,
                  reorderIndex: 0,
                  unit: Unit.kg,
                  rirControls: RirControls.off,
                  expanded: false,
                  onToggle: () => expanded++,
                  onRemove: () => removed++,
                  onChanged: () {},
                ),
              ],
            ),
            brightness,
            locale,
          ),
        );
        final expand = find.byKey(
          ValueKey('day-slot-expand-${slot.instanceKey}'),
        );
        expect(tester.getSize(expand).height, greaterThanOrEqualTo(48));
        final remove = find.byKey(
          ValueKey('day-slot-remove-${slot.instanceKey}'),
        );
        final removeNode = tester.getSemantics(remove);
        expect(removeNode.flagsCollection.isButton, isTrue);
        expect(removeNode.label, contains('Bench'));
        expect(removeNode.rect.size, const Size(48, 48));
        await _tabTo(tester, expand);
        final button = tester.widget<TextButton>(expand);
        expect(
          button.style!.overlayColor!.resolve({WidgetState.focused}),
          isNot(Colors.transparent),
        );
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pump();
        expect(expanded, 1);
        expect(removed, 0);
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pump();
        expect(removed, 1);
        expect(expanded, 1);
      } finally {
        semantics.dispose();
      }
    });

    testWidgets('Plan day action and menu keep separate keyboard activation '
        '${brightness.name}/${locale.languageCode}', (tester) async {
      final semantics = tester.ensureSemantics();
      try {
        var opened = 0;
        var menu = 0;
        await tester.pumpWidget(
          _wrap(
            SplitDayCard(
              weekday: 0,
              name: 'Upper A',
              focus: 'Push',
              exerciseCount: 3,
              onTap: () => opened++,
              onActions: () => menu++,
            ),
            brightness,
            locale,
          ),
        );
        final row = find.descendant(
          of: find.byType(SplitDayCard),
          matching: find.byType(TextButton),
        );
        await _tabTo(tester, row);
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pump();
        expect(opened, 1);
        expect(menu, 0);
        final action = find.descendant(
          of: find.byType(SplitDayCard),
          matching: find.byType(IconButton),
        );
        await _tabTo(tester, action);
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pump();
        expect(menu, 1);
        expect(opened, 1);
      } finally {
        semantics.dispose();
      }
    });

    testWidgets('History header expands by keyboard and Resume remains usable '
        '${brightness.name}/${locale.languageCode}', (tester) async {
      final semantics = tester.ensureSemantics();
      try {
        var resumed = 0;
        await tester.pumpWidget(
          _wrap(
            SessionCard(
              session: sessionRow(),
              catalogMap: catalog,
              sessionRepo: FakeSessionRepository([logged(60)]),
              units: UnitService(),
              resumeState: SessionResumeState.available,
              onResume: () => resumed++,
            ),
            brightness,
            locale,
          ),
        );
        final header = find.byKey(const ValueKey('history-expand-S'));
        expect(
          tester.getSemantics(header).flagsCollection.isExpanded,
          Tristate.isFalse,
        );
        await _tabTo(tester, header);
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        expect(
          tester.getSemantics(header).flagsCollection.isExpanded,
          Tristate.isTrue,
        );
        final resume = find.descendant(
          of: find.byKey(const ValueKey('history-resume')),
          matching: find.byType(TextButton),
        );
        await _tabTo(tester, resume);
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pump();
        expect(resumed, 1);
      } finally {
        semantics.dispose();
      }
    });
  }
}
