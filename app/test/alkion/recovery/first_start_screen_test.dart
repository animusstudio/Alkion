import 'dart:async';
import 'dart:io';

import 'package:alkion/animus/connection.dart';
import 'package:alkion/animus/config.dart';
import 'package:alkion/animus/contracts.dart';
import 'package:alkion/animus/ports.dart';
import 'package:alkion/animus/probe.dart';
import 'package:alkion/l10n/app_localizations.dart';
import 'package:alkion/identity/alkion_identity.dart';
import 'package:alkion/recovery/restore.dart';
import 'package:alkion/theme/app_theme.dart';
import 'package:alkion/theme/tokens.dart';
import 'package:alkion/ui/alkion_recovery/first_start_screen.dart';
import 'package:alkion/widgets/alkion_brand.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import '../domains/local_screen_harness.dart' show settleReal;
import '../files/fake_documents.dart';
import 'first_start_restore_test.dart'
    show firstActionReady, openOfflineChoices;
import '../../support/app_fonts.dart';
import '../../animus/support.dart';

Widget _app(
  Widget home, {
  String locale = 'en',
  Brightness brightness = Brightness.dark,
}) => MaterialApp(
  theme: buildTheme(brightness, accents[0]),
  locale: Locale(locale),
  localizationsDelegates: const [
    AppLocalizations.delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
  ],
  supportedLocales: AppLocalizations.supportedLocales,
  home: home,
);

void _narrow(WidgetTester tester) {
  tester.view.physicalSize = const Size(320, 760);
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = 2;
  tester.platformDispatcher.accessibilityFeaturesTestValue =
      FakeAccessibilityFeatures.allOn;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
}

void _completeParagraphs(WidgetTester tester) {
  for (final element in find.byType(RichText).evaluate()) {
    final paragraph = element.renderObject! as RenderParagraph;
    expect(
      paragraph.didExceedMaxLines,
      isFalse,
      reason: paragraph.text.toPlainText(),
    );
  }
  for (final element
      in find.byWidgetPredicate((w) => w is ButtonStyleButton).evaluate()) {
    final size = tester.getSize(find.byWidget(element.widget));
    expect(size.width, greaterThanOrEqualTo(48));
    expect(size.height, greaterThanOrEqualTo(48));
  }
  expect(tester.takeException(), isNull);
}

void main() {
  setUpAll(preloadAppFonts);
  testWidgets(
    'production large-text step navigation starts at the top and picker cancellation preserves offline choices',
    (tester) async {
      _narrow(tester);
      late Directory temp;
      await tester.runAsync(() async {
        temp = await Directory.systemTemp.createTemp('alkion-entry-scroll-');
      });
      addTearDown(() => temp.delete(recursive: true));
      final root = Directory('${temp.path}/${AlkionIdentity.applicationId}');
      final documents = FakeDocuments(temp);
      await tester.pumpWidget(
        AlkionFirstStartApp(
          service: RestoreService(root),
          state: const FreshRestoreState(canStartLocal: true),
          documents: documents,
          startLocal: () async {
            fail('Navigation must not create a profile');
          },
          relaunch: () async {
            fail('Picker cancellation must not relaunch');
          },
        ),
      );
      await tester.pumpAndSettle();
      ScrollPosition position() =>
          tester.state<ScrollableState>(find.byType(Scrollable)).position;
      final viewport = tester.getRect(find.byType(SingleChildScrollView));
      final offline = find.byKey(const Key('first-go-offline'));
      await tester.ensureVisible(offline);
      await tester.pumpAndSettle();
      expect(position().pixels, greaterThan(0));
      await tester.tap(offline);
      await tester.pumpAndSettle();
      expect(position().pixels, 0);
      final back = find.byKey(const Key('first-offline-back'));
      expect(viewport.contains(tester.getCenter(back)), isTrue);
      expect(
        tester.getRect(find.byType(AlkionBrandLockup)).top,
        greaterThanOrEqualTo(viewport.top),
      );
      final restore = find.byKey(const Key('first-restore'));
      await tester.ensureVisible(restore);
      await tester.pumpAndSettle();
      final beforeCancel = position().pixels;
      await tester.tap(restore);
      await firstActionReady(tester);
      expect(documents.opens, 1);
      expect(position().pixels, beforeCancel);
      expect(find.byKey(const Key('first-start-local')), findsOneWidget);
      expect(find.byKey(const Key('first-animus-sign-in')), findsNothing);
      expect(root.existsSync(), isFalse);
      await tester.ensureVisible(back);
      await tester.tap(back);
      await tester.pumpAndSettle();
      expect(position().pixels, 0);
      expect(
        tester.getRect(find.byType(AlkionBrandLockup)).top,
        greaterThanOrEqualTo(viewport.top),
      );
      expect(find.byKey(const Key('first-animus-sign-in')), findsOneWidget);
      expect(find.byKey(const Key('first-restore')), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'production first-start app follows system light and dark themes on both entry steps',
    (tester) async {
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          FakeAccessibilityFeatures.allOn;
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
      await tester.pumpWidget(
        AlkionFirstStartApp(
          service: RestoreService(
            Directory('/synthetic-unopened-entry-target'),
          ),
          state: const FreshRestoreState(canStartLocal: true),
          startLocal: () async {
            fail('Changing theme must not create a profile');
          },
          relaunch: () async {
            fail('Changing theme must not relaunch');
          },
        ),
      );
      await tester.pumpAndSettle();
      expect(
        Theme.of(tester.element(find.byType(FirstStartScreen))).brightness,
        Brightness.light,
      );
      for (final offline in [false, true]) {
        if (offline) await openOfflineChoices(tester);
        for (final brightness in [Brightness.dark, Brightness.light]) {
          tester.platformDispatcher.platformBrightnessTestValue = brightness;
          await tester.pumpAndSettle();
          final context = tester.element(find.byType(FirstStartScreen));
          expect(Theme.of(context).brightness, brightness);
          expect(
            tester.widget<Scaffold>(find.byType(Scaffold)).backgroundColor,
            context.tokens.bg,
          );
          expect(
            find.byKey(
              Key(offline ? 'first-start-local' : 'first-animus-sign-in'),
            ),
            findsOneWidget,
          );
          expect(find.byType(AlkionBrandLockup), findsOneWidget);
          _completeParagraphs(tester);
        }
      }
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'first-start choices and interrupted copy stay complete in four locales, light/dark, 320dp/2x',
    (tester) async {
      _narrow(tester);
      final digest = List.filled(64, 'a').join();
      final service = RestoreService(Directory('/synthetic-unopened-target'));
      final states = [
        const FreshRestoreState(canStartLocal: true),
        FreshRestoreState(
          canStartLocal: false,
          pending: PendingRestore('rs-synthetic', {
            'backup': {'container_sha256': digest},
          }),
        ),
        FreshRestoreState(
          canStartLocal: false,
          pending: PendingRestore('rs-synthetic', {
            'backup': {'container_sha256': digest},
            'staged': <String, Object?>{},
          }),
        ),
      ];
      for (final brightness in Brightness.values) {
        for (final locale in ['en', 'de', 'es', 'it']) {
          for (var i = 0; i < states.length; i++) {
            final state = states[i];
            await tester.pumpWidget(
              _app(
                FirstStartScreen(
                  key: ValueKey('$brightness-$locale-$i'),
                  service: service,
                  state: state,
                  documents: FakeDocuments(Directory.systemTemp),
                  startLocal: () async {
                    fail('Layout must not start a profile');
                  },
                  relaunch: () async {
                    fail('Layout must not relaunch');
                  },
                ),
                locale: locale,
                brightness: brightness,
              ),
            );
            await tester.pump();
            expect(find.byType(AlkionBrandLockup), findsOneWidget);
            expect(find.text('Alkion'), findsOneWidget);
            expect(find.text('by Animus'), findsOneWidget);
            if (state.canStartLocal) {
              expect(
                find.byKey(const Key('first-animus-sign-in')),
                findsOneWidget,
              );
              expect(
                find.byKey(const Key('first-animus-sign-up')),
                findsOneWidget,
              );
              expect(find.byKey(const Key('first-go-offline')), findsOneWidget);
              expect(find.byKey(const Key('first-restore')), findsNothing);
              _completeParagraphs(tester);
              await openOfflineChoices(tester);
            }
            expect(
              find.byKey(const Key('first-start-local')),
              state.canStartLocal ? findsOneWidget : findsNothing,
            );
            final action = find.byKey(
              Key(
                state.canComplete ? 'first-restore-complete' : 'first-restore',
              ),
            );
            expect(action, findsOneWidget);
            if (state.pending != null) {
              expect(find.text('SHA-256 $digest'), findsOneWidget);
            }
            _completeParagraphs(tester);
            await tester.ensureVisible(action);
            await tester.pump();
            expect(
              tester
                  .getRect(action)
                  .overlaps(const Rect.fromLTWH(0, 0, 320, 760)),
              isTrue,
            );
          }
        }
      }
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'cancel keeps the empty installation; local busy/error permits a deliberate retry',
    (tester) async {
      _narrow(tester);
      late Directory temp;
      await tester.runAsync(() async {
        temp = await Directory.systemTemp.createTemp('alkion-first-ui-');
      });
      final root = Directory('${temp.path}/${AlkionIdentity.applicationId}');
      final service = RestoreService(root);
      final documents = FakeDocuments(temp);
      final gate = Completer<void>();
      var localCalls = 0;
      var relaunches = 0;
      await tester.pumpWidget(
        _app(
          FirstStartScreen(
            service: service,
            state: const FreshRestoreState(canStartLocal: true),
            documents: documents,
            startLocal: () async {
              localCalls++;
              await gate.future;
              throw StateError('synthetic_local_failure');
            },
            relaunch: () async {
              relaunches++;
            },
          ),
        ),
      );
      await tester.pump();
      await openOfflineChoices(tester);
      final restore = find.byKey(const Key('first-restore'));
      await tester.ensureVisible(restore);
      await tester.tap(restore);
      await firstActionReady(tester);
      expect(documents.opens, 1);
      expect(localCalls, 0);
      expect(relaunches, 0);
      expect(root.existsSync(), isFalse);
      expect(tester.widget<OutlinedButton>(restore).onPressed, isNotNull);
      final local = find.byKey(const Key('first-start-local'));
      await tester.ensureVisible(local);
      await tester.tap(local);
      for (var i = 0; i < 100 && localCalls == 0; i++) {
        await settleReal(tester, ticks: 1);
      }
      expect(localCalls, 1);
      expect(tester.widget<FilledButton>(local).onPressed, isNull);
      expect(tester.widget<OutlinedButton>(restore).onPressed, isNull);
      gate.complete();
      for (
        var i = 0;
        i < 100 && tester.widget<FilledButton>(local).onPressed == null;
        i++
      ) {
        await settleReal(tester, ticks: 1);
      }
      final l = AppLocalizations.of(
        tester.element(find.byType(FirstStartScreen)),
      );
      final failure = find.text(
        l.alkionRestoreFailedBody('Bad state: synthetic_local_failure'),
      );
      expect(failure, findsOneWidget);
      await tester.ensureVisible(failure);
      _completeParagraphs(tester);
      expect(tester.widget<FilledButton>(local).onPressed, isNotNull);
      expect(tester.widget<OutlinedButton>(restore).onPressed, isNotNull);
      expect(localCalls, 1);
      expect(relaunches, 0);
      expect(root.existsSync(), isFalse);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() => temp.delete(recursive: true));
    },
  );
  testWidgets(
    'offline transition waits for abandonment, Back returns, and picker cancellation stays offline',
    (tester) async {
      _narrow(tester);
      final gate = Completer<void>();
      var abandoned = 0, started = 0, prepared = 0;
      late Directory temp;
      await tester.runAsync(() async {
        temp = await Directory.systemTemp.createTemp('alkion-entry-choices-');
      });
      addTearDown(() => temp.delete(recursive: true));
      final root = Directory('${temp.path}/${AlkionIdentity.applicationId}');
      final documents = FakeDocuments(temp);
      await tester.pumpWidget(
        _app(
          FirstStartScreen(
            service: RestoreService(root),
            state: const FreshRestoreState(canStartLocal: true),
            documents: documents,
            prepareConnection: () async {
              prepared++;
              return AnimusConnectionController();
            },
            abandonAuthentication: () async {
              abandoned++;
              await gate.future;
            },
            startLocal: () async {
              started++;
            },
            relaunch: () async {
              fail('Cancel must not relaunch');
            },
          ),
        ),
      );
      await tester.pump();
      final offline = find.byKey(const Key('first-go-offline'));
      await tester.ensureVisible(offline);
      await tester.tap(offline);
      await tester.pump();
      expect(abandoned, 1);
      expect(prepared, 0);
      expect(started, 0);
      expect(find.byKey(const Key('first-start-local')), findsNothing);
      gate.complete();
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const Key('first-start-local')), findsOneWidget);
      await tester.ensureVisible(find.byKey(const Key('first-restore')));
      await tester.tap(find.byKey(const Key('first-restore')));
      await firstActionReady(tester);
      expect(documents.opens, 1);
      expect(root.existsSync(), isFalse);
      expect(find.byKey(const Key('first-start-local')), findsOneWidget);
      expect(find.byKey(const Key('first-animus-sign-in')), findsNothing);
      await tester.ensureVisible(find.byKey(const Key('first-offline-back')));
      await tester.tap(find.byKey(const Key('first-offline-back')));
      await tester.pump();
      expect(find.byKey(const Key('first-animus-sign-in')), findsOneWidget);
      expect(find.byKey(const Key('first-restore')), findsNothing);
      expect(started, 0);
      await openOfflineChoices(tester);
      await tester.binding.handlePopRoute();
      await tester.pump();
      expect(find.byKey(const Key('first-animus-sign-in')), findsOneWidget);
      expect(started, 0);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'account confirmation is explicit and readable in all locales and themes',
    (tester) async {
      _narrow(tester);
      for (final locale in ['en', 'de', 'es', 'it']) {
        for (final brightness in Brightness.values) {
          final auth = _EntryAuth(), probe = _EntryProbe();
          final c = AnimusConnectionController(
            config: syntheticAnimusConfig(),
            auth: auth,
            probe: probe,
          );
          var prepared = 0, confirmations = 0;
          await tester.pumpWidget(
            _app(
              FirstStartScreen(
                key: ValueKey('confirm-$locale-$brightness'),
                service: RestoreService(
                  Directory('/synthetic-unopened-entry-target'),
                ),
                state: const FreshRestoreState(canStartLocal: true),
                entryConfig: syntheticAnimusConfig(),
                prepareConnection: () async {
                  prepared++;
                  return c;
                },
                abandonAuthentication: c.cancel,
                confirmConnection: () async {
                  confirmations++;
                  await c.confirm();
                },
                startLocal: () async {
                  fail('Sign-in must not choose offline');
                },
                relaunch: () async {},
              ),
              locale: locale,
              brightness: brightness,
            ),
          );
          await tester.pump();
          expect(prepared, 0);
          expect(auth.authorizations, 0);
          expect(find.byType(TextField), findsNothing);
          final signIn = find.byKey(const Key('first-animus-sign-in'));
          await tester.ensureVisible(signIn);
          await tester.tap(signIn);
          await tester.pumpAndSettle();
          expect(prepared, 1);
          expect(auth.authorizations, 1);
          expect(auth.intent, AnimusAuthIntent.signIn);
          expect(auth.retains, 0);
          expect(probe.calls, 0);
          expect(
            find.textContaining('synthetic-entry-subject'),
            findsOneWidget,
          );
          expect(
            find.text(syntheticAnimusConfig().dataSpaceId),
            findsOneWidget,
          );
          expect(
            find.text('synthetic-credential-never-displayed'),
            findsNothing,
          );
          final confirm = find.byKey(const Key('first-animus-confirm'));
          await tester.ensureVisible(confirm);
          _completeParagraphs(tester);
          await tester.tap(confirm);
          await tester.pumpAndSettle();
          expect(confirmations, 1);
          expect(auth.retains, 1);
          expect(probe.calls, 1);
          await tester.pumpWidget(const SizedBox());
          c.dispose();
        }
      }
    },
  );

  testWidgets(
    'pending browser login keeps offline available and fences late completion',
    (tester) async {
      _narrow(tester);
      final auth = _EntryAuth()..pending = Completer<AnimusAuthSession?>();
      final probe = _EntryProbe();
      final c = AnimusConnectionController(
        config: syntheticAnimusConfig(),
        auth: auth,
        probe: probe,
      );
      await tester.pumpWidget(
        _app(
          FirstStartScreen(
            service: RestoreService(
              Directory('/synthetic-unopened-entry-target'),
            ),
            state: const FreshRestoreState(canStartLocal: true),
            entryConfig: syntheticAnimusConfig(),
            prepareConnection: () async => c,
            abandonAuthentication: c.cancel,
            startLocal: () async {},
            relaunch: () async {},
          ),
        ),
      );
      await tester.pump();
      await tester.ensureVisible(find.byKey(const Key('first-animus-sign-in')));
      await tester.tap(find.byKey(const Key('first-animus-sign-in')));
      await tester.pump();
      expect(c.busy, isTrue);
      expect(
        tester
            .widget<TextButton>(find.byKey(const Key('first-go-offline')))
            .onPressed,
        isNotNull,
      );
      await openOfflineChoices(tester);
      auth.pending!.complete(_entrySession());
      await tester.pumpAndSettle();
      expect(c.identity, isNull);
      expect(find.byKey(const Key('first-start-local')), findsOneWidget);
      expect(auth.retains, 0);
      expect(probe.calls, 0);
      await tester.pumpWidget(const SizedBox());
      c.dispose();
    },
  );
  testWidgets(
    'confirmation locks offline, cancellation and Back until persistence finishes',
    (tester) async {
      _narrow(tester);
      final auth = _EntryAuth(), probe = _EntryProbe();
      final c = AnimusConnectionController(
        config: syntheticAnimusConfig(),
        auth: auth,
        probe: probe,
      );
      final gate = Completer<void>();
      var abandoned = 0;
      await tester.pumpWidget(
        _app(
          FirstStartScreen(
            service: RestoreService(
              Directory('/synthetic-unopened-entry-target'),
            ),
            state: const FreshRestoreState(canStartLocal: true),
            entryConfig: syntheticAnimusConfig(),
            prepareConnection: () async => c,
            abandonAuthentication: () async {
              abandoned++;
              await c.cancel();
            },
            confirmConnection: () async {
              await gate.future;
              await c.confirm();
            },
            startLocal: () async {},
            relaunch: () async {},
          ),
        ),
      );
      await tester.pump();
      await tester.ensureVisible(find.byKey(const Key('first-animus-sign-in')));
      await tester.tap(find.byKey(const Key('first-animus-sign-in')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('first-animus-confirm')));
      await tester.tap(find.byKey(const Key('first-animus-confirm')));
      await tester.pump();
      expect(
        tester
            .widget<TextButton>(find.byKey(const Key('first-go-offline')))
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<TextButton>(find.byKey(const Key('first-animus-cancel')))
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('first-animus-confirm')))
            .onPressed,
        isNull,
      );
      await tester.binding.handlePopRoute();
      await tester.pump();
      expect(find.byKey(const Key('first-animus-confirm')), findsOneWidget);
      expect(find.byKey(const Key('first-start-local')), findsNothing);
      expect(abandoned, 0);
      expect(auth.retains, 0);
      gate.complete();
      await tester.pumpAndSettle();
      expect(auth.retains, 1);
      expect(probe.calls, 1);
      await tester.pumpWidget(const SizedBox());
      c.dispose();
    },
  );

  testWidgets(
    'configured signup uses create-account intent; unconfigured setup is explicit',
    (tester) async {
      _narrow(tester);
      final semantics = tester.ensureSemantics();
      final config = AnimusConfig.fromEnvironment(
        syntheticAnimusValues()
          ..['ALKION_ANIMUS_ENROLLMENT_FLOW'] = 'synthetic-enrollment',
        platform: AnimusPlatform.linux,
      )!;
      final auth = _EntryAuth(), probe = _EntryProbe();
      final c = AnimusConnectionController(
        config: config,
        auth: auth,
        probe: probe,
      );
      await tester.pumpWidget(
        _app(
          FirstStartScreen(
            service: RestoreService(
              Directory('/synthetic-unopened-entry-target'),
            ),
            state: const FreshRestoreState(canStartLocal: true),
            entryConfig: config,
            prepareConnection: () async => c,
            abandonAuthentication: c.cancel,
            startLocal: () async {},
            relaunch: () async {},
          ),
        ),
      );
      await tester.pump();
      final signup = find.byKey(const Key('first-animus-sign-up'));
      await tester.ensureVisible(signup);
      expect(
        tester.getSemantics(signup).label,
        'Don’t have an account? Join now',
      );
      expect(find.text('Don’t have an account?'), findsNothing);
      // The leading sentence belongs to the same action as “Join now”.
      final target = tester.getRect(signup);
      await tester.tapAt(Offset(target.left + 24, target.center.dy));
      await tester.pumpAndSettle();
      expect(auth.intent, AnimusAuthIntent.createAccount);
      expect(auth.retains, 0);
      expect(probe.calls, 0);
      await tester.pumpWidget(const SizedBox());
      c.dispose();
      await tester.pumpWidget(
        _app(
          FirstStartScreen(
            service: RestoreService(
              Directory('/synthetic-unopened-entry-target'),
            ),
            state: const FreshRestoreState(canStartLocal: true),
            entryMisconfigured: true,
            startLocal: () async {},
            relaunch: () async {},
          ),
        ),
      );
      await tester.pump();
      expect(
        find.text('Animus setup is unavailable. Local workouts are available.'),
        findsOneWidget,
      );
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('first-animus-sign-in')))
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<TextButton>(find.byKey(const Key('first-animus-sign-up')))
            .onPressed,
        isNull,
      );
      await openOfflineChoices(tester);
      expect(find.byKey(const Key('first-start-local')), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      semantics.dispose();
    },
  );

  testWidgets(
    'normal phone entry keeps the offline action near the safe bottom',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          FakeAccessibilityFeatures.allOn;
      addTearDown(tester.view.reset);
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      await tester.pumpWidget(
        _app(
          FirstStartScreen(
            service: RestoreService(
              Directory('/synthetic-unopened-entry-target'),
            ),
            state: const FreshRestoreState(canStartLocal: true),
            startLocal: () async {},
            relaunch: () async {},
          ),
        ),
      );
      await tester.pump();
      final rect = tester.getRect(find.byKey(const Key('first-go-offline')));
      expect(rect.bottom, greaterThan(740));
      expect(rect.bottom, lessThan(824));
      _completeParagraphs(tester);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'published profile can continue offline after secret retention fails without fresh restore choices',
    (tester) async {
      _narrow(tester);
      final auth = _EntryAuth()
        ..retainFailure = const AnimusSecretStoreUnavailable();
      var published = false, continued = 0, abandoned = 0;
      final probe = _EntryProbe();
      final c = AnimusConnectionController(
        config: syntheticAnimusConfig(),
        auth: auth,
        probe: probe,
        beforeRetain: () async {
          published = true;
        },
      );
      await tester.pumpWidget(
        _app(
          FirstStartScreen(
            service: RestoreService(
              Directory('/synthetic-unopened-entry-target'),
            ),
            state: const FreshRestoreState(canStartLocal: true),
            entryConfig: syntheticAnimusConfig(),
            prepareConnection: () async => c,
            confirmConnection: c.confirm,
            hasLocalProfile: () => published,
            continueOffline: () async {
              continued++;
              await c.cancel();
            },
            abandonAuthentication: () async {
              abandoned++;
            },
            startLocal: () async {
              fail('Published profile must not start fresh');
            },
            relaunch: () async {},
          ),
        ),
      );
      await tester.pump();
      await tester.ensureVisible(find.byKey(const Key('first-animus-sign-in')));
      await tester.tap(find.byKey(const Key('first-animus-sign-in')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('first-animus-confirm')));
      await tester.tap(find.byKey(const Key('first-animus-confirm')));
      await tester.pumpAndSettle();
      expect(published, isTrue);
      expect(probe.calls, 0);
      expect(find.text('Continue offline'), findsOneWidget);
      final offline = find.byKey(const Key('first-go-offline'));
      await tester.ensureVisible(offline);
      await tester.tap(offline);
      await tester.pumpAndSettle();
      expect(continued, 1);
      expect(abandoned, 0);
      expect(find.byKey(const Key('first-start-local')), findsNothing);
      expect(find.byKey(const Key('first-restore')), findsNothing);
      await tester.pumpWidget(const SizedBox());
      c.dispose();
    },
  );
}

AnimusAuthSession _entrySession() => AnimusAuthSession(
  identity: AnimusIdentity(
    issuer: syntheticAnimusConfig().issuer,
    subject: 'synthetic-entry-subject',
    displayName: 'Synthetic entry account',
  ),
  accessToken: 'synthetic-credential-never-displayed',
  expiresAt: DateTime.utc(2100),
);

class _EntryAuth implements AnimusAuthPort {
  int authorizations = 0, retains = 0;
  Object? retainFailure;
  AnimusAuthIntent? intent;
  Completer<AnimusAuthSession?>? pending;
  @override
  Future<AnimusAuthSession?> authorize({
    AnimusAuthIntent intent = AnimusAuthIntent.signIn,
  }) async {
    authorizations++;
    this.intent = intent;
    return pending == null ? _entrySession() : pending!.future;
  }

  @override
  Future<void> retain(AnimusAuthSession session) async {
    retains++;
    if (retainFailure != null) throw retainFailure!;
  }

  @override
  Future<AnimusAuthSession?> restore() async => null;
  @override
  Future<AnimusAuthSession?> refresh() async => null;
  @override
  Future<void> disconnect() async {}
  @override
  Future<void> cancel() async {}
  @override
  Future<void> close() async {}
}

class _EntryProbe implements AnimusProbePort {
  int calls = 0;
  @override
  Future<AnimusProbeResult> verify(AnimusAuthSession session) async {
    calls++;
    return AnimusProbeResult.verified;
  }

  @override
  Future<void> cancel() async {}
  @override
  Future<void> close() async {}
}
