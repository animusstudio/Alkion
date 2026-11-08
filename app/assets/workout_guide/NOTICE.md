# Workout Guide media: kept in source, not bundled

Since 2026-11-08 Alkion no longer shows these movement frames, and the app
bundle no longer declares or ships anything in this directory. The frames,
SVG masters, manifest and upstream notices stay in the source repository with
their provenance, so the reviewed subset can be verified or reused.

- `ATTRIBUTION.md`, `LICENSE-ASSETS.txt`, `LICENSE-CODE.txt` and `LICENSES.md`
  are unchanged copies of the upstream notices, pinned by digest in
  `manifest.json`. Their terms still apply to every copy of these files,
  including this source tree.
- The artwork is **CC BY-SA 4.0** (Everkinetic and Bryl Lim). It is not owner
  exercise artwork, and the application's software license does not cover it.
- `app/tool/prepare_workout_guide_media.py` verifies the retained files and
  fails if `app/pubspec.yaml` declares any of them again.

See [exercise media](../../../docs/alkion/exercise-media.md) and
[licensing](../../../docs/alkion/licensing.md).
