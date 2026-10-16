import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../../tool/alkion_store_recovery.dart' show checkpointReuseCase;

void main() {
  test(
    'checkpoint-reused WAL preserves commits and ignores rolled-back writes',
    () async {
      for (final rolledBack in [false, true]) {
        final output = await Directory.systemTemp.createTemp(
          'alkion-wal-reuse-test-',
        );
        try {
          final result = await checkpointReuseCase(
            output,
            rolledBack: rolledBack,
          );
          expect(result['status'], 'PASS');
          expect(result['reopens'], 2);
          final layout = result['layout'] as Map;
          expect(layout['older_tail_frames'], greaterThan(0));
          expect(layout['old_tail_unchanged'], isTrue);
          expect(
            layout['last_current_commit'],
            rolledBack ? 0 : layout['current_frames'],
          );
          expect(result['native_copied_wal'], result['expected']);
          expect(result['reopened'], result['expected']);
        } finally {
          await output.delete(recursive: true);
        }
      }
    },
  );
}
