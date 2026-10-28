import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/main.dart';

void main() {
  test('legacy enablement and login cannot activate absent sync transport', () {
    expect(shouldConnectSync(syncEnabled: true, loggedIn: true), isFalse);
    expect(shouldConnectSync(syncEnabled: true, loggedIn: false), isFalse);
    expect(shouldConnectSync(syncEnabled: false, loggedIn: true), isFalse);
    expect(shouldConnectSync(syncEnabled: false, loggedIn: false), isFalse);
  });
}
