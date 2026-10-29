import 'dart:convert';
import 'dart:typed_data';

import 'package:alkion/data/day_template_repository.dart';
import 'package:alkion/data/models.dart';
import 'package:alkion/export/alkion_exports.dart';
import 'package:alkion/export/export_service.dart';
import 'package:alkion/store/local_store.dart';
import 'package:alkion/transfer/transfer_service.dart';
import 'package:flutter_test/flutter_test.dart';

import 'transfer_harness.dart';

const at = '2026-10-29T10:00:00Z';
Matcher category(String value) =>
    throwsA(isA<StoreException>().having((e) => e.category, 'category', value));

final class RecordingDelivery implements ExportDelivery {
  int calls = 0;
  @override
  Future<ExportResult> deliver(Uint8List bytes, String filename) async {
    calls++;
    return const ExportResult(ExportOutcome.saved);
  }
}

void main() {
  late TransferHarness h;
  setUp(() async {
    h = await TransferHarness.open('prescription-transfer');
  });
  tearDown(() async {
    await h.close();
  });

  test(
    'new legacy days are active; same and changed reimport retain later local Disable and review boundary',
    () async {
      final transfer = TransferService(h.store);
      final original = fixture('full-rich-synthetic-v1.json');
      expect(
        (await transfer.importArtifact(
          original,
          namespace: 'synthetic',
        )).status,
        ImportStatus.selected,
      );
      final repo = DayTemplateRepository.local(h.store);
      final day = (await repo.allDays()).single;
      expect(day.active, isTrue);
      expect(day.slots.single.rirPolicy, isNull);
      await repo.commitPrepared(
        repo.prepareSetActive(day.id, day.localRevision!, false),
      );
      final before = await h.store.inventory();
      final disabled = (await repo.byId(day.id))!;
      expect(
        (await transfer.importArtifact(
          original,
          namespace: 'synthetic',
        )).status,
        ImportStatus.alreadySelected,
      );
      expect(await h.store.inventory(), before);
      final changed = utf8Bytes(
        utf8
            .decode(original)
            .replaceFirst(
              '"name": "Synthetic Day"',
              '"name": "Changed Source Day"',
            ),
      );
      final result = await transfer.importArtifact(
        changed,
        namespace: 'synthetic',
      );
      expect(result.status, ImportStatus.selected);
      final retained = (await repo.byId(day.id))!;
      expect(retained.active, isFalse);
      expect(retained.name, day.name);
      expect(retained.localRevision, disabled.localRevision);
      final after = await h.store.inventory();
      for (final table in [
        'day_templates',
        'day_template_items',
        'sets',
        'sessions',
        'operations',
      ]) {
        expect(after[table], before[table], reason: table);
      }
      final review = (await transfer.reviews())
          .where((r) => r['category'] == 'source_changed_under_overlay')
          .single;
      expect(review, isNotNull);
      final stable = await h.reopenTwice();
      expect(stable['day_templates'], after['day_templates']);
      expect(
        (await DayTemplateRepository.local(h.store).allDays()).single.active,
        isFalse,
      );
    },
  );

  test(
    'frozen v1 decoder ignores claimed activation/policy, native carries local fields, compatibility refuses before delivery',
    () async {
      final original = fixture('full-rich-synthetic-v1.json');
      final input = utf8Bytes(
        utf8
            .decode(original)
            .replaceFirst(
              '"name": "Synthetic Day"',
              '"name": "Synthetic Day", "is_active": 0',
            )
            .replaceFirst(
              '"id": "slot1"',
              '"id": "slot1", "rir_policy": "off"',
            ),
      );
      await TransferService(
        h.store,
      ).importArtifact(input, namespace: 'synthetic');
      final repo = DayTemplateRepository.local(h.store),
          day = (await DayTemplateRepository.local(h.store).allDays()).single;
      expect(day.active, isTrue);
      expect(day.slots.single.rirPolicy, isNull);
      final delivery = RecordingDelivery(),
          exports = ExportService(h.store, delivery: RecordingDelivery());
      expect(await exports.transferBytes(), isNotEmpty);
      final slot = day.slots.single;
      Future<void> policy(String? value, {int? low, int? high}) async {
        final current = (await repo.byId(day.id))!,
            s = (await repo.byId(day.id))!.slots.single;
        await repo.saveDay(
          id: current.id,
          draft: DayDraft(
            name: current.name,
            localRevision: current.localRevision,
            rawFields: current.rawFields,
            changedFields: {},
            slots: [
              SlotDraft(
                itemId: slot.id,
                exerciseId: slot.exerciseId,
                localRevision: s.localRevision,
                rawFields: s.rawFields,
                changedFields: {
                  'rir_policy',
                  'target_rir_low',
                  'target_rir_high',
                },
                rirPolicy: value,
                rirLow: low,
                rirHigh: high,
              ),
            ],
          ),
        );
      }

      for (final value in [RirPolicy.off, 'future-policy', RirPolicy.target]) {
        await policy(value);
        final service = ExportService(h.store, delivery: delivery);
        await expectLater(
          service.exportTransfer(),
          category('compat_export_rir_policy_requires_native_backup'),
        );
        expect(delivery.calls, 0);
      }
      await policy(RirPolicy.target, low: 2, high: 3);
      expect(await exports.transferBytes(), isNotEmpty);
      await policy(RirPolicy.inherit, low: 2, high: 3);
      await expectLater(
        exports.transferBytes(),
        category('compat_export_rir_policy_requires_native_backup'),
      );
      await policy(RirPolicy.inherit);
      expect(await exports.transferBytes(), isNotEmpty);
      await policy(RirPolicy.off);
      final native = await h.store.readTransaction(
        (tx) => buildDomainExport(tx, exportedAt: at),
      );
      expect(
        (((native['domain'] as Map)['day_template_items'] as List).single
            as Map)['rir_policy'],
        RirPolicy.off,
      );
      final latest = (await repo.byId(day.id))!;
      await repo.commitPrepared(
        repo.prepareSetActive(day.id, latest.localRevision!, false),
      );
      await expectLater(
        exports.transferBytes(),
        category('compat_export_day_activation_requires_native_backup'),
      );
    },
  );
}
