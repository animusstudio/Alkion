# Iconoir glyph system

Date: 2026-11-04. Lane: **Standard — interface integration**.
Status: **Integrated and independently reviewed; whole-suite CI gates delivery.**
Parent: [development](../alkion/development.md).

## Outcome and observed baseline

Replace app-authored Material glyphs and the custom-painted destination set with
a consistent, bundled Iconoir outline system while preserving Alkion's existing
navigation, meanings, layout and accessible controls. The current
`lib/theme/icons.dart` maps about 30 `WIcons` names to Material `IconData` and
draws five destination icons with a custom 1.75-unit painter. References span
the shared widgets, session flow and UI; direct Material glyphs also occur
throughout shell, recovery, entry, catalog and other app-authored screens.
Several small controls use 12–15 logical-pixel glyphs. `pubspec.yaml` currently
has no SVG renderer. T1 will recheck the exact source baseline and active callers
before implementation (inspected app baseline: `09cc85c`).

## Decisions and boundaries

- Use only the required regular SVG subset from the pinned upstream
  [Iconoir repository](https://github.com/iconoir-icons/iconoir), retaining
  revision `39834e3f193bc0cca2c36bebb6a650471977433d`, SVG originals, MIT notice,
  source URLs and per-file hashes. Generate
  deterministic app-ready derivatives at 1.25 and 1.0 stroke units plus a
  manifest. Preserve path geometry, fills, caps and joins; normalize effective
  descendant strokes too (including multi-path glyphs such as Pause).
- Use `flutter_svg` via a single semantic `AlkionGlyph`/`AlkionIcon` adapter;
  T1 selects and locks a release compatible with the pinned Flutter toolchain.
  Bundle runtime SVGs and their notice; keep originals/generation inputs outside
  the runtime asset bundle. No
  runtime network loading, string rewriting, custom SVG engine or broad
  framework fork. Use the adapter's asset rendering and theme/current-color
  support; verify behavior against the selected package's official
  [documentation](https://pub.dev/packages/flutter_svg).
- Stroke values are 24×24 viewBox units, not size multipliers or fixed pixels.
  Stroke is 1.25 units for rendered sizes below 32 logical pixels and 1.0 at
  32 and above. Support canonical 16, 20, 24, 32 and 48 sizes; default to the
  active `IconTheme` size with a 24 fallback. Preserve noncanonical 26–31 sizes
  with 1.25 stroke. Migrate 12–15 glyphs to at least 16 and verify local fit;
  report any unfit control for resolution before creating an exception. Do not
  shrink adjacent text.
- Preserve current token colors, selected destination circle and selected vs
  idle text emphasis, disabled/focus states, localized control semantics and
  48dp interactive targets. Hide decorative glyph semantics when the control
  already has a label; retain labels and ordering. Mirror only directional
  glyphs in RTL. Do not add weight/fill as a selected cue.
- Material-generated platform controls may retain framework icons where the
  app does not author the glyph. No data, navigation order/indices, launcher
  logo, exercise artwork, motion, background or layout redesign; no claims of
  physical-device qualification without device evidence.

Proposed core semantic roles: Home (`home-simple`), Workout (`gym`), Plan
(`calendar`), History (`clock-rotate-right`), Progress (`graph-up`), Library
(`book-stack`), Settings (`settings`), Add (`plus`), Edit (`edit-pencil`),
Delete (`trash`), Play (`play`) and Pause (`pause`). T1 inventories every
app-authored icon and proposes the remaining semantic-to-upstream mapping for
focused visual review; these examples do not assert owner-approved exact names.

## Acceptance

1. **A1:** A checked-in, reproducible asset subset has complete source and MIT
   attribution, stable hashes and manifest; both normalized derivatives preserve
   geometry and have the intended effective stroke on every rendered path.
2. **A2:** One semantic adapter resolves all app-authored icons to bundled assets,
   applies theme color, size, stroke tier and directional RTL behavior, and
   exposes no duplicate semantics for decorative glyphs. No app-authored
   Material icon or `WDestinationIcon` painter remains in the migrated scope.
3. **A3:** All existing navigation destinations retain label, order, index, selected
   treatment and tap target; shared widgets and app screens preserve their
   existing action, locale, contrast, focus, disabled and accessibility behavior.
4. **A4:** Tests cover asset provenance/effective strokes (including Pause), adapter
   semantics/color/size/RTL, action sheet and stepper states, tap targets, tab
   layout, and live/history/catalog/entry interactions. Replace glyph-specific
   `find.byIcon` checks with semantic adapter assertions. `commitPendingInput()`
   behavior and durable actions remain unchanged.
5. **A5:** Visual evidence covers both themes, selected/unselected, disabled and focus
   states at 16/20/24/32/48; live layouts at 320/412dp with text scales 1×/2×
   and EN/IT/DE; directional behavior in RTL. Inspect captures for stroke
   legibility at small sizes. Android device verification is identified
   separately from host render results.

## Tasks and checks

1. **Assets and adapter — standard Flutter/assets.** Inventory glyphs, finalize
   mappings, lock a compatible SVG package, and create attributed originals,
   deterministic 1.25/1.0 derivatives, manifest and adapter. Own the icon assets,
   app theme adapter, dependency lock, generator and focused tests. Check hashes,
   determinism, descendant strokes, color, sizing, RTL and semantics.

2. **Shared widgets and navigation — standard Flutter.** Migrate icon contracts
   and callers in action sheets, steppers, prescription/progress/session controls
   and tabs. Preserve destination labels/order/indices; check affordances,
   semantics/localization, selected/disabled states, tab geometry and
   `commitPendingInput()` barriers.

3. **Remaining screens — standard Flutter.** Replace app-authored Material
   glyphs and migrate all `IconData` callers across UI, shell, session, recovery,
   entry and catalog. Check affected interactions without changing data/action
   contracts.

4. **Visual and integration qualification — standard Flutter.** Update test and
   capture evidence for both themes, states, sizes, viewport/text-scale/locales
   and RTL; inspect glyph fit. Run formatting, tests, analysis and builds through
   documented Make routes with disposable Android data; dependency changes use
   explicit update routes, never locked `get-online`. Record results and separate
   host evidence from device evidence. Independent task review precedes
   delivery; integration checks follow the repository workflow. Use explicit
   disposable Android user data for debug builds and the
   [Android checklist](../alkion/android-smoke.md)
   on an explicitly selected disposable device/profile before claiming device
   qualification. One reviewed branch/PR merges on green checks; public pushes
   require exact outgoing-range review and owner approval.

## Task state and evidence

- T1–T4: Complete; independent task reviews PASS. Scoped host, build and Android
  emulator qualification passes; broader device/release gates remain open.
- Source `a60b610` bundles 40 attributed glyphs with two normalized SVG strokes,
  a semantic adapter (`app/lib/theme/alkion_icon.dart`) and the
  [mapping/provenance guide](../../app/tool/iconoir/README.md). Framework catalog
  ExpansionTile/dropdown icons remain exceptions; app-authored Material glyphs,
  `IconData` mappings and the destination painter are removed. No navigation,
  product data or backend behavior changed.
- Independent T1–T4 reviews PASS, including corrected 48dp touch-target review
  and three RTL rotation checks. Whole Flutter suite: 2,273 passed, two expected
  optional live-connection skips (549 seconds); asset checks 5/5; visual checks
  20/20, covering 400 glyph cells (two themes, five sizes), screen controls and
  RTL. Ten entrance-fix tests passed before the clean full-suite run.
- `make -C app get`, `analyze`, and check-only `format` passed; format checked 451
  files and found zero changes. Linux build passed in 32 seconds; debug APK build
  passed in 19 seconds.
- Scoped native icon/workout smoke PASS on a fresh Android emulator (API 36)
  (1080×2400, density 420), source `a60b610`; APK SHA-256
  `4e583f38f66e31bd930c49445e145ff1a4b0021db43ec54917777df172a6702a`. Verified
  offline start, navigation, empty workout, notification allow, minimize/resume,
  synthetic exercise creation, add exercise, 20kg×8 logging, finish and one
  160kg History workout. Keyboard activation completed the footer action; its
  center-tap overlap with navigation remains an existing editor-layout issue,
  unchanged since `09cc85c`, outside this change. Light switch/relaunch retained
  History; both-theme captures confirmed glyph sizes
  and states; no Flutter/AndroidRuntime errors. Unrun checklist areas: backup/
  restore, notification denial/actions, physical device, release and Animus.
- Public docs still have two pre-existing broken MakeHuman links
  (`LICENSE.CODE.md`, `LICENSE.ASSETS.md`, lines 47/66); unchanged and out of scope.
- Published-snapshot integration (2026-11-04): merging
  `116cd01342a6e79936bcb150bb0cbbe8159a5db2`, preserving its catalog/artwork,
  muscle, history/recovery behavior and licenses while migrating new glyphs.
  The `a60b610` checks above remain dated baseline evidence. At `ade9f7d`, focused
  integration checks and independent caller/asset review pass; 51 semantic roles
  use 50 originals. Exact outgoing review and whole-suite CI gate delivery. No persisted-data change; rollback reverts the UI change.
