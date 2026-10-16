import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/main.dart';

void main() {
  test('routes to onboarding when not complete', () {
    expect(homeRouteFor(onboardingComplete: false), HomeRoute.onboarding);
  });
  test('routes to shell when onboarding complete', () {
    expect(homeRouteFor(onboardingComplete: true), HomeRoute.shell);
  });
  test('legacy enablement and login cannot activate absent sync transport', () {
    expect(shouldConnectSync(syncEnabled: true, loggedIn: true), isFalse);
    expect(shouldConnectSync(syncEnabled: true, loggedIn: false), isFalse);
    expect(shouldConnectSync(syncEnabled: false, loggedIn: true), isFalse);
    expect(shouldConnectSync(syncEnabled: false, loggedIn: false), isFalse);
  });
}
