import '../store/local_store.dart';

/// Incoming source flags are preserved; no boot rewrite is supported.
Future<void> backfillIsTemplate(Object legacy, {Object? parent}) async =>
    throw const StoreException('legacy_backfill_unavailable');
