# Alkion owner gates and known limits

T7 record of what the synthetic Linux evidence does **not** establish, the
gates an owner cutover still needs (spec milestone O and R8), and the T7
decisions on the items carried from the T5/T6 reviews. Integrated evidence is
in [acceptance](acceptance.md); the future Animus seam is in
[animus-follow-on](animus-follow-on.md).

Nothing here is authorized by this phase: no real data or device access, no
legacy mutation, no transport, attachment, server authority, READY, retirement,
purge, release, signing or publication.

## Owner cutover gates (all UNRUN)

| Gate | What it needs | Current evidence and status |
| --- | --- | --- |
| Build and installation identity | Final application ID, signing, repository, license and release route | Development ID `dev.animusstudio.alkion.dev` only. **UNRUN/unauthorized.** |
| Device and writer inventory | Every installation and writer of the owner's legacy Reps data: phones, desktops, old images, admin/background jobs, server writers | None collected. The tooling refuses legacy roots and never discovers devices. **UNRUN.** |
| Durable pause and input save | Each legacy writer paused with its owed input saved, before export | Alkion's own lifecycle barrier flushes owed input ([storage](storage.md)); nothing pauses legacy Reps. **UNRUN.** |
| Complete legacy archive | Server-only rows, local/server comparison, pending queue and deletion evidence, non-exported state disposition, receiving-side restore check of the archive | A `reps-export` full v1 file is domain transfer only. Quarantine preserves explicit incoming files and uncertain queue evidence ([transfer](transfer.md#incoming-evidence-quarantine)). No complete legacy backup is claimed. **UNRUN.** |
| Live transfer | Owner export imported into an owner installation, reviewed corrections/absences | Synthetic fixtures only (`test/fixtures/alkion/`). **UNRUN.** |
| One authoritative writer | Controlled primary handoff; every other installation fenced or retired; server containment | Owned synthetic fences only: a restore fences the previous generation on the same storage, and the profile owner lock refuses a second process. A backup cannot stop another offline device. **UNRUN.** |
| Forward recovery on owner storage | Manual backup copied off-device and verified there; separate-storage restore on owner media | Separate-storage restore and receiving verification pass on disposable Linux storage only. Android/off-device media **UNRUN.** |
| Archive retention window | The 30-day final-legacy-archive window starts only after both qualified retirement and a restore check | No window or deletion starts here. **Not started.** |
| Android | SDK/JDK, an explicitly identified fresh synthetic emulator, co-install/provider/storage/notification isolation, minimize/kill/+30s/permission behavior | Not installed or run in T7 by direction. **UNRUN.** |

## Decisions on carried review items

### Incoming quarantine wiring (T5/T6 carry)

**Decision: not wired into an app loader; no ownership extension.**
`IncomingQuarantine` stays the standalone seam. Rationale against the spec:

* R1 forbids opening or adopting legacy drafts, settings, credentials or the
  legacy database; explicit synthetic artifact import is the only transfer
  input. R4 keeps every new draft and finished recovery in SQLite.
* No production path loads incoming legacy files. The runtime builds only
  `DraftStore.local` and `FinishedSessionStore.local`. The retained
  directory constructors read through `JsonFileStore`, whose `save` and `clear`
  refuse with `incoming_evidence_read_only`; nothing calls them in `lib/`.
* The one incoming path, explicit full-export import, already preserves before
  it parses: raw bytes, digest and a `received` journal entry commit before any
  decode, and rejected or incompatible input keeps its bytes
  ([transfer](transfer.md#staging-selection-and-crash-behavior)).
* AC-15 requires the evidence to survive *before loaders*. With no loader, the
  seam's own tests (`quarantine_test.dart`, the AC-15 backup/restore case) and
  the integrated flow (legacy-shaped decoy files beside the root stay
  byte-identical and unadopted) are the evidence.

Gate: any future owner flow that ingests legacy draft, finished-snapshot,
`.tmp` or queue files must call `IncomingQuarantine.capture` in the same
transaction boundary before its loader, and must keep `replayCompleteness()`
blocking. That flow is new product scope and needs its own approval.

### Restore: mutation versus transport

**Decision: the T6 reading is confirmed.** R7 says to "atomically select
restore generation with mutation/transport closed until reconciliation
completes", and AC-18 asks that reconciliation retain newer work and attempts
or record an explicit loss boundary. In T6 reconciliation is a step of the
restore itself. The runtime is closed and the previous generation fenced; each
newer, changed or absent row becomes an immutable `restore_newer_work` review
holding the exact previous and backup rows. Only after that is the restored
generation selected. Once selected, local mutation reopens. Undecided reviews
keep `RestoreReviews.transportGate` at `blocked`, so a future sender cannot
publish while newer work is undecided. Keeping local mutation closed until the
owner decides every review would block unrelated logging. The spec keeps
unrelated work usable elsewhere (R5, R6) and does not ask for that block. The
integrated acceptance flow commits a local write after selection and confirms
that the review count and the blocked gate are unchanged. An owner may later
choose a stricter policy; that would be a product decision.

### T7 fix round 1 ownership extension

The coordinator authorized minimal edits to T4-owned
`app/lib/session/session_manager.dart` and `app/lib/ui/today_screen.dart` to
fix the two inherited defects above. `active_session_screen.dart` needed no
change. The edits change no persisted state, launch guard, session indicator or
resume behavior.

### Stale storage document

[storage](storage.md) is corrected as a recorded T7 extension. The change
covers the startup sentence, the generation-resolved database path, the
reserved-but-unused migration IDs and the Restore row. The T2 behavior text is
unchanged.

## Known limits (explicit status)

| Limit | Status | Notes |
| --- | --- | --- |
| No in-app entry for separate-storage restore before a first profile | **Known limit** | The app creates a profile at first start; separate-storage restore is reachable through `RestoreService` and the proof target only. |
| Disk-full is injected only | **Injected PASS; physical UNRUN** | `ENOSPC` injected while writing a backup and while staging a restore. A physically full filesystem was not used. |
| Power loss | **UNRUN** | All crash proof is process SIGKILL around COMMIT, publication and selection. No physical power-loss claim. |
| DST computation | **UNRUN** | Calendar days and offsetless source times are preserved without inventing offsets. No DST-transition computation case ran. |
| Raw-size ±1 boundary | **UNRUN** | Reader limits are configurable and bounds are tested. The exact 128 MiB raw-staging edge (limit, limit+1) was not exercised. |
| Recovery tool does not kill an initial import into an empty profile | **Known limit** | Transfer crash boundaries run with pre-existing draft/operation/attempt state. A first import into an empty profile is not killed. |
| Hard-link export on filesystems without hard links | **Known limit** | `DirectoryExportDelivery` and backup publication use exclusive `link(2)`. Without hard links they fail with a generic error and publish nothing; no fallback copy exists. |
| Import by typed path | **By design** | The transfer screen takes a typed file path and has no picker dependency. Linux only was exercised. |
| Inherited minimize assertion | **Fixed (T7 fix 1)** | Inherited from `6207987`: `ActiveSessionScreen.dispose` notified `SessionManager` while `finalizeTree` held the build lock. `SessionManager.screenOpen` now changes at once and defers its notification to the post-frame callback when set during that phase. A regression test covers it, and the acceptance tests no longer tolerate it. |
| Inherited resume-hero layout | **Fixed (T7 fix 1)** | Inherited from `6207987`: the Today resume hero split a long single-word name at 2x text, and its clock/count row overflowed in es at 320dp/2x. The name is now a `FitLabel` (`maxLines: 3`), and the count is a `Flexible` `FitLabel`. A regression test covers it, and the acceptance tests no longer tolerate it. |
| Stale doc comments | **Cosmetic** | Some retained `lib/` doc comments still name PowerSync. There are no imports, dependencies or native registrations. |
| Stale development document | **Cosmetic** | [development](development.md) records the T1-era state. It is not owned by T7. |
| Android notifications, background and permissions | **UNRUN** | See the Android gate above. |
| R3 two-device, wrong-account, revoke and relogin | **UNRUN** | Needs the separately approved transport; see [animus-follow-on](animus-follow-on.md). |

## Recovery gates for an owner

* Back up manually after each session that matters. Copy the file off the
  device and run the receiving check there. Work after the last verified
  backup can be lost.
* After a restore, review every `restore_newer_work` entry before any future
  transport is enabled. Keep the previous generation, which stays fenced and is
  never deleted.
* A failed, interrupted or unsupported restore keeps the source file, staging
  and current generation. Complete it or keep current state explicitly; nothing
  is retried automatically.
* Legacy Reps remains the daily app with its own sync until the cutover gates
  above are passed.
