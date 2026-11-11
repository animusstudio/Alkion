import 'dart:convert';
import 'dart:io';

import 'package:alkion/identity/alkion_identity.dart';
import 'package:alkion/main.dart' show checkedAlkionSupportRoot;
import 'package:alkion/session/notification_envelope.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

const _intentId = '0b7d2a1e-3c4f-4a5b-8c6d-7e8f9a0b1c2d';

NotificationAction _action({String profile = 'synthetic-profile'}) =>
    NotificationAction(
      applicationId: AlkionIdentity.applicationId,
      profileId: profile,
      generation: 2,
      draftId: 'synthetic-draft',
      restStart: '2026-06-03T10:29:30.000',
      timerRevision: 3,
      token: 'issued-synthetic-token',
    );

NotificationView _view({
  String title = 'Upper A',
  String restBody = 'Next · Bench Press',
  String elapsedBody = 'Next · Bench Press',
  String? locale = 'en',
}) => NotificationView(
  title: title,
  restBody: restBody,
  elapsedBody: elapsedBody,
  startedAt: DateTime.utc(2026, 6, 3, 10, 0, 0, 0, 7),
  restStart: DateTime.utc(2026, 6, 3, 10, 29, 30, 123, 456),
  restTotal: 90,
  locale: locale,
);

int _bytes(String value) => utf8.encode(value).length;

/// No code unit of [value] is half of a surrogate pair on its own.
bool _wellFormed(String value) =>
    value.runes.every((rune) => rune < 0xD800 || rune > 0xDFFF);

/// Repeats [unit] after [prefix] up to the longest view title whose payload
/// still fits.
String _titleAtBoundary(NotificationAction action, String prefix, String unit) {
  var title = prefix;
  while (true) {
    final next = '$title$unit';
    final payload = NotificationEnvelope(
      action: action,
      step: 1,
      view: _view(title: next),
    ).encode();
    if (payload == null) return title;
    title = next;
  }
}

void main() {
  group('NotificationAction', () {
    test('the bare token keeps its exact historical encoding', () {
      final action = _action();
      expect(jsonDecode(action.encode()), {
        'format': 'alkion-notification-action/1',
        'application_id': AlkionIdentity.applicationId,
        'profile_id': 'synthetic-profile',
        'generation': 2,
        'draft_id': 'synthetic-draft',
        'rest_start': '2026-06-03T10:29:30.000',
        'timer_revision': 3,
        'token': 'issued-synthetic-token',
      });
      expect(
        NotificationAction.decode(action.encode())!.encode(),
        action.encode(),
      );
      expect(
        NotificationAction.fromJson(action.toJson())!.encode(),
        action.encode(),
      );
    });

    test('decode refuses malformed tokens', () {
      final json = _action().toJson();
      for (final broken in <Map<String, Object?>>[
        {...json, 'extra': 1},
        {...json, 'format': 'alkion-notification-payload/1'},
        {...json, 'generation': 0},
        {...json, 'timer_revision': 0},
        {...json, 'token': ''},
        {...json, 'draft_id': 'x' * 257},
        {...json, 'rest_start': 'not a time'},
      ]) {
        expect(NotificationAction.decode(jsonEncode(broken)), isNull);
      }
      expect(NotificationAction.decode(null), isNull);
      expect(NotificationAction.decode('[]'), isNull);
      expect(NotificationAction.fromJson('text'), isNull);
    });
  });

  group('NotificationEnvelope', () {
    test('round-trips the action, step and view', () {
      final envelope = NotificationEnvelope(
        action: _action(),
        step: 3,
        view: _view(locale: null),
      );
      final payload = envelope.encode()!;
      final json = jsonDecode(payload) as Map;
      expect(json.keys, {'format', 'action', 'step', 'view'});
      expect(json['format'], 'alkion-notification-payload/1');
      expect(json['action'], _action().toJson());
      final decoded = NotificationEnvelope.decode(payload)!;
      expect(decoded.action.encode(), _action().encode());
      expect(decoded.step, 3);
      final view = decoded.view!;
      expect(view.title, 'Upper A');
      expect(view.restBody, 'Next · Bench Press');
      expect(view.elapsedBody, 'Next · Bench Press');
      expect(view.startedAt, DateTime.utc(2026, 6, 3, 10, 0, 0, 0, 7));
      expect(view.restStart, DateTime.utc(2026, 6, 3, 10, 29, 30, 123, 456));
      expect(view.restTotal, 90);
      expect(view.locale, isNull);
      expect(decoded.encode(), payload);
    });

    test('a local time is carried as the same instant in UTC', () {
      final local = DateTime(2026, 6, 3, 10, 0);
      final view = NotificationEnvelope.decode(
        NotificationEnvelope(
          action: _action(),
          step: 1,
          view: NotificationView(
            title: 't',
            restBody: 'r',
            elapsedBody: 'e',
            startedAt: local,
          ),
        ).encode(),
      )!.view!;
      expect(view.startedAt.isUtc, isTrue);
      expect(
        view.startedAt.microsecondsSinceEpoch,
        local.microsecondsSinceEpoch,
      );
      expect(view.restStart, isNull);
      expect(view.restTotal, 0);
    });

    test('a legacy bare token decodes as step 1 with no view', () {
      final legacy = NotificationEnvelope.decode(_action().encode())!;
      expect(legacy.step, 1);
      expect(legacy.view, isNull);
      expect(legacy.action.encode(), _action().encode());
    });

    test('an envelope without a view decodes with no view', () {
      final payload = NotificationEnvelope(
        action: _action(),
        step: 2,
      ).encode()!;
      expect((jsonDecode(payload) as Map).keys, {'format', 'action', 'step'});
      final decoded = NotificationEnvelope.decode(payload)!;
      expect(decoded.step, 2);
      expect(decoded.view, isNull);
    });

    test('decode refuses malformed envelopes', () {
      final json = NotificationEnvelope(
        action: _action(),
        step: 1,
        view: _view(),
      ).toJson();
      final view = json['view']! as Map<String, Object?>;
      for (final broken in <Map<String, Object?>>[
        {...json, 'step': 0},
        {...json, 'step': '1'},
        {...json, 'extra': 1},
        {...json, 'format': 'alkion-notification-payload/2'},
        {
          ...json,
          'action': {..._action().toJson(), 'token': ''},
        },
        {...json, 'view': null},
        {
          ...json,
          'view': {...view, 'extra': 1},
        },
        {
          ...json,
          'view': {...view, 'rest_total': -1},
        },
        {
          ...json,
          'view': {...view, 'title': 1},
        },
        {
          ...json,
          'view': {...view, 'locale': ''},
        },
        {
          ...json,
          'view': {...view, 'started_at': 'later'},
        },
        {
          ...json,
          'view': {...view, 'started_at': '2026-06-03T10:00:00.000'},
        },
        {
          ...json,
          'view': {...view, 'rest_start': 5},
        },
      ]) {
        expect(
          NotificationEnvelope.decode(jsonEncode(broken)),
          isNull,
          reason: '$broken',
        );
      }
      expect(NotificationEnvelope.decode(null), isNull);
      expect(NotificationEnvelope.decode('{bad'), isNull);
      expect(NotificationEnvelope.decode('"text"'), isNull);
    });

    test('the decoder bound counts UTF-8 bytes, not UTF-16 units', () {
      final action = _action();
      final title = _titleAtBoundary(action, '', 'ü');
      final fits = NotificationEnvelope(
        action: action,
        step: 1,
        view: _view(title: title),
      ).encode()!;
      expect(_bytes(fits), lessThanOrEqualTo(4096));
      expect(NotificationEnvelope.decode(fits), isNotNull);
      final over = jsonEncode(
        NotificationEnvelope(
          action: action,
          step: 1,
          view: _view(title: '$titleü'),
        ).toJson(),
      );
      expect(over.length, lessThan(4096), reason: 'fits in UTF-16 units');
      expect(_bytes(over), greaterThan(4096));
      expect(NotificationEnvelope.decode(over), isNull);
    });

    test('the budget holds exactly at the 4096-byte boundary', () {
      final action = _action();
      final title = _titleAtBoundary(action, '', 'a');
      final exact = NotificationEnvelope(
        action: action,
        step: 1,
        view: _view(title: title),
      );
      expect(_bytes(exact.encode()!), 4096);
      expect(exact.encodeWithinBudget(), exact.encode());
      expect(NotificationEnvelope.decode(exact.encode())!.view!.title, title);

      final over = NotificationEnvelope(
        action: action,
        step: 1,
        view: _view(title: '${title}a'),
      );
      expect(over.encode(), isNull);
      final fitted = over.encodeWithinBudget()!;
      expect(_bytes(fitted), 4096);
      expect(NotificationEnvelope.decode(fitted)!.view!.title, title);
    });

    for (final (language, unit) in [
      ('de', 'Kniebeuge mit Überkopf-Langhantel · Größe '),
      ('es', 'Press de banca inclinado con mancuernas · señal '),
      ('it', 'Rematore con bilanciere · perché più così '),
      ('emoji', '🏋️‍♀️💪🔥'),
    ]) {
      test('a long $language title is shortened on a code point boundary', () {
        final action = _action();
        final longTitle = List.filled(200, unit).join();
        final envelope = NotificationEnvelope(
          action: action,
          step: 4,
          view: _view(
            title: longTitle,
            restBody: 'Next · $unit',
            elapsedBody: 'Next · $unit',
            locale: language == 'emoji' ? 'en' : language,
          ),
        );
        expect(envelope.encode(), isNull);
        final fitted = envelope.encodeWithinBudget()!;
        expect(_bytes(fitted), lessThanOrEqualTo(4096));
        final decoded = NotificationEnvelope.decode(fitted)!;
        expect(decoded.step, 4);
        final title = decoded.view!.title;
        expect(_wellFormed(title), isTrue);
        expect(title, isNotEmpty);
        expect(longTitle.startsWith(title), isTrue);
        // Maximal: one more code point would not fit.
        final runes = longTitle.runes.toList();
        final kept = title.runes.length;
        expect(
          NotificationEnvelope(
            action: action,
            step: 4,
            view: _view(
              title: String.fromCharCodes(runes.take(kept + 1)),
              restBody: 'Next · $unit',
              elapsedBody: 'Next · $unit',
              locale: language == 'emoji' ? 'en' : language,
            ),
          ).encode(),
          isNull,
        );
        expect(decoded.view!.restBody, 'Next · $unit');
      });
    }

    test('a surrogate pair is never split', () {
      final action = _action();
      // Two 4-byte emoji replace the last two bytes of room: neither fits.
      final base = _titleAtBoundary(action, '', 'a');
      final title = '${base.substring(0, base.length - 2)}😀😀';
      final fitted = NotificationEnvelope(
        action: action,
        step: 1,
        view: _view(title: title),
      ).encodeWithinBudget()!;
      final kept = NotificationEnvelope.decode(fitted)!.view!.title;
      expect(_wellFormed(kept), isTrue);
      expect(kept, base.substring(0, base.length - 2));
    });

    test('a title is never shortened to nothing: the view is dropped', () {
      final action = _action();
      // The longest rest body that fits beside an empty title: 4096 bytes.
      var body = '';
      while (NotificationEnvelope(
            action: action,
            step: 1,
            view: _view(title: '', restBody: '${body}a'),
          ).encode() !=
          null) {
        body = '${body}a';
      }
      String? fit(String title, String restBody) => NotificationEnvelope(
        action: action,
        step: 1,
        view: _view(title: title, restBody: restBody),
      ).encodeWithinBudget();
      final full = NotificationEnvelope(
        action: action,
        step: 1,
        view: _view(title: '', restBody: body),
      ).encode()!;
      expect(_bytes(full), 4096);

      // No room for one code point: the view goes, never a blank title.
      final dropped = NotificationEnvelope.decode(fit('abc', body))!;
      expect(dropped.view, isNull);
      // One byte of room: one ASCII code point stays.
      final shortened = fit('abc', body.substring(1))!;
      expect(_bytes(shortened), 4096);
      expect(NotificationEnvelope.decode(shortened)!.view!.title, 'a');
      // One byte of room cannot hold a 4-byte emoji: the view goes.
      expect(
        NotificationEnvelope.decode(fit('😀a', body.substring(1)))!.view,
        isNull,
      );
    });

    test('when shortening the title is not enough, the view is omitted', () {
      final body = 'Ü' * 2100;
      final fitted = NotificationEnvelope(
        action: _action(),
        step: 2,
        view: _view(restBody: body),
      ).encodeWithinBudget()!;
      final decoded = NotificationEnvelope.decode(fitted)!;
      expect(decoded.view, isNull);
      expect(decoded.step, 2);
      expect(decoded.action.encode(), _action().encode());
    });
  });

  group('NotificationIntent', () {
    NotificationIntent intent() => NotificationIntent(
      intentId: _intentId,
      actionId: AlkionIdentity.addRestAction,
      kind: NotificationIntentKind.add,
      tappedAt: DateTime.utc(2026, 6, 3, 10, 30, 0, 1, 2),
      payload: NotificationEnvelope(action: _action(), step: 2, view: _view()),
    );

    test('round-trips its record', () {
      final source = intent().encode();
      final json = jsonDecode(source) as Map;
      expect(json.keys, {
        'format',
        'intent_id',
        'action_id',
        'kind',
        'tapped_at',
        'payload',
      });
      expect(json['format'], 'alkion-notification-intent/1');
      expect(json['kind'], 'add');
      expect(json['tapped_at'], '2026-06-03T10:30:00.001002Z');
      final decoded = NotificationIntent.decode(source)!;
      expect(decoded.intentId, _intentId);
      expect(decoded.actionId, AlkionIdentity.addRestAction);
      expect(decoded.kind, NotificationIntentKind.add);
      expect(decoded.tappedAt, DateTime.utc(2026, 6, 3, 10, 30, 0, 1, 2));
      expect(decoded.payload.step, 2);
      expect(decoded.payload.view!.title, 'Upper A');
      expect(decoded.encode(), source);
      expect(
        NotificationIntentKind.fromWire('skip'),
        NotificationIntentKind.skip,
      );
      expect(NotificationIntentKind.fromWire('stop'), isNull);
    });

    test('decode refuses malformed records', () {
      final json = intent().toJson();
      for (final broken in <Map<String, Object?>>[
        {...json, 'extra': 1},
        {...json, 'format': 'alkion-notification-intent/2'},
        {...json, 'intent_id': '../escape'},
        {...json, 'intent_id': _intentId.toUpperCase()},
        {...json, 'action_id': ''},
        {...json, 'kind': 'stop'},
        {...json, 'tapped_at': '2026-06-03T10:30:00.000'},
        {
          ...json,
          'payload': {'format': 'alkion-notification-payload/1'},
        },
      ]) {
        expect(
          NotificationIntent.decode(jsonEncode(broken)),
          isNull,
          reason: '$broken',
        );
      }
      expect(NotificationIntent.decode('{bad'), isNull);
      expect(NotificationIntent.decode('[]'), isNull);
    });
  });

  group('journal directory and port', () {
    test(
      'the support root matches the owner derivation in main.dart',
      () async {
        final base = p.join(Directory.systemTemp.path, 'synthetic-support');
        for (final supplied in [
          p.join(base, 'files'),
          p.join(base, 'files', ''),
          p.join(base, 'files', AlkionIdentity.applicationId),
          p.join(base, AlkionIdentity.applicationId, 'files'),
        ]) {
          final owner = await checkedAlkionSupportRoot(
            verifyIdentity: () async => null,
            supportDirectory: () async => Directory(supplied),
          );
          final background = notificationSupportRoot(Directory(supplied));
          expect(background.path, owner.path, reason: supplied);
          expect(
            notificationJournalDirectory(background).path,
            notificationJournalDirectory(owner).path,
            reason: supplied,
          );
        }
        expect(
          notificationSupportRoot(Directory(p.join(base, 'files'))).path,
          p.join(base, 'files', AlkionIdentity.applicationId),
        );
      },
    );

    test('the journal is a variant-scoped sibling of the support root', () {
      final files = p.join(Directory.systemTemp.path, 'synthetic-files');
      final root = Directory(p.join(files, AlkionIdentity.applicationId));
      final journal = notificationJournalDirectory(root).path;
      expect(
        journal,
        p.join(files, '.${AlkionIdentity.applicationId}-notification-intents'),
      );
      expect(p.isWithin(root.path, journal), isFalse);
      expect(
        notificationJournalDirectory(Directory('${root.path}/')).path,
        journal,
      );
      expect(
        notificationJournalDirectory(
          Directory(p.join(files, 'x', '..', AlkionIdentity.applicationId)),
        ).path,
        journal,
      );
      expect(
        p.isAbsolute(notificationJournalDirectory(Directory('relative')).path),
        isTrue,
      );
    });

    test('the port name and wake-up message are fixed', () {
      expect(
        notificationPortName,
        '${AlkionIdentity.applicationId}.notification-intents',
      );
      expect(notificationWakeMessage, 'alkion-notification-wake/1');
    });
  });
}
