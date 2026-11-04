import 'dart:convert';

import '../store/local_store.dart';
import 'ports.dart';
import 'remote_recovery_repository.dart';
import 'strict_json.dart';

final class AnimusRecoveryFailure implements Exception {
  const AnimusRecoveryFailure();
  @override
  String toString() => 'Animus recovery requires review';
}

const recoveryGenerationHeader = 'X-Hub-Recovery-Generation';
const operationGenerationHeader = 'X-Hub-Operation-Generation';
const _recoveryErrors = {
  'recovery_required',
  'operation_recovery_required',
  'recovery_unavailable',
};
final _uuid = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
);
bool _known(Object? value) =>
    value is String &&
    _uuid.hasMatch(value) &&
    value != unknownOperationGeneration;

String? recoveryResponseGeneration(AnimusHttpResponse response) {
  final matches = response.headers.entries
      .where(
        (e) => e.key.toLowerCase() == recoveryGenerationHeader.toLowerCase(),
      )
      .toList();
  if (matches.isEmpty) return null;
  if (matches.length != 1 || !_known(matches.single.value)) {
    throw const FormatException('Invalid recovery response metadata');
  }
  return matches.single.value;
}

Map<String, dynamic> _object(AnimusHttpResponse response, int limit) {
  final types = response.headers.entries
      .where((e) => e.key.toLowerCase() == 'content-type')
      .toList();
  final encodings = response.headers.entries
      .where((e) => e.key.toLowerCase() == 'content-encoding')
      .toList();
  if (response.body.length > limit ||
      types.length != 1 ||
      !RegExp(
        r'^application/json(?:\s*;\s*charset\s*=\s*(?:"utf-8"|utf-8))?$',
        caseSensitive: false,
      ).hasMatch(types.single.value) ||
      encodings.length > 1 ||
      encodings.any((e) => e.value != 'identity' && e.value != '')) {
    throw const FormatException('Invalid API representation');
  }
  final parsed = decodeStrictAnimusJson(
    utf8.decode(response.body),
    maxDepth: 48,
  );
  if (parsed is! Map<String, Object?>) {
    throw const FormatException('API object required');
  }
  return Map<String, dynamic>.from(parsed);
}

final class _Descriptor {
  _Descriptor(Map<String, dynamic> info) {
    final r = info['recovery'];
    if (r is! Map ||
        r.keys.any(
          (k) => !const [
            'protocol_version',
            'required',
            'profile',
            'state',
            'generation',
          ].contains(k),
        ) ||
        r['protocol_version'] is! int ||
        r['protocol_version'] != 1 ||
        r['required'] is! bool ||
        !const ['open', 'closed'].contains(r['state']) ||
        !r.containsKey('generation')) {
      throw const FormatException('Invalid recovery discovery');
    }
    required = r['required'] as bool;
    generation = r['generation'] as String?;
    if (required) {
      if (r['profile'] != 'native-workout-v1' ||
          r['state'] != 'open' ||
          !_known(generation)) {
        throw const FormatException('Recovery unavailable');
      }
    } else if (generation != null ||
        (r['profile'] != null && r['profile'] != '')) {
      throw const FormatException('Invalid explicit legacy discovery');
    }
  }
  late final bool required;
  late final String? generation;
}

/// Enforced recovery reviews never use the development legacy escape hatch.
String requireRecoveryDiscovery(AnimusHttpResponse response) {
  if (response.statusCode != 200) throw const AnimusRecoveryFailure();
  final descriptor = _Descriptor(_object(response, 64 * 1024));
  if (!descriptor.required ||
      recoveryResponseGeneration(response) != descriptor.generation) {
    throw const AnimusRecoveryFailure();
  }
  return descriptor.generation!;
}

Map<String, dynamic> recoveryResponseObject(AnimusHttpResponse response) =>
    _object(response, 8 * 1024 * 1024);

bool isRecoveryResponseError(Object? value) => _recoveryErrors.contains(value);

/// One identity/config/local-generation scope. Construction is inert. Each
/// covered API exchange commits its intent before invoking the supplied I/O.
final class DurableAnimusRecovery implements AnimusRecoveryPort {
  DurableAnimusRecovery(
    LocalDatabase database,
    this.binding, {
    this.allowLegacyDevelopment = false,
  }) : _repository = RemoteRecoveryRepository(database);
  final RemoteRecoveryBinding binding;
  final bool allowLegacyDevelopment;
  final RemoteRecoveryRepository _repository;
  _Descriptor? _descriptor;
  @override
  bool get preflightSelection => true;
  Future<RemoteExchange> _begin(Future<RemoteExchange> pending) async {
    try {
      return await pending;
    } on StoreException {
      throw const AnimusRecoveryFailure();
    }
  }

  @override
  Future<void> checkReady() async {
    final state = await _repository.state(binding.id);
    if (!state.ready &&
        !(state.state == 'unbound' && _descriptor?.required == false)) {
      throw const AnimusRecoveryFailure();
    }
  }

  Future<Never> _stop(
    RemoteExchange exchange, [
    AnimusHttpResponse? response,
  ]) async {
    try {
      await _repository.fence(binding.id);
    } on Object {
      /* The pre-I/O intent independently fences recovery. */
    }
    if (response != null) {
      String? generation;
      try {
        generation = recoveryResponseGeneration(response);
      } on FormatException {
        /* malformed stays unknown evidence */
      }
      try {
        await _repository.appendResponse(
          exchange,
          status: response.statusCode,
          generation: generation,
          body: response.body,
        );
      } on Object {
        /* Never use a failed/fenced store; pending intent preserves uncertainty. */
      }
    }
    try {
      await _repository.capture(binding.id);
    } on Object {
      /* Pending intent/fence remains durable even when capture fails. */
    }
    throw const AnimusRecoveryFailure();
  }

  @override
  Future<AnimusHttpResponse> discover(
    Future<AnimusHttpResponse> Function(Map<String, String>) send,
    bool Function() current,
  ) async {
    final exchange = await _begin(_repository.beginDiscovery(binding));
    AnimusHttpResponse? response;
    try {
      if (!current()) return await _stop(exchange);
      response = await send(const {});
      if (!current()) return await _stop(exchange, response);
      if (response.statusCode == 401 || response.statusCode == 403) {
        if (recoveryResponseGeneration(response) != null ||
            response.body.isNotEmpty &&
                _recoveryErrors.contains(
                  _object(response, 64 * 1024)['error'],
                )) {
          return await _stop(exchange, response);
        }
        await _repository.settleUnscopedResponse(
          exchange,
          status: response.statusCode,
          body: response.body,
        );
        return response;
      }
      if (response.statusCode != 200) return await _stop(exchange, response);
      final descriptor = _Descriptor(_object(response, 64 * 1024));
      final observed = recoveryResponseGeneration(response);
      if (observed != descriptor.generation) {
        return await _stop(exchange, response);
      }
      if (!descriptor.required) {
        if (!allowLegacyDevelopment) return await _stop(exchange, response);
        await _repository.settleUnscopedResponse(
          exchange,
          status: 200,
          body: response.body,
          legacyDevelopment: true,
        );
      } else if (exchange.generation == null) {
        await _repository.settleInitialDiscovery(
          exchange,
          generation: descriptor.generation!,
          body: response.body,
        );
      } else {
        await _repository.settleValidatedResponse(
          exchange,
          status: 200,
          generation: descriptor.generation!,
          body: response.body,
        );
      }
      _descriptor = descriptor;
      return response;
    } on AnimusRecoveryFailure {
      rethrow;
    } on Object {
      return await _stop(exchange, response);
    }
  }

  @override
  Future<void> prepareSelectionTx(
    LocalTransaction tx,
    Iterable<String> operations,
  ) async {
    final descriptor = _descriptor;
    if (descriptor == null) throw const AnimusRecoveryFailure();
    await _repository.prepareOriginsTx(
      tx,
      binding.id,
      operations,
      generation: descriptor.generation,
      legacyDevelopment: !descriptor.required,
    );
  }

  @override
  Future<AnimusHttpResponse> exchange(
    RemoteApiRequest request,
    Future<AnimusHttpResponse> Function(Map<String, String>) send,
    bool Function() current,
    void Function(AnimusHttpResponse) validate,
  ) async {
    final descriptor = _descriptor;
    if (descriptor == null) throw const AnimusRecoveryFailure();
    final exchange = await _begin(
      _repository.beginExchange(
        binding.id,
        request,
        legacyDevelopment: !descriptor.required,
      ),
    );
    final headers = <String, String>{
      if (descriptor.required) recoveryGenerationHeader: exchange.generation!,
      if (descriptor.required && request.path == RemoteApiPath.action)
        operationGenerationHeader: exchange.operationGeneration!,
    };
    AnimusHttpResponse? response;
    try {
      if (!current()) return await _stop(exchange);
      response = await send(headers);
      if (!current()) return await _stop(exchange, response);
      if (response.statusCode == 401 || response.statusCode == 403) {
        if (recoveryResponseGeneration(response) != null ||
            response.body.isNotEmpty &&
                _recoveryErrors.contains(
                  _object(response, 64 * 1024)['error'],
                )) {
          return await _stop(exchange, response);
        }
        await _repository.settleUnscopedResponse(
          exchange,
          status: response.statusCode,
          body: response.body,
        );
        return response;
      }
      final generation = recoveryResponseGeneration(response);
      final object = response.body.isEmpty
          ? null
          : _object(response, 8 * 1024 * 1024);
      final error = object?['error'];
      if (_recoveryErrors.contains(error) ||
          descriptor.required && generation != exchange.generation ||
          !descriptor.required && generation != null ||
          response.statusCode == 404 &&
              exchange.operationGeneration != null &&
              exchange.operationGeneration != exchange.generation) {
        return await _stop(exchange, response);
      }
      if (descriptor.required &&
          request.path == RemoteApiPath.operationStatus &&
          response.statusCode == 200 &&
          (object?['recovery_generation'] != generation ||
              object?['recorded_operation_generation'] !=
                  exchange.operationGeneration)) {
        return await _stop(exchange, response);
      }
      validate(response);
      if (descriptor.required) {
        await _repository.settleValidatedResponse(
          exchange,
          status: response.statusCode,
          generation: generation!,
          body: response.body,
        );
      } else {
        await _repository.settleUnscopedResponse(
          exchange,
          status: response.statusCode,
          body: response.body,
          legacyDevelopment: true,
        );
      }
      return response;
    } on AnimusRecoveryFailure {
      rethrow;
    } on Object {
      return await _stop(exchange, response);
    }
  }

  Future<Uri> operationStatusUri(Uri uri, String operationId) async {
    final descriptor = _descriptor,
        origin = await _repository.operationOrigin(operationId);
    if (descriptor == null || origin == null) {
      throw const AnimusRecoveryFailure();
    }
    return descriptor.required
        ? uri.replace(queryParameters: {'operation_generation': origin})
        : uri;
  }
}
