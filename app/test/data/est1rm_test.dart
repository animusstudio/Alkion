import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/data/models.dart';

void main() {
  group('est1rm', () {
    test('Epley formula rounds correctly', () {
      // 100 * (1 + 5/30) = 116.666... → 117
      expect(est1rm(100, 5), 117);
    });
    test('a single still goes through Epley: 100 kg x1 reads 103', () {
      expect(est1rm(100, 1), 103);
    });
  });
}
