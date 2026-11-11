# Latest artwork review filter and ordering

Date: 2026-11-11. Lane: Standard. Status: Approved by the owner's direct
request to filter/order newly generated images.

## Outcome

Let the owner show only the latest regenerated images in the existing numbered
HTML library and order them with newest artwork first. Preserve permanent
numbers, edition comparison, search, source provenance and regeneration marks.

## Decisions

- Latest means the reviewed owner-marked regeneration: source illustrations
  2021–2360, currently 77 male and 93 female selections. Publish this explicit
  cohort as small library metadata, never derive it from mutable queue marks.
- Add a Show control (all images / latest regenerated) and an Order control
  (exercise number / newest artwork first). Newest uses descending source
  illustration with permanent number as a deterministic tie-breaker.
- Default stays all images in permanent-number order; shareable URL state can
  open the latest-only/newest view directly. Edition changes reapply both.
- Search composes with the filter. Inspection navigation follows displayed
  order. Explicit edition comparison keeps the exercise identity; navigation
  is disabled if its counterpart is outside the filtered set.
- Preserve the incumbent typography, colors and card layout. This is the web
  review utility, not an Android feature or redesign.

## Acceptance

1. Latest-only shows exactly 77 male or 93 female images from the current
   cohort; changing or removing marks cannot change cohort membership.
2. Newest ordering updates both the visible DOM and previous/next navigation;
   exercise numbers, image files and saved queue bytes remain unchanged.
3. Search, clear/empty states, edition switching and URL reload/deep links work
   with each view. Mobile controls remain readable and operable.
4. Gallery data remains deterministically generated and validated. Source
   metadata is explicit; stale/inconsistent cohort declarations fail safely.

## Task and checks

One Sol high implementation task; independent Sol medium diff/acceptance review.
Own gallery HTML/CSS/JS, cohort metadata, generator, focused tests and usage docs.
Run focused Python generator tests and existing offline/queue browser suites,
then inspect desktop and narrow screenshots in one batched pass. No asset
regeneration, queue writes, runtime app changes, public push or installation.

State: Done. Implementation and independent review passed.

Qualification:

- Nine generator tests and nine helper tests passed; deterministic generation
  validates 760 exercises and 1,520 edition selections.
- Offline and disposable-queue browser suites passed, including composed
  search/filter/order, 77/93 membership, DOM/navigation ordering, reload/deep
  links, outside-filter focus and missing-cohort error handling.
- Desktop and 360px live screenshots passed in a bounded initial/confirmation
  pair. Live verification used GET only and preserved all 170 saved marks.
- Existing artwork item data is unchanged beyond the explicit cohort metadata;
  no image, manifest, registry or app-runtime changes are included.
