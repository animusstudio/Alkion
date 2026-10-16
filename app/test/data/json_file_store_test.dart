import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/data/json_file_store.dart';
import 'package:alkion/store/local_store.dart';

/// Incoming compatibility JSON is read-only evidence. These retained six
/// cases pin valid reads, refused overwrites/deletion and malformed preservation.
JsonFileStore<String> _store(Directory dir) => JsonFileStore<String>(
  filename: 'value.json',
  directory: () async => dir,
  encode: (v) => {'v': v},
  tryDecode: (raw) {
    try {
      final json = jsonDecode(raw) as Map<String, dynamic>;
      return json['v'] as String;
    } catch (_) {
      return null;
    }
  },
);

void main() {
  group('JsonFileStore', () {
    late Directory tmp;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('json_file_store_test');
    });

    tearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    test('load returns null when no file exists', () async {
      expect(await _store(tmp).load(), isNull);
    });

    test(
      'incoming valid value loads and refused save preserves original bytes',
      () async {
        final store = _store(tmp);
        final file = File('${tmp.path}/value.json');
        final bytes = utf8.encode('{"v":"hello","unknown":7}');
        await file.writeAsBytes(bytes);
        expect(await store.load(), 'hello');
        await expectLater(
          store.save('changed'),
          throwsA(
            isA<StoreException>().having(
              (e) => e.category,
              'read-only',
              'incoming_evidence_read_only',
            ),
          ),
        );
        expect(await file.readAsBytes(), bytes);
      },
    );

    test(
      'refused save preserves original and orphan temporary bytes',
      () async {
        final file = File('${tmp.path}/value.json'),
            orphan = File('${tmp.path}/value.json.tmp');
        await file.writeAsBytes([0, 255, 1, 2]);
        await orphan.writeAsBytes([255, 0, 4]);
        await expectLater(
          _store(tmp).save('hello'),
          throwsA(isA<StoreException>()),
        );
        expect(await file.readAsBytes(), [0, 255, 1, 2]);
        expect(await orphan.readAsBytes(), [255, 0, 4]);
        expect(await _store(tmp).load(), isNull);
        expect(await file.readAsBytes(), [0, 255, 1, 2]);
      },
    );

    test('load preserves and returns null for a malformed file', () async {
      final file = File('${tmp.path}/value.json');
      await file.writeAsString('not json');
      expect(await _store(tmp).load(), isNull);
      expect(file.existsSync(), isTrue);
      expect(await file.readAsString(), contains('not json'));
    });

    test('load preserves and returns null for a mistyped file', () async {
      // A cast failure inside tryDecode is a TypeError, not an Exception;
      // this pins that load() preserves evidence rather than rethrowing.
      final file = File('${tmp.path}/value.json');
      await file.writeAsString(jsonEncode({'v': 3}));
      expect(await _store(tmp).load(), isNull);
      expect(file.existsSync(), isTrue);
      expect(await file.readAsString(), jsonEncode({'v': 3}));
    });

    test(
      'clear refuses deletion both with existing and absent evidence',
      () async {
        final store = _store(tmp);
        final file = File('${tmp.path}/value.json');
        await file.writeAsString('{"v":"hello"}');
        await expectLater(store.clear(), throwsA(isA<StoreException>()));
        expect(await file.readAsString(), '{"v":"hello"}');
        await file.delete();
        await expectLater(store.clear(), throwsA(isA<StoreException>()));
        expect(await file.exists(), isFalse);
      },
    );
  });
}
