# Alkion

<p align="center">
  <img src="docs/assets/brand/alkion-banner.png" width="800" alt="Alkion by Animus, with a classical bust formed from characters">
</p>

Alkion, by Animus, is a pre-1.0 workout app for Android with a Linux development
target. It works locally without an account or backend. Workouts, history,
training plans and settings live in a profile-scoped SQLite store.

The app includes workout logging and resume, rest notifications, an editable
exercise catalog, history and progress views, manual backup/restore, and reviewed
local transfer/import workflows. Originals and uncertain recovery state remain
separate from corrections and derived results. Replicas are not backups.

An explicitly configured [optional Animus connection](docs/alkion/animus-connection.md)
adds browser sign-in, account/space confirmation and a foreground read-access
check at first use or later in Profile. A separate confirmed History action can
[manually send one supported native workout](docs/alkion/animus-workout-upload.md)
and its required exercise definitions. First use also offers Go fully offline,
then Start new/Restore backup; existing profiles open directly. Default builds
and local workout use remain account-free and offline. Automatic/background
sending, bulk history attachment, replica downloads and OTA updates remain
separate work. Final release identity and signing remain open; this repository
does not publish signed APKs or backend images automatically.

## Development

Use the existing [FVM](https://fvm.app/) installation and the committed Flutter
3.44.0 pin. From the repository root:

```sh
make -C app get
make -C app analyze
make -C app test TEST=--concurrency=2
make -C app format
make -C app build
make -C app build-apk
```

Dependency resolution is offline and locked. `format` checks without changing
files. `build` produces the Linux bundle; `build-apk` produces the development
flavor's debug APK. Android builds need the Android SDK, Java 21 and an explicitly
selected disposable `ANDROID_USER_HOME` for debug signing. They do not install or
launch an app. See [app development](app/README.md) and the
[development guide](docs/alkion/development.md) for boundaries and qualification.

For a fresh checkout and optional private body artwork, see
[continuing development](docs/alkion/continuing-development.md).

## Source layout

- `app/lib/`: local store, domain workflows, backup/recovery/transfer and Flutter UI.
- `app/test/`: unit, widget, real SQLite and synthetic fixture tests.
- `app/tool/`: focused local SQLite, backup and transfer qualification tools.
- `scripts/`, `tests/`: retained capture evidence validation.
- `docs/alkion/`: current architecture, contracts, acceptance and owner gates.
- `docs/history/`, `docs/superpowers/`: source provenance and dated design history.

The bespoke Android campaign framework was retired on 2026-10-20; its source
and dated results remain in Git history. See the [retirement note and manual APK
smoke checklist](docs/alkion/android-smoke.md). Host tests do not qualify device behavior.

## Legacy Reps

v0.18.1 is the final legacy Reps release. Its Go backend, PowerSync service,
deployment stack, old API and release workflows have been removed from current
source. [Exact retirement provenance](docs/alkion/legacy-retirement.md) preserves
required non-runtime schema/protocol fixtures and immutable source references.
The full Git history and dated capture qualification evidence remain available.
This source cleanup does not shut down a running service or authorize live data
migration, READY, deployment or a release.

## License

[MIT](LICENSE). Bundled fonts retain their OFL notices.
