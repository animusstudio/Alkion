import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/session/active_session_controller.dart';

void main() {
  test('draftOrNull is null before a session is built', () {
    final c = ActiveSessionController();
    expect(c.hasSession, isFalse);
    expect(c.draftOrNull, isNull);
  });
}
