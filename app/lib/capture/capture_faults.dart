import 'dart:async';

/// Named points a capture passes at each durable step: before and after
/// every journal replacement (`journal_flush:<stage>`,
/// `journal_renamed:<stage>`), after each store file and the manifest are
/// flushed and closed (`store_flushed:<name>`, `manifest_flushed`), right
/// before the no-replace publication (`publication_rename`), and at every
/// coordinator step (`journal:<stage>`, `published_renamed`, `released`,
/// ...), including the publication and resume decisions.
///
/// The production implementation does nothing. Tests wire a subclass that
/// records the points, stops the attempt at one of them (the coordinator
/// treats that like process death: nothing is cleaned up or released) or
/// parks a disposable fixture process there so it can be killed.
class CaptureFaults {
  const CaptureFaults();

  /// Called when a capture reaches [boundary]. Production: no-op.
  FutureOr<void> hit(String boundary) {}
}
