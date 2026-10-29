import 'dart:async';

import 'package:alkion/animus/adapters/auth.dart';
import 'package:alkion/animus/connection.dart';
import 'package:alkion/animus/contracts.dart';
import 'package:alkion/animus/ports.dart';
import 'package:alkion/animus/probe.dart';
import 'package:alkion/l10n/app_localizations.dart';
import 'package:alkion/theme/app_theme.dart';
import 'package:alkion/theme/tokens.dart';
import 'package:alkion/ui/animus_connection_panel.dart';
import 'package:alkion/ui/profile_screen.dart';
import 'package:alkion/ui/training_preferences_sheet.dart';
import 'package:alkion/settings/settings_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import '../support/screen_harness.dart';
import 'support.dart';

void main() {
  Widget panel(
    AnimusConnectionController? connection, {
    String locale = 'en',
    Brightness brightness = Brightness.dark,
  }) => ChangeNotifierProvider<AnimusConnectionController?>.value(
    value: connection,
    child: MaterialApp(
      theme: buildTheme(brightness, accents[0]),
      locale: Locale(locale),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: const Scaffold(
        body: SingleChildScrollView(child: AnimusConnectionPanel()),
      ),
    ),
  );

  testWidgets('absent and disabled connection leave local Profile unchanged', (
    tester,
  ) async {
    final harness = ScreenHarness();
    addTearDown(harness.close);
    await harness.open(tester);
    await tester.pumpWidget(harness.wrap(ProfileScreen(onClose: () {})));
    await settleReal(tester);
    expect(find.byKey(const Key('animus-connection-panel')), findsNothing);
    await scrollIntoView(
      tester,
      find.byType(ProfileScreen),
      find.byKey(const Key('profile-data-actions')),
    );
    expect(find.byKey(const Key('profile-data-actions')), findsOneWidget);
    await harness.unmount(tester);
    final disabled = AnimusConnectionController();
    await tester.pumpWidget(panel(disabled));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('animus-connection-panel')), findsNothing);
    await tester.pumpWidget(const SizedBox());
    disabled.dispose();
  });

  testWidgets(
    'Profile keeps training preferences and optional connection usable together',
    (tester) async {
      final harness = ScreenHarness();
      addTearDown(harness.close);
      await harness.open(tester);
      final auth = _Auth(), probe = _Probe();
      final connection = AnimusConnectionController(
        config: syntheticAnimusConfig(),
        auth: auth,
        probe: probe,
      );
      addTearDown(connection.dispose);
      await tester.pumpWidget(
        harness.wrap(
          ProfileScreen(onClose: () {}),
          extra: [
            ChangeNotifierProvider<AnimusConnectionController?>.value(
              value: connection,
            ),
          ],
        ),
      );
      await settleReal(tester);
      final host = find.byType(ProfileScreen);
      await scrollIntoView(tester, host, find.text('Training preferences'));
      await tester.tap(find.text('Training preferences').last);
      await settleReal(tester);
      expect(find.byType(TrainingPreferencesSheet), findsOneWidget);
      await tester.tap(find.text('Rep range'));
      await settleReal(tester);
      expect(harness.settings.repEntry, RepEntry.range);
      await tester.binding.handlePopRoute();
      await settleReal(tester);
      expect(find.byType(TrainingPreferencesSheet), findsNothing);
      await scrollIntoView(tester, host, find.text('Connect to Animus'));
      expect(find.byKey(const Key('animus-connection-panel')), findsOneWidget);
      expect(find.text('Connect to Animus'), findsOneWidget);
      expect(auth.calls, 0);
      expect(probe.calls, 0);
      await harness.unmount(tester);
    },
  );

  testWidgets(
    'account and space must be confirmed before retain or API read; disconnect is local',
    (tester) async {
      final auth = _Auth(), probe = _Probe();
      final controller = AnimusConnectionController(
        config: syntheticAnimusConfig(),
        auth: auth,
        probe: probe,
      );
      addTearDown(controller.dispose);
      await tester.pumpWidget(panel(controller));
      await tester.pumpAndSettle();
      expect(auth.calls, 0);
      expect(probe.calls, 0);
      await tester.tap(find.text('Connect to Animus'));
      await tester.pumpAndSettle();
      expect(
        find.text('Signed in. Confirm the account and data space.'),
        findsOneWidget,
      );
      expect(
        find.textContaining(
          'https://identity.example.test/application/o/alkion/',
        ),
        findsOneWidget,
      );
      expect(find.textContaining('synthetic-subject'), findsOneWidget);
      expect(find.text(syntheticAnimusConfig().dataSpaceId), findsOneWidget);
      expect(auth.retains, 0);
      expect(probe.calls, 0);
      await tester.tap(find.text('Confirm account and space'));
      await tester.pumpAndSettle();
      expect(auth.retains, 1);
      expect(probe.calls, 1);
      expect(find.text('Workout read access verified.'), findsOneWidget);
      expect(
        find.textContaining('does not upload or synchronize'),
        findsOneWidget,
      );
      await tester.ensureVisible(find.text('Disconnect'));
      await tester.tap(find.text('Disconnect'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining(
          'Local workouts, drafts, pending changes and backups are kept.',
        ),
        findsOneWidget,
      );
      await tester.tap(find.text('Disconnect').last);
      await tester.pumpAndSettle();
      expect(controller.state, AnimusConnectionState.disconnected);
      expect(probe.calls, 1);
      expect(find.byKey(const Key('animus-account-identity')), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('cancel pending browser login does not show verified access', (
    tester,
  ) async {
    final auth = _Auth()..pending = Completer<AnimusAuthSession?>();
    final controller = AnimusConnectionController(
      config: syntheticAnimusConfig(),
      auth: auth,
      probe: _Probe(),
    );
    addTearDown(controller.dispose);
    await tester.pumpWidget(panel(controller));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Connect to Animus'));
    await tester.pump();
    expect(find.text('Opening sign-in in your browser…'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    auth.pending!.complete(_session());
    await tester.pumpAndSettle();
    expect(controller.state, AnimusConnectionState.cancelled);
    expect(auth.retains, 0);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('narrow large-text states fit all locales and both themes', (
    tester,
  ) async {
    setPhone(tester, width: 320, textScale: 2);
    for (final locale in ['en', 'de', 'es', 'it']) {
      for (final brightness in Brightness.values) {
        final pendingAuth = _Auth()..pending = Completer<AnimusAuthSession?>();
        final signingIn = AnimusConnectionController(
          config: syntheticAnimusConfig(),
          auth: pendingAuth,
          probe: _Probe(),
        );
        final login = signingIn.connect();
        await tester.pumpWidget(
          panel(signingIn, locale: locale, brightness: brightness),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await signingIn.cancel();
        pendingAuth.pending!.complete(null);
        await login;
        await tester.pumpWidget(const SizedBox());
        signingIn.dispose();

        for (final result in [null, ...AnimusProbeResult.values]) {
          final auth = _Auth(),
              probe = _Probe()..result = result ?? AnimusProbeResult.verified;
          final controller = AnimusConnectionController(
            config: syntheticAnimusConfig(),
            auth: auth,
            probe: probe,
          );
          await controller.connect();
          if (result != null) await controller.confirm();
          await tester.pumpWidget(
            panel(controller, locale: locale, brightness: brightness),
          );
          await tester.pumpAndSettle();
          expect(
            tester.takeException(),
            isNull,
            reason: '$locale $brightness $result',
          );
          for (final button in tester.widgetList<TextButton>(
            find.byType(TextButton),
          )) {
            expect(
              button.style!.minimumSize!.resolve({})!.height,
              greaterThanOrEqualTo(48),
            );
          }
          await tester.pumpWidget(const SizedBox());
          controller.dispose();
        }
        for (final failure in [
          const AnimusSecretStoreUnavailable(),
          ...AnimusAuthFailureKind.values.map(AnimusAuthFailure.new),
        ]) {
          final controller = AnimusConnectionController(
            config: syntheticAnimusConfig(),
            auth: _Auth()..failure = failure,
            probe: _Probe(),
          );
          await controller.connect();
          await tester.pumpWidget(
            panel(controller, locale: locale, brightness: brightness),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
          controller.dispose();
        }
        final invalid = AnimusConnectionController(misconfigured: true);
        await tester.pumpWidget(
          panel(invalid, locale: locale, brightness: brightness),
        );
        await tester.pumpAndSettle();
        expect(find.byType(TextButton), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        invalid.dispose();
      }
    }
  });
}

AnimusAuthSession _session() => AnimusAuthSession(
  identity: AnimusIdentity(
    issuer: syntheticAnimusConfig().issuer,
    subject: 'synthetic-subject',
    displayName: 'Synthetic workout account',
  ),
  accessToken: 'synthetic-never-displayed',
  expiresAt: DateTime.utc(2100),
);

class _Auth implements AnimusAuthPort {
  int calls = 0, retains = 0;
  Completer<AnimusAuthSession?>? pending;
  Object? failure;
  @override
  Future<AnimusAuthSession?> authorize({
    AnimusAuthIntent intent = AnimusAuthIntent.signIn,
  }) async {
    calls++;
    if (failure != null) throw failure!;
    return pending == null ? _session() : pending!.future;
  }

  @override
  Future<AnimusAuthSession?> restore() => authorize();
  @override
  Future<AnimusAuthSession?> refresh() => authorize();
  @override
  Future<void> retain(AnimusAuthSession session) async {
    retains++;
  }

  @override
  Future<void> disconnect() async {
    calls++;
  }

  @override
  Future<void> cancel() async {
    calls++;
  }

  @override
  Future<void> close() async {
    calls++;
  }
}

class _Probe implements AnimusProbePort {
  int calls = 0;
  AnimusProbeResult result = AnimusProbeResult.verified;
  @override
  Future<AnimusProbeResult> verify(AnimusAuthSession session) async {
    calls++;
    return result;
  }

  @override
  Future<void> cancel() async {}
  @override
  Future<void> close() async {}
}
