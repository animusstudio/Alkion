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
.PHONY: android-synthetic-documents-apk android-synthetic-documents-provider android-synthetic-documents-self-test
.PHONY: android-synthetic-capability-apk android-synthetic-capabilities-self-test
.PHONY: android-synthetic-restore-apks android-synthetic-restore-check android-synthetic-restore-run android-synthetic-restore-self-test
.PHONY: android-synthetic-publisher android-synthetic-publisher-self-test
ALKION_SYNTHETIC_ACTION ?= check
# Preserve raw operator inputs in the environment, including literal dollars.
override export ALKION_SYNTHETIC_ACTION := $(value ALKION_SYNTHETIC_ACTION)
override export ALKION_AVD := $(value ALKION_AVD)
override export ALKION_SERIAL := $(value ALKION_SERIAL)
override export ALKION_RECEIPT := $(value ALKION_RECEIPT)
override export ALKION_OUTPUT := $(value ALKION_OUTPUT)
override export ALKION_BASE_RUN := $(value ALKION_BASE_RUN)
override export ALKION_DRIVER_RUN := $(value ALKION_DRIVER_RUN)
override export ALKION_UPDATES_RUN := $(value ALKION_UPDATES_RUN)
override export ALKION_VERSION_LEDGER := $(value ALKION_VERSION_LEDGER)
override export ALKION_SOURCE_REVIEW := $(value ALKION_SOURCE_REVIEW)
override export ALKION_ATTEMPT_MANIFESTS_JSON := $(value ALKION_ATTEMPT_MANIFESTS_JSON)
override export ALKION_JIT_BUILD_BUDGET := $(value ALKION_JIT_BUILD_BUDGET)
override export ALKION_BACKUP := $(value ALKION_BACKUP)
override export ALKION_FLAVOR := $(value ALKION_FLAVOR)
override export ALKION_PROOF_RUN := $(value ALKION_PROOF_RUN)
override export ALKION_PROOF_SOURCE := $(value ALKION_PROOF_SOURCE)
override export ALKION_PRIOR_SOURCE := $(value ALKION_PRIOR_SOURCE)
override export ALKION_PROOF_VARIANT := $(value ALKION_PROOF_VARIANT)
override export ALKION_CAPABILITY_CASE := $(value ALKION_CAPABILITY_CASE)
override export ALKION_CAPABILITY_PHASE := $(value ALKION_CAPABILITY_PHASE)
override export ALKION_PROOF_VERSION := $(value ALKION_PROOF_VERSION)
override export ALKION_PRIOR_VERSION := $(value ALKION_PRIOR_VERSION)
override export ALKION_CONSUMED_VERSION_FLOOR := $(value ALKION_CONSUMED_VERSION_FLOOR)
override export ALKION_PROOF_PROFILE := $(value ALKION_PROOF_PROFILE)
override export ALKION_PROOF_GENERATION := $(value ALKION_PROOF_GENERATION)
override export ALKION_PRIOR_REPORT_SHA256 := $(value ALKION_PRIOR_REPORT_SHA256)
override export ALKION_PRIOR_STATE_SHA256 := $(value ALKION_PRIOR_STATE_SHA256)
override export ALKION_RESTORE_SOURCE_MANIFEST := $(value ALKION_RESTORE_SOURCE_MANIFEST)
override export ALKION_RESTORE_RECEIVER_DRIVER := $(value ALKION_RESTORE_RECEIVER_DRIVER)
override export ALKION_RESTORE_CANDIDATE_MANIFEST := $(value ALKION_RESTORE_CANDIDATE_MANIFEST)
override export ALKION_RESTORE_DEV_APK := $(value ALKION_RESTORE_DEV_APK)
override export ALKION_RESTORE_SUPPORTED_APK := $(value ALKION_RESTORE_SUPPORTED_APK)
override export ALKION_RESTORE_PROVIDER_APK := $(value ALKION_RESTORE_PROVIDER_APK)
override export ALKION_UI_OBSERVER_BUILD := $(value ALKION_UI_OBSERVER_BUILD)
override export ALKION_PUBLISHER_BUILD := $(value ALKION_PUBLISHER_BUILD)
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
	@test -n "$${ALKION_BACKUP}" || (echo 'Set ALKION_BACKUP to the explicitly received backup file.' >&2; exit 2)
	@test -n "$${ALKION_OUTPUT}" || (echo 'Set ALKION_OUTPUT to a fresh inspection directory.' >&2; exit 2)
	$(DART) run tool/alkion_verify_backup.dart --backup "$${ALKION_BACKUP}" --output "$${ALKION_OUTPUT}"
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
	@set --; \
	case "$${ALKION_SYNTHETIC_ACTION}" in \
	documents-check|documents) set -- --publisher-build "$${ALKION_PUBLISHER_BUILD}" ;; \
	capabilities-check|capabilities) set -- --version-ledger "$${ALKION_VERSION_LEDGER}" --source-review "$${ALKION_SOURCE_REVIEW}" --attempt-manifests-json "$${ALKION_ATTEMPT_MANIFESTS_JSON:-[]}" --jit-build-budget "$${ALKION_JIT_BUILD_BUDGET:-120}" --publisher-build "$${ALKION_PUBLISHER_BUILD}" ;; \
	build-restore|restore-check|restore) set -- --source-manifest "$${ALKION_RESTORE_SOURCE_MANIFEST}" --receiver-driver "$${ALKION_RESTORE_RECEIVER_DRIVER}" --version-ledger "$${ALKION_VERSION_LEDGER}" --source-review "$${ALKION_SOURCE_REVIEW}" --attempt-manifests-json "$${ALKION_ATTEMPT_MANIFESTS_JSON:-[]}" --candidate-manifest "$${ALKION_RESTORE_CANDIDATE_MANIFEST}" --dev-apk "$${ALKION_RESTORE_DEV_APK}" --supported-apk "$${ALKION_RESTORE_SUPPORTED_APK}" --provider-apk "$${ALKION_RESTORE_PROVIDER_APK}" --ui-observer-build "$${ALKION_UI_OBSERVER_BUILD}" ;; \
	esac; \
	bash tool/android_synthetic.sh --action "$${ALKION_SYNTHETIC_ACTION}" --avd "$${ALKION_AVD}" --serial "$${ALKION_SERIAL}" --receipt "$${ALKION_RECEIPT}" --output "$${ALKION_OUTPUT}" --base-run "$${ALKION_BASE_RUN}" --driver-run "$${ALKION_DRIVER_RUN}" --updates-run "$${ALKION_UPDATES_RUN}" "$$@"
android-synthetic-self-test:
	bash tool/android_synthetic.sh --action self-test
	$(MAKE) android-synthetic-documents-self-test
	$(MAKE) android-synthetic-ui-observer-self-test
	$(MAKE) android-synthetic-capabilities-self-test
	$(MAKE) android-synthetic-restore-self-test
	$(MAKE) android-synthetic-publisher-self-test
android-synthetic-restore-apks:
	$(MAKE) android-synthetic ALKION_SYNTHETIC_ACTION=build-restore
android-synthetic-restore-check:
	$(MAKE) android-synthetic ALKION_SYNTHETIC_ACTION=restore-check
android-synthetic-restore-run:
	$(MAKE) android-synthetic ALKION_SYNTHETIC_ACTION=restore
android-synthetic-restore-self-test:
	PYTHONDONTWRITEBYTECODE=1 python3 tool/android_synthetic_restore_self_test.py
android-synthetic-capabilities-self-test:
	PYTHONDONTWRITEBYTECODE=1 python3 tool/android_synthetic_capabilities_self_test.py
android-synthetic-capability-apk:
	bash tool/android_synthetic.sh --action build-capability
android-synthetic-documents-self-test:
	PYTHONDONTWRITEBYTECODE=1 python3 tool/android_synthetic_documents_self_test.py
# Host-only literal build of the test publisher; never invoked by a campaign route.
android-synthetic-publisher:
	bash tool/android_synthetic.sh --action build-publisher --output "$${ALKION_OUTPUT}"
android-synthetic-publisher-self-test:
	PYTHONDONTWRITEBYTECODE=1 python3 tool/android_synthetic_publish_self_test.py
android-synthetic-neighbor:
	bash tool/android_synthetic.sh --action build-neighbor --output "$(ALKION_OUTPUT)"
.PHONY: android-synthetic-ui-observer android-synthetic-ui-observer-self-test
android-synthetic-ui-observer:
	bash tool/android_synthetic.sh --action build-ui-observer --output "$${ALKION_OUTPUT}"
android-synthetic-ui-observer-self-test:
	PYTHONDONTWRITEBYTECODE=1 python3 tool/android_synthetic_ui_self_test.py
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
android-synthetic-documents-apk:
	bash tool/android_synthetic.sh --action build-documents
android-synthetic-documents-provider:
	bash tool/android_synthetic.sh --action build-documents-provider --output "$${ALKION_OUTPUT}"
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
