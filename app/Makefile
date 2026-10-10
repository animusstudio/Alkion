# All targets are meant to be invoked from the repo root via `make -C app <target>`.
# Every target runs Flutter/Dart through fvm so the pinned SDK in .fvmrc is used.

FLUTTER := fvm flutter
DART := fvm dart

.PHONY: help install get scaffold-linux scaffold-android analyze test capture-integration capture-recovery capture-go-compat fmt format build build-apk build-apk-release run run-android doctor devices clean

help:
	@echo "Targets (run from repo root as 'make -C app <target>'):"
	@echo "  install        Install the pinned Flutter SDK (reads .fvmrc)"
	@echo "  get            flutter pub get"
	@echo "  scaffold-linux Generate the linux/ desktop runner (additive)"
	@echo "  scaffold-android  Generate the Android platform folder"
	@echo "  analyze        Static analysis (flutter analyze)"
	@echo "  test           Run all Flutter tests"
	@echo "  capture-integration  Native capture qualification; needs CAPTURE_DEVICE=<id>"
	@echo "  capture-recovery     Interruption/fault/Go fixtures; needs CAPTURE_DEVICE=<id> CAPTURE_OUTPUT=<fresh temp dir>"
	@echo "  capture-go-compat    Hub rehearsal over a produced capture; needs HUB_SRC=<Hub checkout>"
	@echo "  fmt            Format Dart sources in place (dart format)"
	@echo "  format         Verify formatting, fail if changes needed (CI)"
	@echo "  build          Build the Linux desktop bundle (compiles native libs)"
	@echo "  build-apk         Build a debug APK"
	@echo "  build-apk-release Build a signed release APK (needs android/key.properties)"
	@echo "  run            Run on the Linux desktop target"
	@echo "  run-android       Run on a connected Android device"
	@echo "  doctor         flutter doctor -v"
	@echo "  devices        List devices (expect a linux device)"
	@echo "  clean          flutter clean"

install:
	fvm install

get:
	$(FLUTTER) pub get

scaffold-linux:
	$(FLUTTER) create --platforms=linux --org io.github.psychonaut0 --project-name workout_tracker .

scaffold-android:
	$(FLUTTER) create --platforms=android --org dev.psy --project-name workout_tracker .

analyze:
	$(FLUTTER) analyze

# Optional: TEST=test/path/foo_test.dart to run a single file.
test:
	$(FLUTTER) test $(TEST)

# Native capture qualification runs on one explicitly chosen device; no device
# is ever selected implicitly. Example: CAPTURE_DEVICE=linux
capture-integration:
	@if [ -z "$(CAPTURE_DEVICE)" ]; then \
		echo "capture-integration: set CAPTURE_DEVICE=<device id> explicitly (see 'make -C app devices')" >&2; \
		exit 2; \
	fi
	$(FLUTTER) test integration_test/capture_platform_test.dart -d $(CAPTURE_DEVICE)

# Cross-store interruption, fault and Go-compatibility fixtures on one
# explicitly chosen device, written into CAPTURE_OUTPUT: a synthetic
# directory that must not exist yet or be empty, lie strictly below /tmp or
# $TMPDIR and outside this repository. On Linux a disposable child bundle
# (integration_test/capture_recovery_child.dart) is built first and copied to
# a temporary directory; the test starts and SIGKILLs only that child, on its
# own synthetic installations. Example:
#   make -C app capture-recovery CAPTURE_DEVICE=linux CAPTURE_OUTPUT=/tmp/reps-capture-synthetic
# The Go rehearsal then runs separately: scripts/verify-capture-rehearsal.py.
capture-recovery:
	@if [ -z "$(CAPTURE_DEVICE)" ]; then \
		echo "capture-recovery: set CAPTURE_DEVICE=<device id> explicitly (see 'make -C app devices')" >&2; \
		exit 2; \
	fi
	@if [ -z "$(CAPTURE_OUTPUT)" ]; then \
		echo "capture-recovery: set CAPTURE_OUTPUT=<fresh directory under /tmp or \$$TMPDIR>" >&2; \
		exit 2; \
	fi
	@set -e; \
	out=$$(realpath -m -- "$(CAPTURE_OUTPUT)"); \
	repo=$$(realpath -- ..); \
	ok=0; \
	for base in /tmp "$${TMPDIR:-/tmp}"; do \
		b=$$(realpath -m -- "$$base"); \
		case "$$out" in "$$b"/?*) ok=1 ;; esac; \
	done; \
	if [ "$$ok" != 1 ]; then echo "capture-recovery: CAPTURE_OUTPUT must lie below /tmp or \$$TMPDIR: $$out" >&2; exit 2; fi; \
	case "$$out/" in "$$repo"/*) echo "capture-recovery: CAPTURE_OUTPUT must be outside the repository" >&2; exit 2 ;; esac; \
	if [ -L "$(CAPTURE_OUTPUT)" ]; then echo "capture-recovery: CAPTURE_OUTPUT must not be a symbolic link" >&2; exit 2; fi; \
	if [ -e "$$out" ]; then \
		if [ ! -d "$$out" ] || [ -n "$$(ls -A -- "$$out")" ]; then \
			echo "capture-recovery: CAPTURE_OUTPUT must not exist yet or be an empty directory: $$out" >&2; exit 2; \
		fi; \
	else \
		mkdir -m 700 -- "$$out"; \
	fi; \
	child=$$(mktemp -d "$${TMPDIR:-/tmp}/reps-capture-child.XXXXXX"); \
	trap 'rm -rf "$$child"' EXIT; \
	defines="--dart-define=CAPTURE_OUTPUT=$$out"; \
	if [ "$(CAPTURE_DEVICE)" = linux ]; then \
		$(FLUTTER) build linux --debug -t integration_test/capture_recovery_child.dart; \
		cp -a build/linux/x64/debug/bundle "$$child/bundle"; \
		defines="$$defines --dart-define=CAPTURE_CHILD=$$child/bundle/workout_tracker"; \
	fi; \
	$(FLUTTER) test integration_test/capture_recovery_test.dart -d $(CAPTURE_DEVICE) $$defines

# Builds the Hub's reps-migration-rehearsal from an explicitly named Hub
# source tree (read only; e.g. a `git archive` of the pinned commit) into a
# temporary directory and runs it over a capture produced from a synthetic
# PowerSync database, then over a capture the coordinator published. Needs
# Go; the Hub tree is never modified.
capture-go-compat:
	@if [ -z "$(HUB_SRC)" ]; then \
		echo "capture-go-compat: set HUB_SRC=<Hub source tree> explicitly" >&2; \
		exit 2; \
	fi
	@bin_dir=$$(mktemp -d) && trap 'rm -rf "$$bin_dir"' EXIT && \
		go -C "$(HUB_SRC)" build -o "$$bin_dir/reps-migration-rehearsal" ./connectors/reps/cmd/reps-migration-rehearsal && \
		REPS_REHEARSAL_BIN="$$bin_dir/reps-migration-rehearsal" $(FLUTTER) test test/capture/capture_artifact_test.dart --plain-name rehearsal_accepts_produced_capture && \
		REPS_REHEARSAL_BIN="$$bin_dir/reps-migration-rehearsal" $(FLUTTER) test test/capture/capture_coordinator_test.dart --plain-name rehearsal_accepts_certified_capture

fmt:
	$(DART) format .

format:
	$(DART) format --output=none --set-exit-if-changed .

build:
	$(FLUTTER) build linux

build-apk:
	$(FLUTTER) build apk --debug

build-apk-release:
	$(FLUTTER) build apk --release

run:
	$(FLUTTER) run -d linux

run-android:
	$(FLUTTER) run -d android

doctor:
	$(FLUTTER) doctor -v

devices:
	$(FLUTTER) devices

clean:
	$(FLUTTER) clean
