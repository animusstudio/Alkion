# Alkion glyph sources

Alkion uses the **regular** Iconoir outline set, pinned to
[`39834e3f193bc0cca2c36bebb6a650471977433d`](https://github.com/iconoir-icons/iconoir/tree/39834e3f193bc0cca2c36bebb6a650471977433d).
MIT, copyright (c) 2021 Luca Burgio. `sources/LICENSE` retains the exact notice;
`assets/icons/NOTICE` carries it in the app bundle.

`manifest.json` records every semantic role, asset name and directional role.
Its `assets` table records immutable upstream URLs and original SHA-256s;
`sources/` holds unmodified Iconoir SVGs. The separate `custom_assets` table
records original Alkion authorship, license, provenance and digests for `custom/`.
Both source directories stay **outside** the Flutter asset bundle. `derivatives.json` records hashes of
the two generated SVG subsets and bundled notice. Only the runtime subsets and
notice are listed in `pubspec.yaml`.

From the app directory, reproduce or verify without network access:

```sh
python3 tool/generate_iconoir_assets.py
python3 tool/generate_iconoir_assets.py --check
python3 -m unittest discover -s tool -p test_generate_iconoir_assets.py
```

The generator changes only stroke-width attributes, including explicit
path-level overrides (Pause and Archive). It preserves each viewBox, geometry,
fill, cap and join. Every stroked descendant receives the tier's width. Values
are **24-unit viewBox units**, not rendered pixels: 1.25 below 32 logical pixels,
1.0 at 32 and above. `AlkionIcon` keeps noncanonical sizes, enforces a 16px floor,
uses IconTheme size/color/opacity/text scaling, and uses the documented
`SvgPicture.asset` color filter for current-color SVGs. An omitted semantic label
makes the glyph decorative; controls keep their own localized semantics.

`flutter_svg` is pinned to 2.3.2 (Dart ^3.11.0, Flutter >=3.41.0), compatible with
FVM Flutter 3.44.0. Rendering follows the package's official
[asset and tint documentation](https://pub.dev/packages/flutter_svg/versions/2.3.2).
No source loading, SVG rewriting or network access occurs at runtime.

## Semantic mapping

The original app-authored inventory at `09cc85c` contains direct Material
references, the WIcons aliases, five destination painter roles, and IconData
fields in action sheets, steppers, prescription/progress controls, active
sessions, History and Profile. The complete replacement vocabulary is below.
Today uses `home`; Profile uses `profile`. Core additions `library` and `pause`
are included alongside all existing aliases. Semantically distinct meanings
remain distinct enum values, even where a historical Material glyph was shared
(e.g. Plan and settings).

| AlkionGlyph | Bundled SVG stem | RTL mirror |
| --- | --- | --- |
| `home` | `home-simple` | No |
| `workout` | `gym` | No |
| `plan` | `calendar` | No |
| `history` | `clock-rotate-right` | No |
| `progress` | `graph-up` | No |
| `library` | `book-stack` | No |
| `settings` | `settings` | No |
| `add` | `plus` | No |
| `edit` | `edit-pencil` | No |
| `delete` | `trash` | No |
| `play` | `play` | No |
| `pause` | `pause` | No |
| `profile` | `user` | No |
| `back` | `arrow-left` | Yes |
| `forward` | `arrow-right` | Yes |
| `check` | `check` | No |
| `minus` | `minus` | No |
| `timer` | `timer` | No |
| `energy` | `flash` | No |
| `scale` | `weight` | No |
| `language` | `language` | No |
| `chevronRight` | `nav-arrow-right` | Yes |
| `search` | `search` | No |
| `target` | `position` | No |
| `logout` | `log-out` | Yes |
| `cloud` | `cloud` | No |
| `arrowUp` | `arrow-up` | No |
| `flame` | `fire-flame` | No |
| `share` | `share-android` | No |
| `capture` | `archive` | No |
| `update` | `download` | No |
| `refresh` | `refresh` | No |
| `more` | `more-horiz` | No |
| `close` | `xmark` | No |
| `chevronUp` | `nav-arrow-up` | No |
| `chevronDown` | `nav-arrow-down` | No |
| `reorder` | `menu` | No |
| `accessibility` | `accessibility` | No |
| `error` | `warning-circle` | No |
| `undo` | `undo` | Yes |
| `favorite` | `star` | No |
| `info` | `info-circle` | No |
| `list` | `list` | No |
| `imageUnavailable` | `media-image-xmark` | No |
| `bicycle` | `bicycle` | No |
| `run` | `running` | No |
| `cable` | `alkion-cable` | No |
| `machine` | `alkion-machine` | No |
| `rope` | `alkion-band` | No |
| `current` | `check-circle` | No |
| `inDay` | `list-select` | No |

Only navigation/action directions mirror: back, forward, trailing disclosure,
logout and undo. Play, history and refresh preserve their conventional shape;
vertical arrows and reordering remain unchanged. Reorder uses the three equal
horizontal bars in `menu`: upstream `drag` is a four-arrow move symbol and
`drag-hand-gesture` a hand, rather than a grip.

## Caller inventory migration key

All historical WIcons aliases are accounted for:

| Previous WIcons | Semantic replacement |
| --- | --- |
| back, check, minus, timer, history, home, scale, plan, search, edit, target, logout, cloud, arrowUp, flame, capture, update, refresh, more | Same enum name |
| plus | add |
| bolt | energy |
| dumbbell | workout |
| chart | progress |
| gear | settings |
| globe | language |
| trash | delete |
| chevron | chevronRight |
| user | profile |
| export | share |
| resume | play |

Direct app-authored Material references are accounted for:

| Previous Icons | Semantic replacement |
| --- | --- |
| accessibility_new | accessibility |
| add | add |
| arrow_back / arrow_forward | back / forward |
| bolt | energy |
| check | check |
| chevron_right | chevronRight |
| close | close |
| cloud_outlined | cloud |
| delete_outline | delete |
| drag_handle | reorder |
| edit_outlined | edit |
| error_outline | error |
| expand_less / keyboard_arrow_up | chevronUp |
| expand_more / keyboard_arrow_down | chevronDown |
| fitness_center | workout |
| history | history |
| home_outlined | home |
| inventory_2_outlined | capture |
| language | language |
| local_fire_department_outlined | flame |
| logout | logout |
| monitor_weight_outlined | scale |
| more_horiz | more |
| my_location | target |
| north | arrowUp |
| person_outline | profile |
| play_arrow_rounded | play |
| refresh | refresh |
| remove | minus |
| search | search |
| share_outlined | share |
| show_chart | progress |
| system_update_outlined | update |
| timer_outlined | timer |
| tune | settings (the historical Plan alias becomes plan/calendar) |
| undo | undo |

The five former destination painter roles map to home, plan, history, progress
and profile, retaining caller order and selected treatment. Framework-generated
platform glyphs are outside the authored inventory.

## Historical catalog integration inventory (2026-11-04)

The published catalog integration at `116cd01342a6e79936bcb150bb0cbbe8159a5db2`
adds eleven semantic roles. The resulting subset has **51 roles, 50 upstream
originals and 100 runtime derivatives**. Machine reuses the existing settings
source, while keeping its own semantic enum value. These sources remain covered
by the separate Iconoir MIT notice; they are not relicensed by the application
software grant.

| Previous Icons | Semantic role | Mapping rationale |
| --- | --- | --- |
| star / star_border | favorite | Outline star; the badge is present only when favorited, retaining a shape/presence cue independent of color. Action rows retain their localized favorite label and selected state. |
| info_outline | info | Circled information symbol. |
| list | list | Plain list, distinct from membership status. |
| image_not_supported_outlined | imageUnavailable | Image with an x, identifying unavailable media. |
| pedal_bike_outlined | bicycle | Bicycle silhouette. |
| directions_run_outlined | run | Running figure; cardio-machine scanning aid, not an equipment identity claim. |
| cable_outlined | cable | USB cable/connector symbol, closest to the original cable/connector silhouette. The upstream cable-tag is a power label, not a cable. |
| precision_manufacturing_outlined | machine | Gear/mechanism symbol: no strength-machine or Smith-machine silhouette exists in this pinned subset. The localized equipment name remains authoritative. |
| gesture_outlined | rope | Infinite loop, conveying a looped band/rope without an electronic-cable symbol. |
| radio_button_checked | current | Circle with check, for the explicitly labelled current selection. |
| playlist_add_check | inDay | List with check, retaining a distinct day-membership shape. |

Equipment is a scanning aid; localized names remain in row semantics and details.
The machine mechanism glyph and looped rope glyph intentionally convey broad
categories rather than inventing an exact equipment drawing. None of these
roles mirrors in RTL: status, media, sports/equipment and list symbols keep their
conventional orientation. The current circle-check and in-day list-check remain
different shapes. All adapter sizes retain the same 16px minimum.

## Reviewed category extension (2026-11-05)

The current bundle has **91 semantic roles, 48 Iconoir originals and 42 original
Alkion drawings**, generating **180 runtime SVGs**. `usb` and `infinite` were
retired as equipment substitutes. The older `rope` semantic alias now uses the
original Alkion band drawing; category callers use the specific `band` role.

`custom/alkion-*.svg` are original Animus Studio geometric recognition symbols,
authored 2026-11-05 and licensed **AGPL-3.0-only** with the application software.
They are not attributed to Iconoir and are not covered by Iconoir's MIT grant.
The bundled NOTICE separates the grants; no upstream file was edited or used as
a custom source. Geometry uses a 24-unit viewBox, round caps/joins and no fills;
the same generator emits 1.25/1.0 stroke tiers without changing the geometry.

The reviewed mapping lives in `lib/catalog_ui/catalog_equipment_icon.dart`.
All 30 current equipment kinds, 13 muscle groups and 3 activity groups have an
explicit role; unknown/future values retain a neutral fallback. Each equipment
and group category has a distinct glyph within its category set. Muscle symbols
are schematic region marks rather than anatomical or technique evidence. Labels
remain visible and supply accessibility semantics. No direction mirrors in RTL.

| Category | Glyph recognition cue |
| --- | --- |
| bodyweight / none | Pinned accessibility figure / crossed empty equipment frame |
| dumbbell / bicycle | Pinned gym outline / bicycle |
| conditioning | Pinned running figure |
| barbell / axle | Thin straight shaft / thick straight shaft |
| EZ / neutral-grip / safety / trap bar | Zigzag / parallel handles / padded neck and handles / hexagonal frame |
| cable / machine / Smith machine | Pulley and hanging load / seated station / guided horizontal bar |
| band / jump rope / battle rope | Elastic loop / handled U / two waves |
| kettlebell / plate / medicine ball / Atlas stone | Handle and bell / center hole / curved ball seams / solid stone outline |
| ab wheel / wrist roller / hand gripper | Vertical rolling wheel / shaft and suspended load / spring and two handles |
| landmine / dowel / sled / yoke / tire / sandbag | Anchored angled bar / plain rod / runners and posts / carry frame / treaded ring / handled sack |
| cardio machine | Treadmill base and console |
| chest / back / shoulders | Paired pectorals / scapular outline and spine / shoulder caps |
| biceps / triceps / forearms | Flexed arm / rear upper arm / tapering lower arm |
| quads / hamstrings / glutes / calves | Front thigh lobes / rear thigh tendons / paired hip lobes / lower-leg taper |
| core / adductors / abductors | Segmented abdomen / inward / outward thigh arrows |
| mobility / whole body | Stretching figure / open full-body figure |

`catalog_category_glyph_test.dart` checks mapping coverage, distinct roles,
localized labels, decorative semantics and theme/stroke rendering. Its compact
proof plate uses actual 20/24/40px sizes in both themes. To retain disposable host
captures, set `ALKION_CATEGORY_CAPTURE_DIR=/tmp/<fresh-directory>` when running
that test through `make -C app test`. Host plates establish glyph legibility;
they do not qualify Android performance or gestures.

Family/collection previews use the separate explicit
`catalogRepresentativeVariantKeys` table in `catalog_artwork.dart` (147 families,
4 collections). These decorative previews reuse admitted owner illustrations,
independently of locale and row sorting. They do not register the family as an
exact execution or change `catalogArtworkForVariant` identity checks. The family
thumbnail carries no equipment badge because its children can use different kit.
