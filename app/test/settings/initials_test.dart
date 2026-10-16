import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/settings/settings_service.dart';

/// [initialsOf] is shared by the Profile avatar and the Today greeting avatar,
/// so they always show the same letters for a given profile name.
void main() {
  group('initialsOf', () {
    test('single word → first letter, uppercased', () {
      expect(initialsOf('madonna'), 'M');
      expect(initialsOf('Athlete'), 'A');
    });
    test('two+ words → first letter of the first two words', () {
      expect(initialsOf('John Doe'), 'JD');
      expect(initialsOf('mary jane watson'), 'MJ');
    });
    test('empty / whitespace → fallback A', () {
      expect(initialsOf(''), 'A');
      expect(initialsOf('   '), 'A');
    });
  });
}
