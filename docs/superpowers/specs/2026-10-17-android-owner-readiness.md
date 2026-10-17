# Android owner readiness

Date: 2026-10-17. Lane: **full**. Status: **approved preparation scope; independent design review PASS**.
The owner approved the offline-first preparation order and supported application
ID `dev.animusstudio.alkion`, a dedicated Alkion key and manual signed-APK updates.
Actual key creation/custody/access remain gated. No device, signing or transfer qualification is claimed.

## Outcome and inspected baseline

Prepare an isolated supported Alkion installation, durable phone file workflows
and reproducible Android evidence before real data enters that installation.
Initial emulator feasibility may precede the [UI/UX refactor](2026-10-17-ui-ux-refactor.md);
final affected device proof must use the refactored candidate.

At `f6b54f9`, `app/android/app/build.gradle.kts` selects only `.dev` and blocks
release tasks. `app/Makefile` blocks ordinary run/install/device discovery.
`AlkionIdentity`, profile roots and notification identifiers use `.dev`.
`main.dart` creates a profile before onboarding; `RestoreService` already supports
empty-storage restore, but the app has no first-start entry for it.

`TransferService.importFile` and the recovery screen accept typed paths.
`RuntimeRecoveryHost` backs up into app documents; `DirectoryExportDelivery` and
`createBackup` publish verified local bytes through exclusive hard links.
`share_plus` is present for outgoing JSON, with no receiving-file picker API.
The locked `sqlite3`/`sqlite_async` driver, FFI locking/fsync, transfer and restore
tests prove bounded Linux behavior, with Android still unqualified.

`WorkoutNotification` is not initialized by production startup; native scheduled
and action receivers are disabled. Its shown notification carries no fenced
payload, and its background helper changes SQL without refreshing the OS mirror.
Existing timer tests exercise the helper directly, rather than installed actions.

## Identity, build and update contract

Use explicit `supported` and `dev` Android flavors: `dev.animusstudio.alkion` /
`Alkion`, and `dev.animusstudio.alkion.dev` / `Alkion Dev`. Keep the Dart package
and Linux binary `alkion`; the Linux development route retains `.dev`.
Resolve one variant identity for Dart root validation, labels, preferences and
notification channels/actions; check it against the native installed package
before opening a store. Use application-ID-scoped task affinity and providers.
Never discover, open or silently adopt Reps or the other variant's private root.

Same-package, same-signer updates with increasing version codes must retain the
installation/profile IDs, selected generation and all local work. A signature or
package mismatch fails closed; clearing/uninstalling an existing app is no repair.
The approved owner route is a dedicated supported signing key and manually
delivered signed APK, with no OTA. Actual key creation, custody/recovery location,
authorized signer and execution scope must be recorded before access.
No inherited key file or release secret is read; no debug-signing fallback is
allowed for an owner candidate. Public tags, releases and binaries remain barred
before 1.0. A private candidate is a qualification build, not a release claim.

## Reusable phone document workflow

Add a narrow native SAF bridge in the existing Flutter activity, with a typed
Dart adapter. Existing dependencies cover sharing, private directories and hashes;
two Android document operations do not justify another picker package. Use
`ACTION_OPEN_DOCUMENT` and `ACTION_CREATE_DOCUMENT` with `CATEGORY_OPENABLE`;
Android's [document guide](https://developer.android.com/training/data-storage/shared/documents-files)
defines their URI grants and fresh-name behavior. Do not request broad storage
access or a directory tree. Do not interpret a content URI as a filesystem path.

Serialize bridge operations; copy streams on an IO worker between a granted URI
and uniquely named app-private staging outside the selected profile root. Return
small typed receipts, never backup-sized method-channel payloads. Validate the
operation, app-owned staging path and byte bound; URI metadata and names are
untrusted. Apply the existing raw-transfer and backup bounds while streaming,
including unknown-length inputs. Cancellation, revoked grants, short/oversize
streams and process death never become success or change the selected store.
Restart may request reselection; completed private staging remains distinguishable
from partial bytes. Keep the original document untouched.

For input, close and flush the private copy before invoking existing transfer or
backup verification. Preserve exact original bytes before parsing through the
existing import journal; namespace/reimport, changed-source and absence semantics
remain unchanged. Verification operates on the staged bytes, not a later URI read.

For output, flush owed edits first and produce the complete coherent export or
verified backup in app-private storage using existing publication rules. Copy
those immutable bytes to a newly created document, close it, reopen it for a
bounded readback and compare length/hash; backup readback also passes the full
receiving verifier. Retain the private original on every failure. A failed or
interrupted destination may remain visible as an incomplete copy; never replace
or delete an existing external file to simulate rollback.

No hard link, atomic rename or durable flush is promised for arbitrary providers:
[ContentResolver](https://developer.android.com/reference/android/content/ContentResolver)
can return streams backed by pipes. A provider without usable readback cannot
complete the verified-save route. A successful share or local readback does not
prove off-device durability. Keep optional sharing labelled as delivery only.

The supported recovery route is manual: save the backup through Files, copy it
to selected off-device media/workstation, then run the same full verifier at that
receiving destination. Add a read-only receiving-file CLI through `make -C app`;
it inspects a private copy without launching an app/profile. Record full container
digest, length, format/schema and inventory result. Physically off-device storage
and an independently verified received copy are required before calling it a
usable off-device backup. No temporary service, sync layer or upload is needed.
Proposed receiving command: `make -C app alkion-verify-backup ALKION_BACKUP=<received-file> ALKION_OUTPUT=<fresh-inspection-directory>`.

## First start and restore generations

Before `AlkionRuntime.open` can create an identity, an empty installation offers
Start local or Restore backup. Selection and verification require no writable
profile. A confirmed fresh restore preserves the backed-up profile ID and creates
a new installation ID through existing `RestoreService` adoption. Qualify restore
on a separate fresh installation of the same variant, without clearing the source.
This plan qualifies same-variant recovery; cross-variant transfer is not selected.

Same-profile replacement retains the current flush/close/stage/reconcile/fence/
select sequence. Keep prior generations, newer-work reviews, uncertain attempts
and original backups. Repeated/interrupted restore never replays newer operations
or imports them as fresh intent. Resume or keep-current remains an explicit
choice; a fresh restore interrupted before identity publication can resume only
its verified staging, without creating an unrelated empty profile. Foreign-profile,
newer-schema, corrupt, linked or nonempty targets fail without destructive fallback.
Keep OS backup disabled. Private archive/legacy capture completeness is separate.

## Lifecycle, notifications and qualification

Initialize the existing notification plugin after the selected runtime and saved
draft are ready. Prefer the existing visible action model: +30s opens/resumes the
app, then one runtime owner applies the command and refreshes the OS mirror after
commit. Do not add a foreground service or competing headless writer. A payload
identifies variant/profile/generation/draft/rest and expected timer revision;
duplicate delivery of that action token increments once. A refreshed notification
can issue a new action. Stale, finished, expired, foreign or pre-restore actions
cannot mutate a store. Draft/timer change and token consumption commit together;
controller state follows committed results. Native receivers enable only the
selected scheduling/action route. Closing/restoring a runtime cancels its mirrors.

Notification denial/revocation and unavailable exact timing preserve logging and
the absolute rest deadline. Show the limitation; use an inexact OS fallback when
available and reconcile on reopen. Do not claim exact background delivery without
capability. Distinguish backgrounding, ordinary process death, swipe dismissal and
force-stop: force-stop does not promise OS delivery before manual reopening.

Only an explicitly named, fresh disposable emulator with synthetic stores may use
the new debug run/install route. Require serial, expected AVD and disposable-run
receipt; refuse physical devices, mismatches and implicit/default selection.
Use only serial-scoped commands. Co-install a synthetic legacy-package neighbor
without launching legacy code/sync, plus both Alkion variants. No owner device,
key, real export or broad device inventory is part of emulator preparation.

## Observable acceptance

- **A1:** Supported/dev/synthetic legacy coexist with separate roots, providers,
  notifications and task affinity; starting/updating one leaves neighbors exact.
  Native/Dart identity disagreement fails before profile writes.
- **A2:** Same-signer supported updates preserve IDs, generation, drafts, settings,
  operations and source bytes; wrong-signer/package attempts preserve the install.
- **A3:** Real Android SQLite proves constraints, atomic data/outbox commit,
  WAL-tail coherent backup, watches, ownership refusal, reopen and stale-generation
  fencing; missing native assets or failed directory durability block qualification.
- **A4:** Background/kill/reopen preserves exact committed work and resume;
  finish/restart does not duplicate a workout. Notification taps resume correctly;
  +30s commits once per token and stale/replayed/foreign actions change nothing.
  Denied/revoked permissions and force-stop retain usable local logging/recovery.
- **A5:** Phone selection imports exact bytes with existing idempotency/review
  behavior. Cancel, URI revocation, unknown length, size limits, interruption and
  disk-full and provider read/write/readback errors retain originals and the current generation.
- **A6:** Coherent output, verified provider copy and independently verified
  off-device copy have matching bytes. Share-only, truncated, changed or unsupported
  destinations cannot pass. Restore from the received copy preserves covered data.
- **A7:** First-start separate restore and same-profile replacement retain exact
  IDs/values/relationships/drafts/settings/evidence across interrupted boundaries;
  newer work remains reviewable, repeat callbacks cannot write old generations,
  and foreign/corrupt/newer-schema/nonempty targets stay preserved.
- **A8:** After the UI refactor, the final signed candidate separately passes A1–A7
  as applicable on the named owner installation using synthetic successor data.
  Record commit/build/APK digest, package, signer fingerprint, OS and storage route.
  Independent acceptance blocks real transfer and switch; changed candidate,
  signer, storage or relevant platform inputs invalidate affected evidence.

Authentication, Animus transport, real legacy capture/transfer, writer handoff,
deployment and retirement remain separate work. This design grants no operational
access or public publication. Related: [implementation plan](../plans/2026-10-17-android-owner-readiness.md).
