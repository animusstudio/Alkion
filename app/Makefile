# Run from the repository root: make -C app <target>.
# Every Flutter/Dart execution resolves the preserved FVM 3.44.0 pin.
FLUTTER := fvm flutter
DART := fvm dart
# Tool subprocesses must not refresh the reviewed Git index opportunistically.
export GIT_OPTIONAL_LOCKS := 0

.PHONY: help get analyze test fmt format build build-apk alkion-driver-qualification alkion-transfer-recovery alkion-backup-recovery run run-android build-apk-release build-capture-apk-release capture-integration capture-recovery capture-go-compat install doctor devices scaffold-linux scaffold-android clean
help:
	@echo "Alkion: get, analyze, test TEST=<path>, format, fmt FORMAT_FILES=<owned paths>, alkion-driver-qualification ALKION_OUTPUT=<fresh /tmp path>, alkion-transfer-recovery ALKION_OUTPUT=<fresh transfer-proof* path>, alkion-backup-recovery ALKION_OUTPUT=<fresh backup-proof* path>"
get:
	$(FLUTTER) pub get --offline --enforce-lockfile
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
alkion-driver-diagnose:
	@test -n "$(ALKION_OUTPUT)" || (echo 'Set fresh ALKION_OUTPUT.' >&2; exit 2)
	$(DART) run tool/alkion_driver_qualification.dart --diagnose "$(ALKION_OUTPUT)"
alkion-toolchain:
	$(FLUTTER) --version --machine
	$(DART) --version
# Builds are later integration/emulator gates; these do not launch a device.
build:
	$(FLUTTER) build linux --no-pub
build-apk:
	$(FLUTTER) build apk --debug
# No normal startup, legacy capture, release/signing, SDK installation/device
# discovery, scaffold mutation or destructive clean is authorized at T1.
run run-android build-apk-release build-capture-apk-release capture-integration capture-recovery capture-go-compat install doctor devices scaffold-linux scaffold-android clean:
	@echo 'Unavailable in the current Alkion development phase.' >&2
	@exit 2

# Scoped localization generation through the same pinned FVM route.
gen-l10n:
	$(FLUTTER) gen-l10n

# Scoped dependency removal refresh; no upgrade or network resolution.
get-offline-update:
	$(FLUTTER) pub get --offline
