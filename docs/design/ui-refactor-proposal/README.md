# Alkion UI proposal

2026-10-21 · T1 representative visual baseline accepted by owner.
Open [index.html](index.html). No installation, dependency, CDN or network request
is required. Dark/Light changes both compositions. The **Mock split** review
selector changes only Today's card; **Front/Back** changes its illustration.
Each phone scrolls. Keyboard users can Tab to controls and scroll regions, use
native select keys and activate view buttons with Space/Enter.

This is a **web visual proposal**, not the Flutter app or an Android capture.
Every value, initial, date and record is synthetic. The compositions show two
separate moments: Today before starting and the workout after its first logged
set, during the brief RIR correction window. App affordances remain static
without enabled button/input semantics. There is no workout simulation, saved
preference, profile data, account, sync, transfer or saving promise.

The [component study](component-study.md) records the body-card direction and
the accepted rest, ruler, button, icon and navigation baseline. The owner
accepted the integrated proposal with a plain plus on Add exercise. Animation
and other dynamic details are deferred to later work.

## Native adoption

The accepted visual subset was adopted in Flutter on 2026-10-22 at `afdf9ca`;
T2–T5 are complete under the [plan](../../plans/2026-10-21-ui-design-system-refactor.md).
See [native acceptance](../../alkion/acceptance.md#ui-refactor-native-adoption-2026-10-22)
for focused checks, synthetic Android inspection and private APK verification
limits. Native navigation uses the five destinations below, with Start on Today.
The native body stays unfilled without a supported focus mapping and retains
actual saved focus text; the mock split assignments below remain web-only.
The calibrated rest line, ruler guides/integer rep ticks and quiet checked RIR
selection are adopted. Motion and other dynamic visual details remain deferred.
This artifact remains a static web proposal with synthetic content.

## App design brief

Make the existing workout app feel consistent and easy to read at a glance.
Preserve the logging workflow and study the owner-approved navigation revision.
Use black `#000000` in
dark mode; neutral `#F5F6F8` and white surfaces in light mode. Primary actions
use a neutral inverse fill. Coral (`#FF6835` dark / `#A82D00` light) marks
selected workout data and rotation identity; it is not a success/readiness score.

Space Grotesk 400/500 carries interface text. Space Mono 400 carries measured
values, time and the source-derived body illustration. No synthetic weight, DSEG,
shadow, blur or press scaling is used. Metadata is at least 12px. The three levels are page/workout
context, working content, then metadata. Corners are 8px for controls, 12px for
working panels and 16px for the review frame. Proximity and dividers group
content; the live set alone gets an explicit working boundary. Static square
dots (1.5px on a 24px pitch) appear in the outer review margins and inside both
app canvases, visible in margins and gaps. App reading surfaces remain solid.

## Mock body focus card

One full-body source panel is sampled locally into an 80×106 fixed character
grid. Runtime crops retain the head, hands and feet. The original grayscale
raster's luminance determines the visible silhouette and the shared
`@#S08Xx+=-;:.` Space Mono ramp; no geometric stand-in generates the body shape.
Cached, interpolated source-luminance hairlines keep the outer contour and
curved muscle/shading folds readable at this small size. These contours are
sampled at twice the glyph resolution; they do not trace the region polygons.
Both themes use their neutral text ink, with the light theme reversing the ink
against its white surface. No animation, timers, random drift or pause state.

Broad hand-traced source-coordinate regions separate chest, delts, biceps,
triceps, forearms, core, back, quads, hamstrings and calves. They are approximate
illustration masks, not a medical muscle map. Source pixels always clip those
regions. Primary areas have the densest characters; support uses a fixed lower
fill density. Unselected areas keep quiet source contours and sparse shading.
Custom retains unfilled outer and source-shading contours with no inferred focus;
face/hair interiors are unfilled. The same source mask is retained in every split.

| Review preset | Primary | Support |
| --- | --- | --- |
| Upper A | Back | Biceps |
| Upper B | Chest | Delts, triceps |
| Lower A | Quads | Core, calves |
| Lower B | Hamstrings | Glutes, calves |
| Custom | No focus selected | No focus selected |

The source's trunks cover the glutes. Their Lower B support is text-only, with
no invented muscle detail or filled glute mask. Every preset's plain primary /
support summary includes groups hidden by the selected front/back view. There
are no percentages, readiness, fatigue, recovery or body measurement claims.
These assignments and workout details are deterministic mock data; they do not
come from exercises, weekly volume or saved native state. The weekly schedule
and separate active workout remain independent static examples.

The canvas is decorative. Its text equivalent is ordinary readable HTML, and
view buttons expose their selected state through `aria-pressed`. Source,
font or canvas failure leaves an explicit compact unfilled fallback and the
complete textual focus summary. JavaScript failure retains the initial Upper B
text and an unavailable preview; controls requiring it begin disabled. No
fallback falsely presents a filled or computed muscle map.

## Component refinement

The rest header keeps the exact `1:24` readout and accessible `84 / 120`
remaining-time value. Following owner review, the character strip is replaced by
a quiet 2px track with a coral fill at exactly `70%`. The timer remains primary.
The line is ordinary CSS and needs no script, canvas or font to render. This
representative moment stays static, with no countdown or animation.
Nine ticks at 15-second intervals calibrate the remaining-time range from
`0:00` to `2:00`; line, ticks and endpoint labels share the header's inner width.
They describe remaining seconds, not elapsed progress. The plus in `+30s` is
coral while `30s` stays neutral inside the same quiet action slot.

Both rulers use off-white exact readouts, explicit small `kg` / `reps` units,
quiet neighbor values and a single coral center index. The numeric portion of
`72.5` is centered independently of its unit. Values and the tick baseline share
the same inner width; neighbors sit at 10/30/70/90%, with matching major ticks.
The 32px center, 13px inner neighbors and 12px outer neighbors keep the selected
number dominant without crowding its neighbors. More space around the value and
5/9/14/20px quarter/half/major/center ticks establish depth through size and
contrast; no perspective, glow, gradient or shadow is added. Coral square-dot
markers identify Weight and Reps, with flexible dotted leaders beside their
labels. The typing cue keeps its own width so the leader yields first.
The stacked narrow review spreads the inner neighbors to 25/75% and moves the
matching weight major ticks to 0/25/50/75/100%, hiding the outer labels and
clipping offscreen minor ticks. The scale stays uniform and the exact center
stays fixed.
Weight retains `70.5 / 71.5 / 72.5 / 73.5 / 74.5`; its fine divisions are quarter
steps in this anchored view. Reps has only integer ticks at `6 / 7 / 8 / 9 / 10`.
The plain typing cue remains; this static artifact does not implement native
drag, fine-scale or modal entry. Numbers and controls use ordinary text, never
glyph art.

Start workout and Log share a neutral inverse 56px primary treatment, real 500
weight and 8px corners. Clear labels carry these actions without redundant
lightning/check symbols. Rest actions use quiet filled 48px slots; Add exercise
is a quiet labeled 48px slot. RIR retains its balanced two-row `0–5` layout,
48px minimum slots and a check on selected `2` so selection has a shape cue.
The live set keeps its working boundary, while header menus, RIR choices and
secondary actions shed repeated outlines. The depicted app actions remain
static and outside keyboard focus; only review controls and scrolling work.
Add exercise and Custom use the plain plus. Minimize and collapse retain
directional chevrons. The owner rejected the bracketed treatment.

The opaque bottom bar has five equal level destination slots in the exact
owner-approved order: **Progress · History · Today · Plan · Profile**. Today is
selected in the center with a quiet neutral circular backplate and a visible
label. Start appears only on the Today workout card; the pinned Log action is
unchanged. The avatar remains an alternate Profile affordance. These static
navigation drawings do not implement routing or add a Profile screen.

The destination family uses authored 1.4-unit hairlines in a common 24-unit
viewBox, with round caps/joins and no filled areas: an axis and rising trace for
Progress, a returning clock arc for History, a house with an arched doorway for
Today, a calendar for Plan and a head/shoulder arc for Profile. These familiar
symbols use the same quiet instrument geometry without adding scales or values.
Every label remains visible in at least a 48px slot. Utility chevrons, menu,
check, keyboard and plus keep their simple 1.75-unit line family.

The visual reference is the official [Nothing Weather store screenshots](https://play.google.com/store/apps/details?hl=en_US&id=com.nothing.weather):
fine-line wireframe UV geometry and the wind compass demonstrate restrained
arcs, axes and sparse colored indices. This proposal applies that line discipline
to familiar Alkion destinations; it does not adopt the brand's dot-matrix icons.
No Nothing logo, image, font or weather diagram is copied or bundled. Space
Grotesk/Mono, the neutral themes and the approved body sculpture remain Alkion's
own direction. Component tokens retain the 4/8/12/16/24 spacing rhythm; coral
marks measured progress, indices, field markers, the rest increment symbol and
existing workout identity.

Body rendering, source contours, masks, presets, Custom and front/back remain
unchanged. This component pass does not implement Flutter behavior, finish
states, focus semantics for app actions, a running workout or native accessibility.

## T1 app source mapping

| Composition | Flutter authority and retained anatomy at T1 |
| --- | --- |
| Today | `app/lib/ui/today_screen.dart`, `today_labels.dart`, `widgets/split_card.dart`, `week_strip.dart`, `volume_bars.dart`: profile initials, next rotation/day picker, Start, selectable week/custom choice, bodyweight/sets/PRs, recent PR and volume/target rows. Rotation remains independent of scheduled weekdays. A target with no sets is explicitly `0/6`. |
| Navigation | `app/lib/shell/w_tab_bar.dart` was the four-destination/Start authority at T1. The approved Progress, History, Today, Plan, Profile order and Start on Today were subsequently adopted natively. Profile also remains reachable through the avatar. The web drawings themselves do not route. |
| Workout header | `app/lib/session/session_header.dart`: minimize, session/exercise menus, set count, elapsed time, rest countdown, +30s, Skip, next set and draining rest line. Header and Log bar stay outside the scrolling list. |
| Working content | `active_session_screen.dart`, `exercise_block.dart`, `live_set_card.dart`, `set_line.dart`: one live set, compact logged/pending rows, current exercise summary, collapsed later exercises, existing Add exercise affordance. In-session creation of a missing exercise remains deferred. |
| Exact entry | `set_values_editor.dart`, `widgets/ruler_picker.dart`: weight/reps rulers and center-value typing affordance. `72.5` is retained exactly, with the visible tape anchored at that off-step value. No replacement plus/minus controls. |
| RIR and logging | `widgets/rir_picker.dart`, `set_line.dart`, `log_set_bar.dart`: post-log in-flow correction, current **0–5** range, selected 2, balanced two-row picker, explicit `Log set 2 · 72.5kg × 8` action. The live-set spec's original 0–3 wording is historical. |

The [live-set spec addendum](../../superpowers/specs/2026-09-24-live-set-focus-design.md#addendum--first-device-test-2026-09-24)
and current code take precedence over the older handoff's simplified inputs.
RIR is shown under the just-logged set, not added to an unlogged live set.

## Native adaptations and limits

- Light inset controls and the focused set editor use the canonical sunken fill
  `#ECEEF2`; the artifact's local `--raised` name maps to this native adaptation.
  Ordinary light surfaces remain white. Volume/rest tracks use the canonical
  chart-grid color `#E2E5EB`; decorative dots retain their separate `#E1E4E9` role.
- Native adoption retains existing widgets, sheets and Android safe areas and
  maps this styling into Flutter tokens. The web frame is a 390×900 CSS-pixel
  review viewport,
  not device chrome. At narrow browser widths the board stacks without scaling
  the phones. Content scrolls; narrow statistics become rows and ruler neighbors
  recede while the exact center value stays visible.
- Android interaction slots remain at least 48×48dp, including RIR and menus.
  The RIR layout preserves the current balanced rows. Visual marks inside a row
  are not separate tap targets. The web navigation uses five equal slots, each
  at least 48px wide. Native navigation, safe-area and selected-state semantics
  are separate from these web drawings; see native acceptance above.
- Preserve native modal typed entry, display-unit conversion, haptics, zoom on
  slow ruler drag, commit-before-log/focus, rest retention, minimize/resume,
  undo, logged-set correction, finish/retry and accessibility semantics. These
  behaviors are not implemented or qualified by this static proposal.
- This slice shows populated English dark/light screens. Other locales, large
  text, native contrast/semantics, empty/failure states and device rendering
  are outside this static artifact; native evidence is recorded separately. The
  bodyweight history spark is omitted from this example; this proposal does not remove it from the app.
- The owner accepted this visual baseline on 2026-10-21. T2–T5 Flutter
  adoption is complete as recorded above. Animation and dynamic details remain
  deferred; this web artifact itself implements no production behavior.

## Local font provenance

Font bytes are unmodified. All use SIL OFL 1.1; notices are bundled alongside
the fonts. Upstream links document provenance only and are not fetched at runtime.

| Asset | Metadata / upstream | License |
| --- | --- | --- |
| `assets/SpaceGrotesk-Variable.ttf` | Version 2.000; `wght` 300–700; default family metadata “Space Grotesk Light”. CSS declares the actual range and uses only 400/500. [Google Fonts](https://github.com/google/fonts/tree/main/ofl/spacegrotesk), [project](https://github.com/floriankarsten/space-grotesk). | [SpaceGrotesk-OFL.txt](assets/SpaceGrotesk-OFL.txt) |
| `assets/SpaceMono-Regular.ttf` | Version 1.003; real weight 400. [Google Fonts](https://github.com/google/fonts/tree/main/ofl/spacemono), [project](https://github.com/googlefonts/spacemono). | [SpaceMono-OFL.txt](assets/SpaceMono-OFL.txt) |

SHA-256:

```text
acad6de1fc93436f5c0f1f4137751ef04f1aea3063e7036535970ffcfbd79f72  SpaceGrotesk-Variable.ttf
95837e182baeeada83368f7748db28357f0a1b75c6b84ff7065b5edf933c8e18  SpaceMono-Regular.ttf
```

The Grotesk notice includes its complete upstream OFL text; no font was modified.
Icons are authored SVG geometry; the destination hairlines and utility family are
described above.

## Body source provenance

[assets/body-sculpture-source.png](assets/body-sculpture-source.png) is a
first-party AI-generated grayscale source made on 2026-10-21 for this mock,
informed by the owner's sculptural styling reference. It contains separate
front/back full-body views on black; it is source artwork, not a generated UI
screenshot. The PNG is copied unchanged: 1254×1254 RGB, 1,199,111 bytes. Cropping,
masking and character conversion happen in the browser. No image service or
external asset is fetched at runtime. This experiment does not approve the
artwork for adoption or make a broader license grant.

```text
3adbff9fee26530bef0d911259aa56f93d1e5d9df3649979d44edf6c1ded4211  body-sculpture-source.png
```
