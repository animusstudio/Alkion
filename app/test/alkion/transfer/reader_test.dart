import 'dart:convert';
import 'dart:typed_data';

import 'package:alkion/transfer/json_span_reader.dart';
import 'package:flutter_test/flutter_test.dart';

import 'transfer_harness.dart';

Matcher rejects(String category) => throwsA(
  isA<TransferRejection>().having((e) => e.category, 'category', category),
);

void main() {
  group('reps-full-reader/1 encoding and spans', () {
    test('L01 byte spans slice exact lexemes after multi-byte text', () {
      final bytes = utf8Bytes('{"Ünïcødé 🏋️":"ok","w\\u0065ight":40.5000}');
      final root = readJsonSpans(bytes);
      final member = root.members!.last;
      expect(member.key, 'weight');
      expect(
        utf8.decode(bytes.sublist(member.keyStart, member.keyEnd)),
        '"w\\u0065ight"',
      );
      expect(member.value.lexeme(bytes), '40.5000');
      expect(member.value.text, '40.5000');
      expect(root.members!.first.key, 'Ünïcødé 🏋️');
    });

    test('L02 invalid UTF-8 inside or outside strings is refused', () {
      for (final bad in [
        [0x7B, 0x22, 0xC3, 0x22, 0x3A, 0x31, 0x7D],
        [0x7B, 0x7D, 0xFF],
        [0x22, 0xED, 0xA0, 0x80, 0x22],
        [0x22, 0xC0, 0xAF, 0x22],
      ]) {
        expect(
          () => readJsonSpans(Uint8List.fromList(bad)),
          rejects('invalid_utf8'),
        );
      }
    });

    test('L03 BOM and lone surrogates refused; valid pairs decode', () {
      expect(
        () => readJsonSpans(Uint8List.fromList([0xEF, 0xBB, 0xBF, 0x7B, 0x7D])),
        rejects('byte_order_mark_unsupported'),
      );
      expect(
        () => readJsonSpans(utf8Bytes(r'"\ud83d"')),
        rejects('lone_surrogate_unsupported'),
      );
      expect(
        () => readJsonSpans(utf8Bytes(r'"\udc00x"')),
        rejects('lone_surrogate_unsupported'),
      );
      expect(readJsonSpans(utf8Bytes(r'"🏋"')).text, '🏋');
    });

    test('L04 one complete root followed only by whitespace', () {
      expect(readJsonSpans(utf8Bytes('{} \n\t\r ')).kind, JsonKind.object);
      expect(
        () => readJsonSpans(utf8Bytes('{}{}')),
        rejects('trailing_content'),
      );
      expect(
        () => readJsonSpans(utf8Bytes('{} x')),
        rejects('trailing_content'),
      );
      expect(() => readJsonSpans(utf8Bytes('')), rejects('unexpected_end'));
    });

    test('L05 JSON number grammar only, in known and unknown positions', () {
      for (final bad in [
        '+1',
        '01',
        '-.1',
        '1.',
        '.5',
        '1e',
        '1e+',
        'NaN',
        'Infinity',
        '-',
        '0x10',
        '1_0',
      ]) {
        expect(
          () => readJsonSpans(utf8Bytes('{"unknown":[{"n":$bad}]}')),
          throwsA(isA<TransferRejection>()),
          reason: bad,
        );
      }
      for (final good in ['0', '-0', '1e400', '4.050E+1', '-12.30e-2']) {
        expect(readJsonSpans(utf8Bytes('[$good]')).items!.single.text, good);
      }
    });

    test('L06 bad escapes, controls, comments, trailing commas, nesting', () {
      for (final bad in [
        r'"\x"',
        '"a\u0001b"',
        '{"a":1,}',
        '[1,]',
        '{"a":1 // c\n}',
        '/* c */{}',
        '{"a":[1}',
        '[[1]',
        '{"a" 1}',
        '{1:2}',
      ]) {
        expect(
          () => readJsonSpans(utf8Bytes(bad)),
          throwsA(isA<TransferRejection>()),
          reason: bad,
        );
      }
    });
  });

  group('decoded duplicate keys', () {
    for (final (id, json) in [
      ('D01 root', r'{"format":1,"format":2}'),
      ('D02 data', r'{"data":{"sets":[],"sets":[]}}'),
      ('D03 row', r'{"data":{"sets":[{"id":"a","reps":1,"reps":2}]}}'),
      ('D04 settings', r'{"settings":{"unit":"kg","unit":"lb"}}'),
      ('D05 unknown nested', r'{"x":[{"y":[{"k":1,"k":2}]}]}'),
    ]) {
      test('$id rejects before any map collapse', () {
        expect(() => readJsonSpans(utf8Bytes(json)), rejects('duplicate_key'));
      });
    }

    test('D06 normalization/case variants stay distinct keys', () {
      final root = readJsonSpans(
        utf8Bytes('{"café":1,"café":2,"Unit":3,"unit":4," unit":5}'),
      );
      expect(root.members!.map((m) => m.key).toList(), [
        'café',
        'café',
        'Unit',
        'unit',
        ' unit',
      ]);
    });
  });

  group('exact numbers never pass through double', () {
    test('N01/N03 lexemes and exact plain projection', () {
      expect(exactPlainDecimal('9007199254740993'), '9007199254740993');
      expect(exactPlainDecimal('40.5000'), '40.5000');
      expect(exactPlainDecimal('4.050e1'), '40.50');
      expect(exactPlainDecimal('4.050E+1'), '40.50');
      expect(exactPlainDecimal('405.0e-1'), '40.50');
      expect(exactPlainDecimal('0.000000000000000000001e21'), '1');
      expect(exactPlainDecimal('-0'), '-0');
      expect(exactPlainDecimal('-0.0e0'), '-0.0');
      expect(exactPlainDecimal('1e0'), '1');
      expect(exactPlainDecimal('10e-1'), '1.0');
      expect(exactPlainDecimal('5e-3'), '0.005');
    });

    test('N06/B03 huge exponents stay raw and unprojectable', () {
      expect(exactPlainDecimal('1e400'), isNotNull);
      expect(exactPlainDecimal('1e999999'), isNull);
      expect(exactPlainDecimal('1e-99999999999999999999'), isNull);
      final node = readJsonSpans(utf8Bytes('[1e99999999999999999999]'));
      expect(node.items!.single.text, '1e99999999999999999999');
    });
  });

  group('B02 resource ceilings refuse instead of truncating', () {
    test('depth, tokens, string, number and input bounds', () {
      expect(
        () => readJsonSpans(
          utf8Bytes('${'[' * 5}${']' * 5}'),
          limits: const ReaderLimits(maxDepth: 4),
        ),
        rejects('resource_limit_depth'),
      );
      expect(
        readJsonSpans(
          utf8Bytes('${'[' * 4}${']' * 4}'),
          limits: const ReaderLimits(maxDepth: 4),
        ).kind,
        JsonKind.array,
      );
      expect(
        () => readJsonSpans(
          utf8Bytes('[1,2,3]'),
          limits: const ReaderLimits(maxTokens: 3),
        ),
        rejects('resource_limit_tokens'),
      );
      expect(
        () => readJsonSpans(
          utf8Bytes('"abcdef"'),
          limits: const ReaderLimits(maxStringBytes: 4),
        ),
        rejects('resource_limit_string'),
      );
      expect(
        () => readJsonSpans(
          utf8Bytes('123456'),
          limits: const ReaderLimits(maxNumberBytes: 5),
        ),
        rejects('resource_limit_number'),
      );
      expect(
        () => readJsonSpans(
          utf8Bytes('{}  '),
          limits: const ReaderLimits(maxInputBytes: 3),
        ),
        rejects('resource_limit_input'),
      );
    });
  });
}
