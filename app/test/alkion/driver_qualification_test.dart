import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../tool/alkion_driver_qualification.dart';

void main() {
  test(
    'standalone locked SQLite transaction/watch/WAL/backup primitives',
    () async {
      final output = await Directory.systemTemp.createTemp(
        'alkion-driver-test-',
      );
      addTearDown(() => output.delete(recursive: true));
      final result = await qualifyDriver(output);
      expect(
        (result['cases'] as Map<String, String>).values,
        everyElement('PASS'),
      );
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );
}
