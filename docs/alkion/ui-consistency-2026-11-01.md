# Whole-app presentation inventory — 2026-11-01

Companion evidence for the [approved visual-consistency plan](../plans/2026-11-01-catalog-visual-consistency.md), acceptance A5–A7.
The inventory below distinguishes source corrections from rendered evidence.
Current qualification status lives in [acceptance](acceptance.md).

## Source inventory

| Surface | Finding and disposition | Verification route |
| --- | --- | --- |
| Today | PR rows used raw gesture handlers without keyboard activation or focus feedback. They now use themed Material text buttons, preserving the exact PR/date/unit content and callback. Existing 16dp page insets and 24dp section spacing remain. | Today in the shell layout sweep; native Today with synthetic history. |
| Plan and library | Back, day and exercise rows now use focusable Material actions. Day-menu activation remains separate from opening the day. Library row insets are 16dp. The existing segmented control already has selected semantics, focus feedback and a 48dp target. | Keyboard day/menu test; Plan/editor layout and dirty-editor tests; native Plan/day editor. |
| Day editor | The expand control formerly sized to its two text lines, independently of adjacent 48dp controls. It now owns a minimum 48dp target and announces expansion inside the native button semantics. Remove remains a separate action, with an 8dp glyph container radius. Inner row and expanded-form insets are 16dp. | Target-size, keyboard expand/remove, drag isolation and existing editor tests; native short and long rows. |
| Exercise editor | The existing form, token surfaces, 8/12dp control/panel corners and real font roles are retained. Its stats card groups read-only measurements; no hard-coded gray defect was found. | Existing editor layout/guard tests; native exercise-editor check unrun in this batch. |
| Active workout | T2 adds a bounded success trace only for matching accepted set evidence after persistence clears. It cancels on changed evidence, pending/failed work, hidden routes and backgrounding. The pinned 56dp log action and commit-before-action behavior remain. | T2 persistence/motion tests; live layout and set-entry regressions; native log/minimize/resume/finish recording. |
| Rest | Neutral controls already have 48dp targets and token focus treatment. The calibrated rest scale and numerical readout carry timing information, so they remain. No decorative animation covers set inputs. | Existing rest/live layout and notification-boundary tests; native running rest and reduced motion. |
| Summary | Top-set rows use 16dp inner insets. T2's completion trace follows the committed Finish transition. The centered completion header and larger section breaks are a deliberate completion-page composition. Dates, readings and coverage statements remain solid text. | Summary layout and T2 success tests; native saved summary. |
| History | Header, footer and exercise-detail actions now use focusable Material buttons. Expanded state merges into the header's native button semantics. Card/header/body insets are 16dp. The noninteractive 44dp date block preserves intact figures and is not a touch-target exception. Exact/imported/unknown evidence remains unchanged. | Keyboard expand/resume; existing history actions, numeric evidence and layout suites; native expanded history. |
| Progress | Existing 16dp measurement cards, shared numeric formatting and 48dp setup selection are coherent. Separate numeric cards and chart surfaces group different measurements, so they remain. Empty and unsupported setups retain their truthful messages. | Existing Progress/layout tests; native populated and unsupported/empty states. |
| Profile | Back and name editing now have native keyboard activation and token focus feedback. Existing accent choices already provide 48dp controls and selected semantics. Black/white check ink is deliberately chosen by swatch luminance; it is not theme leakage. | Existing Profile layout/header/row tests; native preferences, theme and name editing. |
| First use | Preserve 24dp insets, bounded reading width and 56dp actions as a spacious entry composition. The opening belongs only to first use. T2 loading follows actual catalog work, and its failure handoff retains a usable recovery surface. Entering offline choices still creates no profile. | Existing four-locale, two-theme first-use/recovery suites and T2 real-startup failure tests; native entry/offline/Back. |
| Recovery | Preserve the focused 24dp-inset, bounded-width composition, flexible toolbar, 48/56dp actions, monospaced provenance and explicit failure/review content. Do not hide retained IDs or evidence for visual uniformity. | Existing restore/recovery tests; native synthetic backup/check/restore and cancellation. |

## Shared material and exceptions

- T1 consolidates catalog controls, provides labeled body discovery and keeps
  ordered selection/repetition immediate. T2 supplies token chip states, real-load
  glyph material and finite selection/success feedback.
- Space Grotesk remains interface text and Space Mono remains measured values or
  metadata. No font family, alternate formatter or synthetic font weight was added.
- The prescribed 16dp row inset does not require replacing every subordinate
  8/12dp gap. First-use/recovery reading layouts and the summary composition are
  documented exceptions, not competing token systems.
- No workflow, domain/store/schema, provider, dependency or persistence ordering
  change is part of T3. Save/retry barriers and existing callback ownership remain.

## Verification boundaries

The new keyboard tests exercise both dark/English and light/Spanish controls.
Existing layout suites cover 320/412dp and 1×/2× text with long content; their
shared harness is predominantly dark, with targeted light checks. A layout test
is not a pixel, TalkBack or native-performance qualification.

## Bounded Android evidence

The native batch used a fresh API 36 x86_64 emulator, a debug build, KVM and
SwiftShader. Only the committed full-rich synthetic import fixture was loaded.
No owner profile or physical device was accessed. The initial batch used source
`55232c5`; the final correction confirmation used `c6ffcdf`. The emulator and its
dedicated ADB server were stopped afterward; local evidence was retained.

| Native sample | Observed result |
| --- | --- |
| 412dp, 1×, dark | First-use/offline admission, synthetic import preview/success, Today, Plan/day editor, catalog/body front and back, muscle filtering, Details, favorite, immediate selection/repeat, ordered basket removal and pending-edit discard worked. Live warm-ups and working-set logging, minimize/resume, running rest, committed Finish/summary, expanded History and populated Progress were captured. |
| 412dp, 1×, light | Profile preferences and the separated Edit name action were captured on the final build. |
| 320×640dp, 2×, light | Profile, Plan/day editor, catalog/body/list, filtering, Details, immediate selection/repeat and explicit pending-selection discard were captured. The filter controls and results share a scrolling area: ordinary scrolling exposes full rows and 48dp repeat/detail actions below the initial fold. Long names wrap; bottom navigation abbreviates visible labels while retaining complete semantic labels. |
| Final action confirmation | Back exposes its label; collapsed day Reorder and Remove have separate 48×48dp semantic bounds; Profile Edit name has its own 48dp-high action instead of absorbing the whole header. |
| Reduced animation/lifecycle | With Android animation scales set to zero, the final light/large-text build starts and logs a warm-up. Home then foreground restores the same live session; elapsed time advances and the logged set remains accepted. This is a native smoke sample, with detailed cancellation/reduced-motion assertions supplied by host tests. |

Local recordings retain 18.00s of catalog/body navigation, 39.99s of workout
logging/minimize/resume and 20.01s of Finish/summary. Sampled frames were inspected;
a 10fps inspection around Finish shows the loading handoff followed by the saved
summary and stable measurements. This does not measure the precise duration of
individual decorative traces. No error output appeared in the final bounded
Flutter/AndroidRuntime error sample.

Android `gfxinfo` reported 38 window frames, 26 janky frames (68.42%), with
p50/p90/p95/p99 of 16/69/113/200ms. These are sparse Android window metrics from a
SwiftShader debug emulator, not Flutter UI/raster frame timings or phone
performance. They do **not** qualify smoothness or a hardware frame budget.

The existing Today workload artwork showed its truthful unavailable fallback on
this software target; the new catalog body diagram rendered. Native exercise
editor, recovery/restore, empty/unsupported Progress, other locales and the full
cross-product of themes/sizes/scales were not repeated in this bounded batch;
those retain source/host-test evidence only. No TalkBack or physical-device claim
is made. Private catalog assets and development captures are not redistributed.
