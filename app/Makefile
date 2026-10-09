# All targets are meant to be invoked from the repo root via `make -C app <target>`.
# Every target runs Flutter/Dart through fvm so the pinned SDK in .fvmrc is used.

FLUTTER := fvm flutter
DART := fvm dart

.PHONY: help install get scaffold-linux scaffold-android analyze test capture-integration fmt format build build-apk build-apk-release run run-android doctor devices clean

help:
	@echo "Targets (run from repo root as 'make -C app <target>'):"
	@echo "  install        Install the pinned Flutter SDK (reads .fvmrc)"
	@echo "  get            flutter pub get"
	@echo "  scaffold-linux Generate the linux/ desktop runner (additive)"
	@echo "  scaffold-android  Generate the Android platform folder"
	@echo "  analyze        Static analysis (flutter analyze)"
	@echo "  test           Run all Flutter tests"
	@echo "  capture-integration  Native capture qualification; needs CAPTURE_DEVICE=<id>"
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
