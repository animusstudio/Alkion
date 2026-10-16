import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/theme/tokens.dart';

void main() {
  testWidgets('pages clear the tab bar plus the system navigation inset', (
    tester,
  ) async {
    late double inset;
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(viewPadding: EdgeInsets.only(bottom: 24)),
        child: Builder(
          builder: (context) {
            inset = bottomNavInset(context);
            return const SizedBox();
          },
        ),
      ),
    );
    // On a gesture-bar phone the last row sat under the start button.
    expect(inset, kBottomNavInset + 24);
  });
}
