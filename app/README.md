# Alkion app development

The account-free Alkion runtime stores local profiles, workouts, settings and
immutable outbox entries in SQLite. Backup/restore and transfer preserve original
bytes and uncertain recovery state. No backend, account, synchronization sender
or update transport is required or enabled.

## Toolchain and checks

Flutter is pinned to 3.44.0 in [`.fvmrc`](.fvmrc). Use an existing FVM installation
and run every local Flutter/Dart command through Make from the repository root:

```sh
make -C app get
make -C app alkion-toolchain
make -C app analyze
make -C app test TEST=--concurrency=2
make -C app test TEST=test/path/to/focused_test.dart
make -C app format
make -C app build
```

For a fresh machine, install the pinned SDK with FVM from `app/`, then use
`make -C app get-online` from the repository root once to populate dependencies
with the committed lock enforced. See
[continuing development](../docs/alkion/continuing-development.md).

`get` resolves offline with the lock enforced. `format` checks without writing;
`fmt FORMAT_FILES=...` formats explicitly owned files. `build` creates the Linux
bundle. Tests use disposable fixtures, including actual standalone SQLite;
they do not need PostgreSQL, PowerSync or a Go service.

For a normal development APK, select an explicit disposable Android user
directory for the debug key, with Android SDK and Java 21 configured:

```sh
ANDROID_USER_HOME=/tmp/alkion-debug-user make -C app build-apk
```

The default flavor is `dev` (`dev.animusstudio.alkion.dev`, Alkion Dev);
`ALKION_FLAVOR=supported` selects `dev.animusstudio.alkion`. These commands build
only. They do not select a device, install or launch an app.

For an optimized, private release-mode test APK (dev package, arm64 only), reuse
the **same disposable Android user directory and debug certificate** as the
installed development APK:

```sh
ANDROID_USER_HOME=/tmp/alkion-debug-user ALKION_LOCAL_RELEASE_TEST=1 \
  make -C app build-apk-local-test-release
```

This opt-in uses release-mode compilation with disposable debug signing.
Gradle permits only `assembleDevRelease` for this route;
supported-flavor release builds and bundles remain blocked. Without the opt-in,
all release tasks remain blocked. Builds never read inherited `key.properties`;
final release identity/signing remain separate owner decisions.

## Source map

- `lib/main.dart`, `lib/identity/`: profile identity and selected-generation startup.
- `lib/store/`, `lib/domain/`, `lib/data/`: SQLite admission/recovery,
  revisioned domain actions and immutable local outbox.
- `lib/data/`, `lib/session/`: repositories, drafts, finished workouts and timers.
- `lib/recovery/`, `lib/transfer/`: backup, restore, quarantine and import contracts.
- `lib/ui/`, `lib/shell/`, `lib/widgets/`, `lib/theme/`: application UI.
- `test/`, `tool/`: unit/widget/native-boundary tests and focused local proof tools.

Follow [app agent guidance](AGENTS.md), [current development](../docs/alkion/development.md)
and [integrated acceptance](../docs/alkion/acceptance.md). Driver, store, transfer
and backup Make routes require explicit disposable fixture paths. The bespoke
Android campaign tools are retired; use the [manual APK checklist](../docs/alkion/android-smoke.md)
for a small device smoke check. Host tests do not establish device behavior.

## Historical capture evidence

[Retirement disposition](../docs/alkion/legacy-retirement.md) records the old Reps
backend removal and retained non-runtime schema/protocol fixtures. Dated capture
qualification and installation records remain available, as do
`scripts/check-capture-installation.py`, `scripts/verify-capture-rehearsal.py` and
their installation tests. Older capture-production/release commands are not
current app setup instructions. No live import, key access or service operation
is authorized by this guide.
