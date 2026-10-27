# Run from the repository root: make -C app <target>.
# Every Flutter/Dart execution resolves the preserved FVM 3.44.0 pin.
FLUTTER := fvm flutter
DART := fvm dart
ALKION_FLAVOR ?= dev
# Tool subprocesses must not refresh the reviewed Git index opportunistically.
export GIT_OPTIONAL_LOCKS := 0
override export ALKION_BACKUP := $(value ALKION_BACKUP)
override export ALKION_OUTPUT := $(value ALKION_OUTPUT)

.PHONY: help get get-online analyze test fmt format build build-apk build-apk-dev build-apk-supported alkion-driver-qualification alkion-store-recovery alkion-transfer-recovery alkion-backup-recovery run run-android build-apk-release build-capture-apk-release capture-integration capture-recovery capture-go-compat install doctor devices scaffold-linux scaffold-android clean
.PHONY: alkion-verify-backup build-apk-local-test-release
help:
	@echo "Alkion: get, analyze, test TEST=<path>, format, fmt FORMAT_FILES=<owned paths>, alkion-driver-qualification ALKION_OUTPUT=<fresh /tmp path>, alkion-transfer-recovery ALKION_OUTPUT=<fresh transfer-proof* path>, alkion-backup-recovery ALKION_OUTPUT=<fresh backup-proof* path>"
get:
	$(FLUTTER) pub get --offline --enforce-lockfile
# Explicit connected bootstrap for a fresh dependency cache; never upgrades.
get-online:
	$(FLUTTER) pub get --enforce-lockfile
analyze:
	$(FLUTTER) analyze --no-pub
test:
	$(FLUTTER) test --no-pub $(TEST)
format:
	$(DART) format --output=none --set-exit-if-changed .
fmt:
	@test -n "$(FORMAT_FILES)" || (echo 'Specify owned FORMAT_FILES; broad formatting is not authorized.' >&2; exit 2)
	$(DART) format $(FORMAT_FILES)
alkion-driver-qualification:
	@test -n "$(ALKION_OUTPUT)" || (echo 'Set ALKION_OUTPUT to a fresh owned /tmp directory.' >&2; exit 2)
	$(DART) run tool/alkion_driver_qualification.dart --output "$(ALKION_OUTPUT)"
alkion-store-recovery:
	@test -n "$(ALKION_OUTPUT)" || (echo 'Set ALKION_OUTPUT to a fresh owned /tmp directory.' >&2; exit 2)
	$(DART) run tool/alkion_store_recovery.dart --output "$(ALKION_OUTPUT)" $(ALKION_CASE_ARGS)
alkion-transfer-recovery:
	@test -n "$(ALKION_OUTPUT)" || (echo 'Set ALKION_OUTPUT to a fresh disposable transfer-proof* directory.' >&2; exit 2)
	$(DART) run tool/alkion_transfer_recovery.dart --output "$(ALKION_OUTPUT)"
alkion-backup-recovery:
	@test -n "$(ALKION_OUTPUT)" || (echo 'Set ALKION_OUTPUT to a fresh disposable backup-proof* directory.' >&2; exit 2)
	$(DART) run tool/alkion_backup_recovery.dart --output "$(ALKION_OUTPUT)"
alkion-verify-backup:
	@test -n "$${ALKION_BACKUP}" || (echo 'Set ALKION_BACKUP to the explicitly received backup file.' >&2; exit 2)
	@test -n "$${ALKION_OUTPUT}" || (echo 'Set ALKION_OUTPUT to a fresh inspection directory.' >&2; exit 2)
	$(DART) run tool/alkion_verify_backup.dart --backup "$${ALKION_BACKUP}" --output "$${ALKION_OUTPUT}"
alkion-driver-diagnose:
	@test -n "$(ALKION_OUTPUT)" || (echo 'Set fresh ALKION_OUTPUT.' >&2; exit 2)
	$(DART) run tool/alkion_driver_qualification.dart --diagnose "$(ALKION_OUTPUT)"
alkion-toolchain:
	$(FLUTTER) --version --machine
	$(DART) --version
# Local builds do not install or launch a device.
build:
	$(FLUTTER) build linux --no-pub
build-apk:
	@case "$(ALKION_FLAVOR)" in dev|supported) ;; *) echo 'ALKION_FLAVOR must be dev or supported.' >&2; exit 2 ;; esac
	$(FLUTTER) build apk --debug --no-pub --flavor "$(ALKION_FLAVOR)"
build-apk-dev:
	$(MAKE) build-apk ALKION_FLAVOR=dev
build-apk-supported:
	$(MAKE) build-apk ALKION_FLAVOR=supported
build-apk-local-test-release:
	@test "$${ALKION_LOCAL_RELEASE_TEST}" = 1 || (echo 'Set ALKION_LOCAL_RELEASE_TEST=1 for a private release-mode test APK.' >&2; exit 2)
	@test -n "$${ANDROID_USER_HOME}" || (echo 'Set ANDROID_USER_HOME to the existing disposable debug-key directory.' >&2; exit 2)
	$(FLUTTER) build apk --release --no-pub --flavor dev --target-platform android-arm64
# Implicit app/device/scaffold actions and retired capture/release routes
# remain unavailable; use explicit build and qualification routes above.
run run-android build-apk-release build-capture-apk-release capture-integration capture-recovery capture-go-compat install doctor devices scaffold-linux scaffold-android clean:
	@echo 'Unavailable in the current Alkion development phase.' >&2
	@exit 2

# Scoped localization generation through the same pinned FVM route.
gen-l10n:
	$(FLUTTER) gen-l10n

# Scoped dependency removal refresh; no upgrade or network resolution.
get-offline-update:
	$(FLUTTER) pub get --offline

# Isolated synthetic artwork checkpoint; does not open an Alkion store.
.PHONY: build-character-body-preview stage-character-body verify-character-body
build-character-body-preview:
	ALKION_BODY_PREVIEW_OFFLINE=1 $(FLUTTER) build apk --debug --no-pub --flavor dev --target lib/character_body_preview.dart
stage-character-body:
	@test -n "$(BODY_MALE_ASSETS)" -a -n "$(BODY_FEMALE_ASSETS)" || (echo 'Supply explicit private BODY_MALE_ASSETS and BODY_FEMALE_ASSETS.' >&2; exit 2)
	python3 tool/stage_character_body.py --male-assets "$(BODY_MALE_ASSETS)" --female-assets "$(BODY_FEMALE_ASSETS)"
verify-character-body:
	python3 tool/stage_character_body.py --verify

# Separate offline, synthetic ARM64 artifact. Build only; never install a device.
.PHONY: build-character-body-preview-isolated
build-character-body-preview-isolated:
	@test -n "$${ANDROID_USER_HOME}" && test -f "$${ANDROID_USER_HOME}/debug.keystore" || (echo 'Set ANDROID_USER_HOME to the existing disposable debug signer directory.' >&2; exit 2)
	@if test "$${ALKION_PRIVATE_BODY_ASSETS}" = 1; then $(MAKE) verify-character-body; fi
	ALKION_ISOLATED_BODY_PREVIEW=1 ALKION_BODY_PREVIEW_OFFLINE=1 $(FLUTTER) build apk --debug --no-pub --flavor dev --target-platform android-arm64 --target lib/character_body_preview.dart
	cp -- build/app/outputs/flutter-apk/app-dev-debug.apk build/app/outputs/flutter-apk/alkion-body-preview-isolated-debug.apk

# Rebuild approved brand PNGs, then the existing Android resource set.
.PHONY: brand-icons
brand-icons:
	node tool/generate_brand_assets.mjs
	$(DART) run flutter_launcher_icons -f flutter_launcher_icons.yaml
