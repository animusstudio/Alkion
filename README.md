# Alkion

<p align="center">
  <img src="docs/assets/brand/alkion-banner.png" width="800" alt="Alkion by Animus, with a classical bust formed from characters">
</p>

> **Current state:** `main` is pre-1.0 development of Alkion, the successor app (see
> [`docs/alkion/development.md`](docs/alkion/development.md)). **v0.18.1 is the final legacy
> Reps release.** No tags, releases or use of the release skill happen before Alkion 1.0.
> The legacy reference below describes Reps, not the current successor’s feature set.

## Legacy Reps reference

A local-first gym logging app. Track your sets, watch your top-set weight climb, own your data.

Built for one lifter's actual training (and used at the gym every week), open-sourced because it might fit yours too. **No account, no cloud, no telemetry** — everything lives on your phone, and if you want multi-device sync you point it at your own server.

### Features

- **Workout logging built for the gym floor** — start a session from your split rotation in one tap, steppers sized for sweaty thumbs (or tap to type), per-exercise rest timer with haptics, warm-up ramps suggested from your last top set.
- **Works fully offline** — local database, local identity, optional everything. Minimize the workout and browse the app, keep an eye on the ongoing notification (elapsed / rest countdown), survive a force-kill mid-session and resume where you left off.
- **Progression that matters** — per-exercise top-set trend, estimated 1RM, volume and reps; PR detection with a little celebration; bodyweight tracking with trend.
- **Your split, your catalog** — plan training days with per-exercise prescriptions (sets × reps @ RIR), weekly muscle-volume targets, a fully editable exercise catalog (equipment, plate increments, defaults). Nothing is read-only.
- **History you can fix** — edit, add, or delete past sets and sessions.
- **Data export** — versioned full-backup JSON, plus an LLM-friendly history export for a date range (hand your training log to your favorite model).
- **Optional self-hosted sync** — register against your own backend ([PowerSync](https://www.powersync.com/) + Go + Postgres) and sync across devices. The app works identically without it.
- Dark/light theme, four accent colors, kg/lb, a subtle ambient layer that comes alive while you train (with an off switch), reduced-motion support.

### Install

**Android:** grab the latest `reps-vX.Y.Z.apk` from [Releases](https://github.com/animusstudio/Alkion/releases) and install it. That's the whole setup — open the app, optionally seed the starter exercise catalog, train.

**Build from source** (requires [fvm](https://fvm.app/)):

```sh
make -C app install      # installs the pinned Flutter SDK
make -C app build-apk    # debug APK
make -C app build        # or: Linux desktop build
```

### Self-hosting sync (optional)

The sync backend is a small Go API + Postgres + the PowerSync service, all in one compose stack:

```sh
make -C server gen-jwt-key
docker compose -f infra/compose.yml -f infra/compose.dev.yml --env-file infra/.env up -d
```

See `infra/README.md` for the full runbook. A prebuilt server image is published to GHCR (`ghcr.io/psychonaut0/workout-tracker-server`). In the app: Profile → Sync & Backend → set your server URL → register. Local data is kept and attached on first sign-in.

### Architecture

```
app/        Flutter client (Android + Linux desktop) — PowerSync SQLite, offline-first
server/     Go API — auth (JWT/JWKS), /sync/upload write path, embedded migrations
powersync/  PowerSync service config + sync rules (per-user + template buckets)
infra/      Dev compose stack (Postgres, server, PowerSync)
api/        OpenAPI 3.1 spec
docs/       Design specs & implementation plans for every increment, plus the original design handoff
```

The client is the source of truth for your day-to-day: it writes to a local SQLite database and works with zero connectivity. When sync is enabled, PowerSync streams changes both ways; the server stamps ownership and computes top-set/PR flags. The full design history — every feature's spec and implementation plan — lives in `docs/superpowers/`.

### Development

```sh
make -C app analyze                          # static analysis
make -C app test                             # full test suite
make -C app test TEST=test/path/foo_test.dart
make -C server test                          # needs the dev stack running
```

Releases are automated: tagging `v*` builds and publishes a signed APK; pushes to `main` publish the server image.

## License

[MIT](LICENSE)
