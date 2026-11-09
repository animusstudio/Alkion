# A calmer toast

Date: 2026-11-09. Lane: **Standard**. Status: **Approved** by the owner on 2026-11-09.
Parent: [development](../alkion/development.md).
Baseline: `458aac6`; branch `feat/toast-redesign-20261109`.
Ordering: **after** [error messages and toasts](2026-11-08-error-messages-and-toasts.md)
(P1: it adds `widgets/w_toast.dart` and the `snackBarTheme` this plan restyles) and after
[failed saves](2026-11-08-failed-saves-and-history-editing.md) (P5) and
[live workout flow](2026-11-08-live-workout-flow.md) (P7), which own the raw
`SnackBar` sites that still set a danger background (see Decisions). Before the
[live workout declutter](2026-11-09-live-workout-declutter.md) plan, which calls
`showWToast`. Line numbers for P1 code are at its head `c171880`.

## Outcome and evidence

P1's toast works but looks and behaves like a stock SnackBar. The owner finds the
bar that slides up from the bottom ugly and hard to close: swiping it down collides
with Android one-handed mode. It **stays at the bottom**; the look and the dismissal change.

- **Look.** The theme draws an inverse slab: `backgroundColor: tokens.text`, content
  `tokens.bg` (`theme/app_theme.dart:112-124`), a bright block on a black UI in the dark
  theme. An error is a solid `tokens.danger` fill (`widgets/w_toast.dart:74`). There is
  no glyph, so status is carried by colour alone.
- **Dismissal.** Neither P1 nor the theme sets `dismissDirection`; Flutter 3.44
  defaults it to `down`. There is no tap to close and no close control.
- **Placement is right but unpinned.** The live workout puts `LogSetBar` in
  `bottomNavigationBar` (`session/active_session_screen.dart:1114-1115`), so the
  Scaffold already floats toasts above it; no test pins that. Tab pages clear the tab
  bar through `ToastTabBarClearance` (`widgets/w_toast.dart:19-34`).
- **Motion.** Toasts animate at the framework's default speed; they ignore
  `Motion.of` (`theme/motion.dart`) and reduced motion.
- **Raw sites P1 leaves** (`showSnackBar`, at `458aac6`): `session/active_session_screen.dart`
  221 and 258 (discard and finish failures, danger fill) and 291, 338 (Undo), 534, 575,
  592, 824; `ui/history_screen.dart:151` (danger fill); `ui/catalog_history_editor.dart:111`.
  Owners: 221, 258, 338 and the History sites belong to P7 and P5; 291 to the declutter
  plan; 534, 575, 592, 824 to no plan.

## Decisions

- **Same mechanism.** Still a floating SnackBar, still `SnackBarAction` for Undo
  (P7's Undo and `test/session/active_session_screen_test.dart` find that widget).
- **Look, carried by the theme.** A card on app surfaces: `tokens.surface3` fill, a 1 dp
  `tokens.lineStrong` border, `AppRadius.panel`, no elevation, text `tokens.text`, action
  `tokens.accentText`. In the light theme `surface2` equals `surface3`
  (`theme/tokens.dart:149-150`) and is close to the page, so the border does the
  separating; a test pins at least 3:1 against `bg` and `surface` in both themes. The
  error variant keeps the card but uses a `tokens.danger` border and glyph, never a fill,
  so error text stays `tokens.text`. The inverse palette in `buildTheme` goes away.
- **Glyph.** `showWToast` prepends a decorative 20 dp `AlkionIcon`: `AlkionGlyph.error`
  in `tokens.danger` for errors, `AlkionGlyph.info` in `tokens.info` otherwise, with an
  optional `glyph:` override (for example `check` in `tokens.success`). Glyphs carry no
  semantics label; the SnackBar's live region announces the text. No new strings.
- **Dismiss by side swipe or tap, never down.** The theme sets
  `dismissDirection: horizontal`, so raw SnackBars get it too. The helper wraps its content
  in a tap target that hides the toast (at least 48 dp tall). No close icon. TalkBack keeps
  the SnackBar's own dismiss action.
- **Undo stays inline** at the card's trailing edge; when text wraps at 2x the framework
  stacks the action under the text inside the card.
- **Motion and TalkBack.** `showSnackBar(snackBarAnimationStyle: Motion.sheet(context))`,
  so reduced motion shows and hides it instantly. With accessible navigation a toast with
  an action lasts at least 10 s.
- **Position unchanged.** Insets stay `16/8/16/12`; `ToastTabBarClearance` and its
  numbers stay. Over the live workout the Scaffold lifts the toast above the pinned bar.
- **Raw sites.** The theme gives them the card look and side dismiss, but not the glyph
  or tap-to-close; the owning plans adopt `showWToast`. U1 edits none of them. A site that
  still sets a danger background would draw `tokens.text` on red, so this plan merges only
  after P5 and P7; if one remains, the T2 sweep converts that line to `showWToast(error: true)`.

## Non-goals

Moving the toast to the top; a new surface or queue policy; sound or haptics; changing any
message text; editing the raw sites above; the `main.dart` limitation toast's content.

## Acceptance

- **A1.** Neutral and error toasts render as a bordered surface card with a leading glyph
  in light and dark, for every accent. Text meets 4.5:1 on the card, glyph and border 3:1,
  and the card is distinguishable from the page behind it.
- **A2.** A sideways swipe in either direction dismisses a toast; a downward swipe does
  not; a tap on the card dismisses it; the TalkBack dismiss action still works.
- **A3.** An Undo toast runs its callback once and shows the action inline; at 320 dp and
  2x text nothing is clipped and the action keeps a 48 dp target inside the card.
- **A4.** On the live workout a toast sits fully above `LogSetBar`; on shell pages fully
  above the tab bar; at 320 dp, at 1x and 2x.
- **A5.** With reduced motion the toast neither slides nor fades; with accessible
  navigation an Undo toast stays at least 10 s.
- **A6.** Every `SnackBar` still raw in `lib` renders the card look and dismisses sideways,
  and none sets a danger background.
- **A7.** No ARB, stored-data or message-text change; `arb_parity_test` and
  `unused_keys_test` pass.

## Tasks

Implementers Opus `high`, reviewers Sonnet `high`. T1 then T2 (T2's sweep needs T1's theme).

| Task | Owns | Acceptance | Class |
| --- | --- | --- | --- |
| T1 Look and dismissal | `theme/app_theme.dart` (`snackBarTheme` and the inverse palette only), `widgets/w_toast.dart`, `test/widgets/w_toast_test.dart`, `test/theme/snack_bar_theme_test.dart`, `test/shell/toast_clearance_test.dart` | A1, A2, A3, A5, A7 | UI |
| T2 Placement and sweep | new `test/widgets/w_toast_log_bar_test.dart` (a Scaffold with a real `LogSetBar` as `bottomNavigationBar`), new `test/widgets/raw_snackbar_source_test.dart` (no `lib` SnackBar sets `backgroundColor`), and only if a danger-fill site is left after P5 and P7, that one line | A4, A6 | UI |

Regions: `app_theme.dart` is edited only in the `snackBarTheme` block and the `inverse`
local P1 added. `w_toast.dart` keeps `showWToast`'s existing signature; `glyph:` is additive.

## Checks

- Focused: `make -C app test TEST='--concurrency=2 test/widgets/w_toast_test.dart
  test/widgets/w_toast_log_bar_test.dart test/widgets/raw_snackbar_source_test.dart test/theme
  test/shell test/session/active_session_screen_test.dart test/l10n'`;
  `make -C app analyze`.
- Widget tests: theme tokens and contrast per brightness and accent; `tester.drag` right,
  left and down on the toast; tap to dismiss; Undo once; 320 dp at 2x; `FakeAccessibilityFeatures`
  with `disableAnimations` and `accessibleNavigation`; `tester.getSemantics` shows a live
  region with a dismiss action.
- Integrated: full `make -C app test`; the three known inherited
  `catalog_metric_controls_test.dart` failures are named, no others. Device check on the
  owner's phone with a private Dev APK: a tab-page toast and a live-workout Undo toast,
  one-handed mode on, swipe sideways (dismisses) and down (does not), also from the
  card's edges against the system back gesture; light and dark; 2x font; TalkBack.

## Task state

None started.

## Next

Owner approval, then T1 after P1, P5 and P7 merge.
