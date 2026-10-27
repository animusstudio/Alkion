# Alkion component direction study

2026-10-21 · Owner-accepted T1 visual baseline.
The integrated study is implemented in the editable [proposal](index.html).
The owner accepted it with a plain plus on Add exercise. This is a static web
artifact; final asset selection and Flutter behavior remain later work.

## Direction

**Alkion, by Animus: classical strength expressed through digital character.**
Use black `#000000`, off-white `#F0F0F5`, flat fills, restrained hairlines and
comfortable targets. Space Grotesk 400/500 carries headings, reading and actions;
Space Mono 400 carries exact values, units and compact metadata. Keep ordinary
text legible and stable. The character treatment belongs to imagery and selected
measurement textures; ASCII does not replace controls or body copy.

The compact Möbius felt incidental. The owner's next experiment replaces it in
the first workout card with a full-body sculptural character map, using a real
grayscale source's silhouette and shading. Stable source-clipped muscle regions
use denser characters for mocked primary/support focus; Custom keeps an unfilled
figure. Front/Back shows one complete figure at a time, and a review-only Mock
split selector compares Upper A/B, Lower A/B and Custom. The plain focus summary
includes muscles hidden in the current view. Covered glutes are text-only.

The static neutral character material belongs to this one illustration. It does
not replace controls or imply measured fatigue, readiness or recovery. Preserve
full-body head/hands/feet, organic anatomy and readable workout context beside a
direct Start action. Avoid angular badge silhouettes, esports emblems, gym
pictograms, Greek letters, columns, gold, neon, glow and decorative scores.

## Component comparison

| Component / current problem | Proposed treatment | Preserved behavior |
| --- | --- | --- |
| Today: a tiny abstract mark has little relationship to training. | One full-body sculptural glyph map with source-derived contours, mock split focus, Front/Back and a plain focus summary. Keep workout context and Start visually direct. | Profile, rotation/day choice, workout details, week/custom choice, statistics, PRs and target rows remain available. |
| Rest: character rows add visual weight without helping the readout. | A quiet 2px coral line, calibrated ticks and 0:00/2:00 endpoints; exact timer primary and only the + symbol accented. | Pinned header, countdown, rested state, next set, +30s and Skip; current fallback to workout-set progress outside rest. |
| Weight: layered panels and strong color compete with the selected value. | A quiet tape with tiered type/ticks, one center index, small unit, dotted field marker/leader and a clear tap-to-type cue. | Drag/fling, slow-drag fine scale, modal typing, kg/lb conversion, haptics and exact off-step values such as 72.5. |
| Buttons: repeated borders and similar visual weight flatten priority. | One inverse primary action, quiet filled secondary controls, quiet text actions and labeled destructive intent. | Existing actions, validation, loading/disabled states, focus and touch targets. |
| Icons: destination dot grids feel too close to the reference brand. | Author a shared thin-line destination family with arcs and axes; keep simple line utilities. | Recognizable meanings, visible labels and menu access; the navigation exception is explicit below. |
| Bottom navigation: the raised center pedestal dominates the bar. | Five level destination slots with Today centered and a quiet selected backplate. | Owner-approved Progress · History · Today · Plan · Profile. Start stays on the Today card; Log is unchanged. |
| Live workout: identity could crowd fast entry. | Compact text branding; strong working values, clear set states and restrained rules. | One live set, logged/pending rows, post-log RIR, fixed Log bar, exercise/session menus, minimize and resume. |

## Priority and material placement

| Priority / location | Material use | Limit |
| --- | --- | --- |
| P1 · Active set and Log | Precise typography, ruler ticks, flat fill and hairlines. | No decorative art, glyph substitution or animated labels near live entry. |
| P1 · Rest | A 2px coral line proportional to remaining time. | Exact readable time remains primary; no character texture or animation. |
| P1 · Navigation and buttons | Consistent geometry, contrast and action hierarchy. | Keep every destination label; ordinary values and utility actions stay readable. |
| P2 · Today | One sculptural glyph image, initially about 160–200dp high in a phone study. | Let the image breathe while retaining a readily reachable Start; do not compress all existing content into cards. |
| P2 · App canvas | Sparse static square dots in exposed margins and gaps. | Reading surfaces and charts stay solid; dots encode no data. |
| P3 · Existing empty library | Optional small static material vignette beside the existing explanation/action. | Candidate for later review; exercise creation and its workflow stay outside this study. |
| P3 · Workout completion | Optional still of the same subject after the result is available. | Candidate for later review; no invented reward, readiness score or delayed result reveal. |

Use one visual subject and one glyph vocabulary rather than unrelated effects
on each screen. Progress charts, history rows, backup/recovery messages and
settings benefit from the typography and spacing; they do not need extra art.

## Rest and other measured progress

Owner review found that the ASCII rows did not improve the rest indicator.
The proposal now uses a 2px CSS track with a coral fill whose width is exactly
`84 / 120 = 70%`. The plain `1:24` and ARIA value remain authoritative. There
is no rest canvas, glyph renderer or font dependency.
The range below it uses nine ticks at exact 15-second intervals and `0:00` /
`2:00` endpoints. Line, ticks and labels use one shared inner width and origin.
The labels calibrate remaining time; they do not reinterpret 70% as elapsed
progress. The plus in `+30s` uses coral while the duration text stays neutral.

This representative moment is static, without a timer or animation. The future
native adaptation must retain remaining/rest-total, +30s, Skip, expiry, rested
count-up and the switch to workout set progress, using their real existing
state. Those behaviors are not executed by this mock. Volume rows retain their
real synthetic numerator/denominator labels, including `0/6`; missing values
must stay distinct from zero.

## Weight, reps and RIR

Keep the ruler recognizable as a measuring instrument. Use a hairline baseline,
major/minor ticks and one center marker; neighboring numerals recede without
blurring. The center `72.5` and unit must fit without rounding or truncation.
Retain a textual “Tap value to type” cue; plus/minus drawings must not imply
replacement controls. Reps uses the same family with its existing integer scale.
The selected number stays at 32px, inner neighbors at 13px and outer neighbors
at 12px so the gap around `72.5` remains legible. Added breathing room and
5/9/14/20px quarter/half/major/center tick lengths give the flat tape hierarchy.
Minor marks recede, major marks stay clear and only the center index is coral.
Weight retains 1kg labeled intervals and quarter-step minors; Reps retains only
integer ticks. Neither scale nor exact index position changes.

Small authored square-dot SVG fields in coral precede Weight and Reps. They are
decorative field identifiers, not controls or dataset symbols. Dotted leaders
fill the space to their right, yielding to the full typing cue at narrow widths.
The owner's generated ruler image informs this hierarchy only; its perspective
walls, glow and dense rendered material are not adopted into the flat system.

Presentation must retain display-unit coarse/fine steps, drag/fling and snap,
off-step anchoring, haptic feedback and the modal numeric sheet. Pending input
and gliding rulers must settle before Log or a live-set change acts on values.
RIR remains a post-log correction, `0–5`, with visible selected state and the
current balanced wrapping. Do not move it into the unlogged set or rewrite
restored values outside the current range. Preserve fixed rest and Log regions.

## Buttons and dedicated icons

| Variant | Treatment and examples |
| --- | --- |
| Primary | Off-white fill on black, dark text, 8dp corners; Start workout and pinned Log. One dominant action per working region. |
| Secondary | Quiet solid inset fill and clear text; +30s, Skip and existing secondary choices. |
| Quiet | Text with an optional family icon; subordinate navigation or existing low-emphasis actions. Keep the complete touch slot. |
| Destructive | Explicit action wording and existing semantic error treatment; preserve confirmation. Never communicate danger only by color. |
| Icon action | A 20–24dp drawing centered within at least a 48×48dp target; accessible action name and visible focus. |

All variants share type, corner logic and predictable pressed/focus/disabled
states. Pressed feedback is a flat state change; no scale, glow or glyph scramble.
Loading reflects actual work, keeps its label context and prevents duplicate action.

The owner rejected the bracketed treatment. Add exercise and Custom use the
plain plus; minimize, collapse and navigation keep their familiar directional
drawings. App actions remain static, with no new interaction implied.

Destination pictograms use a common 24-unit viewBox and 1.4-unit strokes with
round caps/joins and no filled areas. Progress combines an axis and rising trace,
History a returning clock arc, Today a house with an arched doorway, Plan a
calendar and Profile a head/shoulder arc. They draw at 24px inside slots at least
48px wide. The menu, chevrons, check, keyboard and plus retain their consistent
1.75-unit line family. No icon font, raster mark or network asset is needed;
authored SVG geometry is local and decorative to the visible labels. No new
measurement scale or numeric value is introduced by the pictograms.

The official [Nothing Weather store screenshots](https://play.google.com/store/apps/details?hl=en_US&id=com.nothing.weather)
provide the visual reference: the UV wireframe and wind compass use fine arcs,
axes and sparse colored indices. That diagram discipline informs the authored
destination family; the reference brand's dot-matrix pictograms are not the
direction. No Nothing assets, logos, fonts or weather diagrams are copied.
The existing typography, neutral palette and source-derived body map
remain the proposal's own material.

## Bottom navigation

The owner explicitly approved **Progress · History · Today · Plan · Profile**
for this T1 revision. All five destinations share equal level slots, visible
labels and one opaque bar with a top hairline. Today is centered and selected
with a quiet neutral circular backplate. There is no navigation Start action,
play symbol, floating action button or pedestal. Start workout remains on the
Today card and the active workout's pinned Log action is unchanged.

Profile already exists through the avatar, which remains an alternate path.
This is a navigation composition, with static app affordances and no new Profile
screen or routing implementation. Native safe areas, accessible tab state,
localized labels, text scaling and minimize/resume remain later checks.

## Accepted baseline and next phase

The implemented body-card experiment uses one unmodified grayscale front/back
source, locally sampled into stable Space Mono characters. Its approximate
regions follow source anatomy; the raster determines the actual silhouette.
No asset selection, medical accuracy or native performance is claimed. See the
[proposal README](README.md) for the mock assignments, source hash and limits.

The previous generated UI concept was not selected. Rest, ruler, button, icon
and navigation studies are now represented in the editable proposal alongside
the body card. The rest line is statically filled to 84/120, ruler numerals
share their exact centers with the index, primary labels stand alone, and the
five navigation slots share a level bar. The active-workout composition and
exact values stay intact; the explicit owner-approved navigation exception
applies only to this web study. The owner accepted the integrated baseline on
2026-10-21 after removal of the bracketed plus. Next is T2 foundations and Flutter
adoption under the existing approved plan; T2–T5 have not started. Animation and
other dynamic details are deferred. No phone installation, APK work, dataset
change or saved state is part of this acceptance. Native accessibility and
performance remain later work.

Static artwork is the current decision. No glyph drift, pause control or timing
machinery is needed for this meaningful focus encoding. Ordinary copy, controls,
values and the source silhouette remain stable.
