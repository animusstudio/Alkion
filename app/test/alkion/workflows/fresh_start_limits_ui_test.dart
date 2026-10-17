import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:alkion/data/active_session_draft.dart';
import 'package:alkion/data/day_template_repository.dart';
import 'package:alkion/l10n/app_localizations.dart';
import 'package:alkion/session/active_session_screen.dart';
import 'package:alkion/session/session_manager.dart';
import 'package:alkion/shell/app_shell.dart';
import 'package:alkion/transfer/transfer_service.dart';
import 'package:alkion/ui/day_editor.dart';
import 'package:alkion/widgets/stepper.dart';
import 'package:alkion/widgets/split_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import '../domains/best_load_consumers_test.dart' show ConsumerHarness;
import '../domains/local_screen_harness.dart';
import '../transfer/import_test.dart' show localId;
import 'compatibility_history_test.dart' show checkpoint;
import 'fresh_start_limits_test.dart' show freshPlanBytes;

Uint8List variant(String kind) {
  final document = jsonDecode(utf8.decode(freshPlanBytes())) as Map;
  final data = document['data'] as Map;
  final item = (data['day_template_items'] as List).single as Map;
  if (kind == 'warmup') {
    item['target_working_sets'] = 1;
    item['target_warmup_sets'] = 100;
  } else if (kind == 'slots' || kind == 'total') {
    item['target_working_sets'] = kind == 'slots' ? 1 : 5;
    item['target_warmup_sets'] = kind == 'slots' ? 0 : 5;
    data['day_template_items'] = [
      for (var i = 0; i < (kind == 'slots' ? 101 : 100); i++)
        {
          ...item,
          'id': 'slot-$i',
          'position': i + 1,
          if (kind == 'total' && i == 99) 'target_warmup_sets': 6,
        },
    ];
  }
  return Uint8List.fromList(utf8.encode(jsonEncode(document)));
}

Widget mounted(
  ConsumerHarness h,
  SessionManager manager,
  String locale,
  Widget home,
) => h.wrap(
  ChangeNotifierProvider<SessionManager>.value(
    value: manager,
    child: Builder(
      builder: (context) => Localizations.override(
        context: context,
        locale: Locale(locale),
        child: home,
      ),
    ),
  ),
);

void main() {
  for (final locale in ['en', 'de', 'es', 'it']) {
    for (final kind in ['working', 'warmup', 'slots', 'total']) {
      testWidgets(
        'actual imported $kind refusal and two reopens in $locale; no draft/operation/source mutation',
        (tester) async {
          final h = ConsumerHarness();
          final bytes = variant(kind);
          String? artifact;
          await h.open(
            tester,
            seed: (db) async {
              final outcome = await TransferService(
                db,
              ).importArtifact(bytes, namespace: 'fresh');
              expect(outcome.status, ImportStatus.selected);
              artifact = outcome.artifactId;
            },
          );
          SessionManager? manager;
          try {
            setPhone(tester, width: 412);
            manager = SessionManager(
              draftStore: DraftStore.local(h.localDatabase),
            );
            final before = await tester.runAsync(h.database.inventory);
            await tester.runAsync(() async {
              await File('${h.root.path}/original-v1.json').writeAsBytes(bytes);
              await checkpoint(h.database, h.root, 'before-start');
            });
            await tester.pumpWidget(
              mounted(h, manager, locale, const AppShell()),
            );
            await settleUntilFound(
              tester,
              find.byType(SplitCard),
              where: 'real Today Start',
            );
            final l = AppLocalizations.of(
              tester.element(find.byType(AppShell)),
            );
            await tester.tap(find.text(l.splitStartWorkout));
            await settleUntilFound(
              tester,
              find.text(l.alkionFreshLimitTitle),
              where: 'visible refusal',
            );
            final message = switch (kind) {
              'working' => l.alkionFreshWorkingLimit('Synthetic lift', 100),
              'warmup' => l.alkionFreshWarmupLimit('Synthetic lift', 100),
              'slots' => l.alkionFreshSlotLimit(101),
              _ => l.alkionFreshTotalLimit('Synthetic lift'),
            };
            expect(
              find.text('$message\n\n${l.alkionFreshLimitCorrection}'),
              findsOneWidget,
            );
            expect(manager.hasActive, isFalse);
            expect(
              manager.launching,
              isFalse,
              reason: 'released while refusal is visible',
            );
            expectLayoutHolds(tester, '$kind refusal $locale');
            await tester.runAsync(() async {
              expect(await h.database.inventory(), before);
              expect(
                await TransferService(h.database).originalBytes(artifact!),
                bytes,
              );
              expect(await DraftStore.local(h.database).load(), isNull);
              await checkpoint(h.database, h.root, 'refused');
            });
            await tester.tap(find.text(l.commonOk));
            await settleReal(tester, ticks: 4);

            if (locale == 'en' && kind == 'working') {
              // The actual Today carousel's custom workout can start immediately.
              await tester.drag(
                find.descendant(
                  of: find.byType(SplitCard),
                  matching: find.byType(PageView),
                ),
                const Offset(-380, 0),
              );
              await settleReal(tester, ticks: 10);
              await tester.tap(find.text(l.splitStartEmpty));
              await settleUntilFound(
                tester,
                find.byType(ActiveSessionScreen),
                where: 'unrelated custom Start',
              );
              expect(manager.active!.draft.templateId, isNull);
              final active = manager.active!;
              await tester.runAsync(manager.flushPersistence);
              final customInventory = await tester.runAsync(
                h.database.inventory,
              );
              final customDraft = jsonEncode(active.snapshot().toJson());
              await tester.tap(find.text(l.sessionAddExercise));
              await settleUntilFound(
                tester,
                find.text('Synthetic lift'),
                where: 'real Add exercise picker',
              );
              await settleReal(tester, ticks: 10);
              await tester.ensureVisible(find.text('Synthetic lift'));
              await tester.tap(find.text('Synthetic lift'));
              await settleUntilFound(
                tester,
                find.text(l.alkionFreshLimitTitle),
                where: 'invalid default refusal',
              );
              expect(
                find.text(
                  '${l.alkionFreshWorkingLimit('Synthetic lift', 100)}\n\n${l.alkionFreshLimitCorrection}',
                ),
                findsOneWidget,
              );
              expect(jsonEncode(active.snapshot().toJson()), customDraft);
              expect(identical(manager.active, active), isTrue);
              await tester.runAsync(() async {
                expect(await h.database.inventory(), customInventory);
                await checkpoint(h.database, h.root, 'add-default-refused');
              });
              expect(tester.takeException(), isNull);
              await tester.tap(find.text(l.commonOk));
              await settleReal(tester, ticks: 4);
              await tester.runAsync(active.discard);
              active.dispose();
              tester.state<NavigatorState>(find.byType(Navigator).first).pop();
              await settleReal(tester, ticks: 5);
              expect(manager.hasActive, isFalse);
              expect(manager.launching, isFalse);
            }
            manager.dispose();
            manager = null;
            await h.reopen(tester, 0);
            await h.reopen(tester, 1);
            await tester.runAsync(() async {
              expect(await DraftStore.local(h.database).load(), isNull);
              expect(
                await TransferService(h.database).originalBytes(artifact!),
                bytes,
              );
              if (locale != 'en' || kind != 'working') {
                expect(await h.database.inventory(), before);
              }
            });

            if (locale == 'en' && kind == 'working') {
              // Correct the offending count through the production editor and
              // typed stepper, then reopen before the next production Start.
              final dayId = (await tester.runAsync(
                () => localId(h.database, 'fresh', 'day_templates', 'plan'),
              ))!;
              manager = SessionManager(
                draftStore: DraftStore.local(h.localDatabase),
              );
              await tester.pumpWidget(
                mounted(
                  h,
                  manager,
                  locale,
                  Scaffold(
                    body: DayEditor(id: dayId, onBack: () {}),
                  ),
                ),
              );
              await settleUntilFound(
                tester,
                find.text('Synthetic lift'),
                where: 'real plan editor',
              );
              await tester.tap(find.text('Synthetic lift'));
              await settleReal(tester, ticks: 5);
              final working = find.byWidgetPredicate(
                (w) =>
                    w is WStepper && w.semanticLabel == l.dayEditorWorkingSets,
              );
              await tester.ensureVisible(working);
              await tester.tap(
                find.descendant(of: working, matching: find.text('100')),
              );
              await tester.pump();
              await tester.enterText(
                find.descendant(of: working, matching: find.byType(TextField)),
                '2',
              );
              await tester.testTextInput.receiveAction(TextInputAction.done);
              await tester.pump();
              await tester.ensureVisible(find.text(l.dayEditorSaveChanges));
              await tester.tap(find.text(l.dayEditorSaveChanges));
              await settleReal(tester, ticks: 15);
              await tester.runAsync(() async {
                final corrected = (await DayTemplateRepository.local(
                  h.database,
                ).byId(dayId))!;
                expect(corrected.slots.single.workSets, 2);
                expect(corrected.slots.single.warmupSets, 0);
                expect(
                  await TransferService(h.database).originalBytes(artifact!),
                  bytes,
                );
              });
              manager.dispose();
              manager = null;
              await h.reopen(tester, 2);
              await h.reopen(tester, 3);
              manager = SessionManager(
                draftStore: DraftStore.local(h.localDatabase),
              );
              await tester.pumpWidget(
                mounted(h, manager, locale, const AppShell()),
              );
              await settleUntilFound(
                tester,
                find.text(l.splitStartWorkout),
                where: 'corrected Start',
              );
              await tester.tap(find.text(l.splitStartWorkout));
              await settleUntilFound(
                tester,
                find.byType(ActiveSessionScreen),
                where: 'corrected workout after reopen',
              );
              expect(
                manager.active!.draft.blocks.single.workingSets,
                hasLength(2),
              );
              await tester.runAsync(manager.flushPersistence);
              expectLayoutHolds(tester, 'corrected active workout');
              final active = manager.active!;
              await h.unmount(tester);
              manager.dispose();
              manager = null;
              active.dispose();
              await h.reopen(tester, 4);
              await h.reopen(tester, 5);
              await tester.runAsync(() async {
                expect(
                  (await DraftStore.local(
                    h.database,
                  ).load())!.blocks.single.workingSets,
                  hasLength(2),
                );
                expect(
                  await TransferService(h.database).originalBytes(artifact!),
                  bytes,
                );
              });
            }
          } finally {
            await h.unmount(tester);
            manager?.active?.dispose();
            manager?.dispose();
            h.manager.dispose();
            await h.close(tester);
          }
        },
      );
    }
  }
}
