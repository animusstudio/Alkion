import 'package:alkion/animus/config.dart';
import 'package:flutter_test/flutter_test.dart';

// This expectation is independent of the transport flag under test. The opt-in
// runs compile the setup fixture through Flutter's actual --dart-define path.
const _expected = String.fromEnvironment(
  'ANIMUS_PRIVATE_HTTP_COMPILE_EXPECTATION',
  defaultValue: 'disabled',
);

void main() {
  test(
    'runtime constructor honors actual compiler setup and transport opt-in',
    () {
      switch (_expected) {
        case 'enabled':
          final config = AnimusConfig.fromCompileTime(
            platform: AnimusPlatform.android,
          );
          expect(config, isNotNull);
          expect(config!.allowPrivateHttp, isTrue);
          expect(config.allowLoopbackHttp, isFalse);
          expect(config.apiOrigin.toString(), 'http://api.example.test:8080');
          expect(
            config.issuer.toString(),
            'http://identity.example.test:9090/application/o/alkion/',
          );
          expect(
            config.redirectUri.toString(),
            'dev.animusstudio.alkion.dev:/oauth2redirect',
          );
        case 'rejected':
          expect(
            () =>
                AnimusConfig.fromCompileTime(platform: AnimusPlatform.android),
            throwsA(isA<AnimusConfigException>()),
          );
        case 'disabled':
          expect(
            AnimusConfig.fromCompileTime(platform: AnimusPlatform.android),
            isNull,
          );
        default:
          fail('Unknown compiler regression expectation');
      }
    },
  );
}
