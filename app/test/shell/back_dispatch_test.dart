import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/shell/back_dispatch.dart';

void main() {
  test('a tab that handled back wins (stay put)', () {
    expect(
      decideBack(tabHandled: true, tabIndex: 3, planEditsAtRisk: false),
      BackAction.none,
    );
  });
  test('non-home tab goes home', () {
    for (final i in [1, 2, 3]) {
      expect(
        decideBack(tabHandled: false, tabIndex: i, planEditsAtRisk: false),
        BackAction.goHome,
      );
    }
  });
  test('home exits', () {
    expect(
      decideBack(tabHandled: false, tabIndex: 0, planEditsAtRisk: false),
      BackAction.exit,
    );
  });
  test('home asks first while a Plan editor holds unsaved edits', () {
    expect(
      decideBack(tabHandled: false, tabIndex: 0, planEditsAtRisk: true),
      BackAction.confirmExit,
    );
  });
  test('unsaved Plan edits leave back on the other tabs unchanged', () {
    for (final i in [1, 2, 3]) {
      expect(
        decideBack(tabHandled: false, tabIndex: i, planEditsAtRisk: true),
        BackAction.goHome,
      );
    }
  });
  test('a Plan tab that handled back still wins with edits at risk', () {
    expect(
      decideBack(tabHandled: true, tabIndex: 3, planEditsAtRisk: true),
      BackAction.none,
    );
  });
}
