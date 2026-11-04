# Catalog selection source and host evidence — 2026-11-01

This records U3 implementation evidence for the usability/history plan. The
source baseline is `09cc85c`; it does not identify an installed Android build.
All inputs below are independently authored synthetic fixtures.

## Source trace and changes

`showExercisePicker` already materialized a concrete choice without a library
prerequisite. Its catalog picker initially showed a discovery home instead of
results. Workout entry now requests immediate selection: All shows concrete
executions, a tap returns that choice, and previously used named contexts remain
available. Plan editors retain their ordered multi-occurrence basket. Selecting
a variant does not require a new personal equipment nickname. The catalog
measurement profile is fixed by that concrete variant; this change introduces
no extra measurement confirmation.

Favorites, Recent and personal exercises are exclusive views. Muscle, Activity
and Equipment have separate selectors below them, with visible active scope,
result count and Clear filters. Clearing filters retains the query/view. Muscle
and Activity selector choices are separated; unclassified remains available.
Existing controller snapshots retain query, scope, navigation and scroll across
browser remounts, and back from details retains the parent position.

The synchronous immutable index cached labels but finding the identifying label
for each previously unseen row still scanned every variant. It now builds one
label-to-siblings map per index. The existing index identity fences bundle,
browse revision, profile/generation, locale and effective personal vocabulary.
The existing bounded query cache, deferred typing refresh and lazy sliver rows
remain. Row distinctions group visible siblings by family once per build.

## Host samples and limits

`catalog_selection_usability_test.dart` prints diagnostic microseconds for a
513-variant synthetic fixture. One baseline sample recorded index construction
25,417; cold identifying labels for all variants 44,601; warm labels 27; cold
browse 18,159; warm browse 31; six query prefixes 8,375 / 3,083 / 1,579 / 3,298 /
1,573 / 996. With grouped labels, one subsequent sample recorded construction
29,975; cold labels 6,965; warm labels 56; cold browse 20,811; warm browse 29;
prefixes 8,695 / 3,790 / 1,523 / 6,414 / 1,151 / 1,169.

These are single host/JIT diagnostic samples, not speed thresholds, distributions
or a claim of Android improvement. Only the repeated label scan was removed;
index construction and search changes are not claimed from those noisy samples.
The host does not establish cold/warm Android opening, storage admission,
keyboard-to-feedback latency, scroll/add distributions or p95 frame time.
A5's named-device/build targets remain open until separately measured. Standard
Flutter profiling should separate SQLite materialization, index/search CPU and
build/layout/raster costs, and retain repeated runs and failed targets.

The final focused run of `make -C app test TEST='test/catalog_ui test/catalog
--concurrency=2 --reporter expanded'` passed **188 tests**, with no skipped tests.
Explicit-path formatting and `git diff --check` passed for the U3 paths.

Focused checks cover single-tap return without enrollment or basket, favorites
with reversible filtering/query retention, named-context repeat-add, lazy rows,
query-cache parity/invalidation and back/remount behavior. Existing browser and
picker layout checks render 320/412dp, 2x text, both themes and en/it/de/es. Host
layout assertions do not replace Android renders or TalkBack qualification.

The generic [gap review rubric](catalog-gap-review.md) separates vocabulary,
filtering, metadata, definition and ambiguity. Supplied personal names and their
reviewed mappings remain outside this repository. No catalog dataset was added
and no universal completeness claim is made.
