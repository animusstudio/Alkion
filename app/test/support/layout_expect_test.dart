import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/widgets/fit_label.dart';

import 'layout_expect.dart';

const _style = TextStyle(fontSize: 20);

Widget _host(Widget child, {required double width}) => Directionality(
  textDirection: TextDirection.ltr,
  child: DefaultTextStyle(
    style: _style,
    child: Align(
      alignment: Alignment.topLeft,
      child: SizedBox(width: width, child: child),
    ),
  ),
);

void main() {
  testWidgets('flags a word split across lines', (tester) async {
    await tester.pumpWidget(_host(const Text('BODYWEIGHT'), width: 40));
    expect(() => expectNoSplitWords(tester), throwsA(isA<TestFailure>()));
  });

  testWidgets('flags a number split across lines', (tester) async {
    await tester.pumpWidget(_host(const Text('1200'), width: 40));
    expect(() => expectNoSplitWords(tester), throwsA(isA<TestFailure>()));
  });

  testWidgets('passes a label that wraps between words', (tester) async {
    await tester.pumpWidget(_host(const Text('LOWER BODY'), width: 110));
    expectNoSplitWords(tester);
  });

  testWidgets('passes the same word in a FitLabel', (tester) async {
    await tester.pumpWidget(
      _host(const FitLabel('BODYWEIGHT', style: _style), width: 40),
    );
    expectNoSplitWords(tester);
  });

  testWidgets('within limits the check to the matched subtree', (tester) async {
    await tester.pumpWidget(
      _host(
        const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('BODYWEIGHT'),
            FitLabel('LOWER BODY', style: _style),
          ],
        ),
        width: 40,
      ),
    );
    expectNoSplitWords(tester, within: find.byType(FitLabel));
    expect(() => expectNoSplitWords(tester), throwsA(isA<TestFailure>()));
  });

  testWidgets('expectOneLine fails on a wrapped label', (tester) async {
    await tester.pumpWidget(_host(const Text('LOWER BODY'), width: 110));
    expect(
      () => expectOneLine(tester, find.text('LOWER BODY')),
      throwsA(isA<TestFailure>()),
    );
  });
}
