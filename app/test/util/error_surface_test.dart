import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/util/error_surface.dart';

void main() {
  // The suite shares a process across test files, so leaking a mutated
  // ErrorWidget.builder into other files would be a real hazard — restore it.
  late ErrorWidgetBuilder original;
  setUp(() {
    original = ErrorWidget.builder;
    installErrorSurface();
  });
  tearDown(() => ErrorWidget.builder = original);

  List<MethodCall> mockPlatform(WidgetTester tester) {
    final calls = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        calls.add(call);
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    return calls;
  }

  test('only a release build installs the card', () {
    ErrorWidget.builder = original;
    installReleaseErrorSurface(release: false);
    expect(ErrorWidget.builder, same(original));
    installReleaseErrorSurface(release: true);
    expect(ErrorWidget.builder, isNot(same(original)));
  });

  testWidgets('a build exception renders a generic card, not a blank box', (
    tester,
  ) async {
    await tester.pumpWidget(
      Builder(builder: (_) => throw StateError('kaboom-marker')),
    );

    // The framework still reports the error...
    expect(tester.takeException(), isStateError);
    // ...the user sees a readable, generic card with no MaterialApp ancestor,
    // and the raw text (which can name files) stays off screen.
    expect(find.text('Something went wrong on this screen'), findsOneWidget);
    expect(find.text('Tap to copy the error details'), findsOneWidget);
    expect(find.textContaining('kaboom-marker'), findsNothing);
  });

  testWidgets('the card follows the platform language', (tester) async {
    tester.platformDispatcher.localeTestValue = const Locale('de');
    addTearDown(tester.platformDispatcher.clearLocaleTestValue);
    await tester.pumpWidget(
      Builder(builder: (_) => throw StateError('kaboom-marker')),
    );
    expect(tester.takeException(), isStateError);
    expect(
      find.text('Auf diesem Bildschirm ist etwas schiefgelaufen'),
      findsOneWidget,
    );
  });

  testWidgets('tapping the card copies the details and says Copied', (
    tester,
  ) async {
    final calls = mockPlatform(tester);
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      Builder(builder: (_) => throw StateError('copy-me-marker')),
    );
    expect(tester.takeException(), isStateError);

    final card = find.bySemanticsLabel(
      RegExp('Something went wrong on this screen'),
    );
    expect(card, findsOneWidget);
    expect(
      tester.getSemantics(card),
      isSemantics(isButton: true, hasTapAction: true),
    );

    await tester.tap(find.text('Something went wrong on this screen'));
    await tester.pump();

    final copied = calls.where((c) => c.method == 'Clipboard.setData');
    expect(copied, hasLength(1));
    final text = (copied.first.arguments as Map)['text'] as String;
    expect(text, contains('copy-me-marker'));
    expect(find.text('Copied'), findsOneWidget);
    expect(find.text('Tap to copy the error details'), findsNothing);

    await tester.pump(const Duration(seconds: 3));
    expect(find.text('Copied'), findsNothing);
    expect(find.text('Tap to copy the error details'), findsOneWidget);
    semantics.dispose();
  });
}
