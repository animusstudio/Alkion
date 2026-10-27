import 'dart:async';

/// Wraps a single-subscription stream factory in a stream that can be listened
/// to more than once, replaying the most recent value to each new listener.
///
/// A SQLite watch may be a single-subscription stream, and
/// cancelling does not reset it — a second `listen()` throws
/// "Bad state: Stream has already been listened to". That is fatal for a
/// StreamBuilder living inside a lazy ListView: the sliver garbage-collects the
/// child when it scrolls out of the cache window (disposing the subscription)
/// and re-creates it on the way back, which re-listens. In a release build that
/// uncaught error renders as Flutter's featureless gray ErrorWidget.
///
/// [Stream.multi] runs its callback once PER listener, so each listener gets a
/// freshly created upstream. The captured [last] value is replayed immediately
/// so a recycled section repaints with data instead of flashing its loading
/// state, and the upstream is cancelled when a listener leaves so a recycled
/// child does not leak a SQL watch.
///
/// The `T?` sentinel relies on a non-nullable element type, which the `extends
/// Object` bound on [T] now enforces at compile time — true for every current
/// repository stream (Lists, ints, records). For a nullable element type,
/// track a separate `hasLast` flag instead.
Stream<T> reListenable<T extends Object>(Stream<T> Function() create) {
  T? last;
  return Stream.multi((controller) {
    final cached = last;
    if (cached != null) controller.add(cached);
    final sub = create().listen(
      (v) {
        last = v;
        controller.add(v);
      },
      onError: controller.addError,
      onDone: controller.close,
    );
    controller.onCancel = sub.cancel;
  });
}
