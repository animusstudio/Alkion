import 'package:alkion/animus/ports.dart';
import 'package:alkion/animus/remote_recovery_repository.dart';
import 'package:alkion/store/local_store.dart';

/// Explicit injection for dated definition/schema-5 transport fixtures only.
/// This makes no recovery claim and is never imported by application code.
final class HistoricalRecoveryFixture implements AnimusRecoveryPort {
  const HistoricalRecoveryFixture({this.probeOnly = false});
  final bool probeOnly;
  @override
  bool get preflightSelection => false;
  @override
  Future<void> checkReady() async {}
  @override
  Future<void> prepareSelectionTx(
    LocalTransaction tx,
    Iterable<String> operations,
  ) async {}
  @override
  Future<AnimusHttpResponse> discover(
    Future<AnimusHttpResponse> Function(Map<String, String>) send,
    bool Function() current,
  ) async => probeOnly
      ? AnimusHttpResponse(
          statusCode: 200,
          headers: const {'content-type': 'application/json'},
          body: const [],
        )
      : send(const {});
  @override
  Future<AnimusHttpResponse> exchange(
    RemoteApiRequest request,
    Future<AnimusHttpResponse> Function(Map<String, String>) send,
    bool Function() current,
    void Function(AnimusHttpResponse) validate,
  ) => send(const {});
}
