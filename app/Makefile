# Run from the repository root: make -C app <target>.
# Every Flutter/Dart execution resolves the preserved FVM 3.44.0 pin.
FLUTTER := fvm flutter
DART := fvm dart
ALKION_FLAVOR ?= dev
# Tool subprocesses must not refresh the reviewed Git index opportunistically.
export GIT_OPTIONAL_LOCKS := 0
export ALKION_FLAVOR ALKION_PROOF_RUN ALKION_PROOF_VERSION ALKION_LIFECYCLE_PHASE
export ALKION_PROOF_SOURCE ALKION_UI_CASE

.PHONY: help get analyze test fmt format build build-apk build-apk-dev build-apk-supported alkion-driver-qualification alkion-transfer-recovery alkion-backup-recovery run run-android build-apk-release build-capture-apk-release capture-integration capture-recovery capture-go-compat install doctor devices scaffold-linux scaffold-android clean
.PHONY: alkion-verify-backup
.PHONY: android-synthetic android-synthetic-self-test android-synthetic-neighbor android-synthetic-driver-apk android-synthetic-update-apk android-synthetic-lifecycle-apk android-synthetic-ui-apk
ALKION_SYNTHETIC_ACTION ?= check
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
alkion-verify-backup:
	@test -n "$(ALKION_BACKUP)" || (echo 'Set ALKION_BACKUP to the explicitly received backup file.' >&2; exit 2)
	@test -n "$(ALKION_OUTPUT)" || (echo 'Set ALKION_OUTPUT to a fresh inspection directory.' >&2; exit 2)
	$(DART) run tool/alkion_verify_backup.dart --backup "$(ALKION_BACKUP)" --output "$(ALKION_OUTPUT)"
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
	@case "$(ALKION_FLAVOR)" in dev|supported) ;; *) echo 'ALKION_FLAVOR must be dev or supported.' >&2; exit 2 ;; esac
	$(FLUTTER) build apk --debug --no-pub --flavor "$(ALKION_FLAVOR)"
build-apk-dev:
	$(MAKE) build-apk ALKION_FLAVOR=dev
build-apk-supported:
	$(MAKE) build-apk ALKION_FLAVOR=supported
android-synthetic:
	bash tool/android_synthetic.sh --action "$(ALKION_SYNTHETIC_ACTION)" --avd "$(ALKION_AVD)" --serial "$(ALKION_SERIAL)" --receipt "$(ALKION_RECEIPT)" --output "$(ALKION_OUTPUT)" --base-run "$(ALKION_BASE_RUN)"
android-synthetic-self-test:
	bash tool/android_synthetic.sh --action self-test
android-synthetic-neighbor:
	bash tool/android_synthetic.sh --action build-neighbor --output "$(ALKION_OUTPUT)"
android-synthetic-driver-apk:
	@case "$(ALKION_FLAVOR)" in dev|supported) ;; *) echo 'ALKION_FLAVOR must be dev or supported.' >&2; exit 2 ;; esac
	@printf '%s' "$(ALKION_PROOF_RUN)" | rg -q '^[a-f0-9]{32}$$' || (echo 'Explicit 32-hex ALKION_PROOF_RUN is required.' >&2; exit 2)
	$(FLUTTER) build apk --debug --no-pub --flavor "$(ALKION_FLAVOR)" --target-platform android-x64 --target integration_test/android_driver_test.dart --dart-define=ALKION_PROOF_RUN="$(ALKION_PROOF_RUN)"
android-synthetic-update-apk:
	@case "$(ALKION_FLAVOR)" in dev|supported) ;; *) exit 2 ;; esac
	@case "$(ALKION_UPDATE_PHASE)" in seed|verify) ;; *) exit 2 ;; esac
	@printf '%s' "$(ALKION_PROOF_RUN)" | rg -q '^[a-f0-9]{32}$$' || exit 2
	@printf '%s' "$(ALKION_PROOF_VERSION)" | rg -q '^[0-9]{1,10}$$' || exit 2
	$(FLUTTER) build apk --debug --no-pub --flavor "$(ALKION_FLAVOR)" --target-platform android-x64 --target integration_test/android_lifecycle_test.dart --build-number "$(ALKION_PROOF_VERSION)" --dart-define=ALKION_PROOF_RUN="$(ALKION_PROOF_RUN)" --dart-define=ALKION_UPDATE_PHASE="$(ALKION_UPDATE_PHASE)"
android-synthetic-lifecycle-apk:
	bash tool/android_synthetic.sh --action build-lifecycle
android-synthetic-ui-apk:
	@python3 -c 'import os,re,subprocess,sys; e=os.environ; f=e.get("ALKION_FLAVOR",""); r=e.get("ALKION_PROOF_RUN",""); s=e.get("ALKION_PROOF_SOURCE",""); v=e.get("ALKION_PROOF_VERSION",""); c=e.get("ALKION_UI_CASE",""); valid=f in ("dev","supported") and re.fullmatch("[a-f0-9]{32}",r) and re.fullmatch("[a-f0-9]{40}",s) and re.fullmatch("[0-9]{1,10}",v) and 1<=int(v)<=2099999999 and c in ("en-dark","de-light-reduced","es-light","it-dark"); valid or sys.exit("Explicit synthetic UI flavor/run/source/version/case required"); raise SystemExit(subprocess.call(["fvm","flutter","build","apk","--debug","--no-pub","--flavor",f,"--target-platform","android-x64","--target","integration_test/android_ui_visual_test.dart","--build-number",v,"--dart-define=ALKION_PROOF_RUN="+r,"--dart-define=ALKION_PROOF_SOURCE="+s,"--dart-define=ALKION_UI_CASE="+c,"--dart-define=ALKION_PROOF_VERSION="+v]))'
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
