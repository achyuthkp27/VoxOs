# Recipes run under bash with pipefail so a failing command in a pipeline fails the
# target. Without it `xcodebuild test | grep ... | sort` reported the exit status of
# `sort`, and `make test` could never fail.
SHELL := /bin/bash
.SHELLFLAGS := -o pipefail -c

# Define a directory for dependencies in the user's home folder
DEPS_DIR := $(HOME)/VoxOS-Dependencies
WHISPER_CPP_DIR := $(DEPS_DIR)/whisper.cpp
# Pinned so every machine and CI build the same whisper.xcframework. Previously this
# tracked master, so a fresh clone got whatever upstream happened to be that day.
# This is the commit local builds were already on; bump it deliberately.
WHISPER_CPP_REF ?= c4ac0012a8f5a2082dfca6aad4ddfd8b2c02b337
FRAMEWORK_PATH := $(WHISPER_CPP_DIR)/build-apple/whisper.xcframework
LOCAL_DERIVED_DATA := $(CURDIR)/.local-build
TEST_DERIVED_DATA := $(CURDIR)/.local-build-tests
# The test host is the app itself. Sharing the app's bundle identifier let macOS resolve
# the login item to whichever copy ran last, so a test run re-pointed it at this throwaway
# build and the next login tried to start a bundle that cannot load whisper.framework.
TEST_BUNDLE_ID_SUFFIX := .testhost
TEST_RESULT_BUNDLE := $(TEST_DERIVED_DATA)/TestResults/latest.xcresult
LOCAL_CODESIGN_IDENTITY ?=
# `make local` installs straight to /Applications so no stray copies are left
# lying around in ~/Downloads for Spotlight to index.
INSTALL_PATH ?= /Applications/VoxOS.app

.PHONY: all clean whisper setup build local check healthcheck help dev run release release-setup test lint format print-whisper-ref

# Default target
all: check build

# Development workflow
dev: local run

# Prerequisites
check:
	@echo "Checking prerequisites..."
	@command -v git >/dev/null 2>&1 || { echo "git is not installed"; exit 1; }
	@command -v xcodebuild >/dev/null 2>&1 || { echo "xcodebuild is not installed (need Xcode)"; exit 1; }
	@command -v swift >/dev/null 2>&1 || { echo "swift is not installed"; exit 1; }
	@echo "Prerequisites OK"

healthcheck: check

# Used by CI to key the whisper.xcframework cache on the pinned ref.
print-whisper-ref:
	@echo $(WHISPER_CPP_REF)

# Build process
whisper:
	@mkdir -p $(DEPS_DIR)
	@if [ ! -d "$(FRAMEWORK_PATH)" ]; then \
		echo "Building whisper.xcframework in $(DEPS_DIR)..."; \
		if [ ! -d "$(WHISPER_CPP_DIR)" ]; then \
			git clone https://github.com/ggerganov/whisper.cpp.git $(WHISPER_CPP_DIR); \
		fi; \
		(cd $(WHISPER_CPP_DIR) && git fetch --tags origin && git checkout --quiet $(WHISPER_CPP_REF)); \
		cd $(WHISPER_CPP_DIR) && ./build-xcframework.sh; \
	else \
		echo "whisper.xcframework already built in $(DEPS_DIR), skipping build"; \
	fi

setup: whisper
	@echo "Whisper framework is ready at $(FRAMEWORK_PATH)"
	@echo "Please ensure your Xcode project references the framework from this new location."

build: setup
	xcodebuild -project VoxOS.xcodeproj -scheme VoxOS -configuration Debug CODE_SIGN_IDENTITY="" build

# Build locally with stable Apple Development signing when available.
local: check setup
	@echo "Building VoxOS for local use (no Apple Developer certificate required)..."
	@rm -rf "$(LOCAL_DERIVED_DATA)"
	@mkdir -p "$(LOCAL_DERIVED_DATA)" && touch "$(LOCAL_DERIVED_DATA)/.metadata_never_index"
	@SIGNING_IDENTITY="$(LOCAL_CODESIGN_IDENTITY)"; \
	if [ -z "$$SIGNING_IDENTITY" ]; then \
		SIGNING_IDENTITIES=$$(security find-identity -v -p codesigning 2>/dev/null | awk '/"Apple Development: / { print $$2 }'); \
		SIGNING_IDENTITY_COUNT=$$(printf '%s\n' "$$SIGNING_IDENTITIES" | awk 'NF { count++ } END { print count + 0 }'); \
		if [ "$$SIGNING_IDENTITY_COUNT" -eq 1 ]; then \
			SIGNING_IDENTITY=$$(printf '%s\n' "$$SIGNING_IDENTITIES" | awk 'NF { print; exit }'); \
		elif [ "$$SIGNING_IDENTITY_COUNT" -gt 1 ]; then \
			echo "Multiple Apple Development identities found; set LOCAL_CODESIGN_IDENTITY to choose one; using ad-hoc signing"; \
		fi; \
	fi; \
	if [ -n "$$SIGNING_IDENTITY" ] && [ "$$SIGNING_IDENTITY" != "-" ]; then \
		SIGNING_REQUIRED=YES; \
		echo "Using stable local signing identity: $$SIGNING_IDENTITY"; \
	else \
		SIGNING_IDENTITY="-"; \
		SIGNING_REQUIRED=NO; \
		echo "Using ad-hoc signing (permissions may need approval after rebuilds)"; \
	fi; \
	xcodebuild -project VoxOS.xcodeproj -scheme VoxOS -configuration Debug \
		-derivedDataPath "$(LOCAL_DERIVED_DATA)" \
		-xcconfig LocalBuild.xcconfig \
		-skipPackagePluginValidation \
		-skipMacroValidation \
		LOCAL_CODE_SIGN_IDENTITY="$$SIGNING_IDENTITY" \
		CODE_SIGNING_REQUIRED="$$SIGNING_REQUIRED" \
		CODE_SIGNING_ALLOWED=YES \
		DEVELOPMENT_TEAM="" \
		CODE_SIGN_ENTITLEMENTS="$(CURDIR)/VoxOS/VoxOS.local.entitlements" \
		SWIFT_ACTIVE_COMPILATION_CONDITIONS='$$(inherited) LOCAL_BUILD' \
		build
	@APP_PATH="$(LOCAL_DERIVED_DATA)/Build/Products/Debug/VoxOS.app" && \
	if [ -d "$$APP_PATH" ]; then \
		if pgrep -x VoxOS >/dev/null; then \
			echo "Quitting running VoxOS..."; \
			osascript -e 'quit app "VoxOS"' >/dev/null 2>&1 || true; \
			sleep 2; \
		fi; \
		echo "Installing to $(INSTALL_PATH)..."; \
		rm -rf "$(INSTALL_PATH)"; \
		ditto "$$APP_PATH" "$(INSTALL_PATH)"; \
		xattr -cr "$(INSTALL_PATH)"; \
		echo ""; \
		echo "Build complete! Installed to: $(INSTALL_PATH)"; \
		echo "Run with: make run"; \
		echo ""; \
		echo "Limitations of local builds:"; \
		echo "  - No iCloud dictionary sync"; \
		echo "  - No automatic updates (pull new code and rebuild to update)"; \
	else \
		echo "Error: Could not find built VoxOS.app at $$APP_PATH"; \
		exit 1; \
	fi

# Run application
run:
	@if [ -d "$(INSTALL_PATH)" ]; then \
		echo "Opening $(INSTALL_PATH)..."; \
		open "$(INSTALL_PATH)"; \
	else \
		echo "VoxOS is not installed. Run 'make local' first."; \
		exit 1; \
	fi

# Build a signed, notarized DMG and matching local Sparkle Appcast.
release: whisper
	@if [ -n "$(NOTES)" ]; then \
		./scripts/release.sh --notes "$(NOTES)" $(RELEASE_ARGS); \
	else \
		./scripts/release.sh $(RELEASE_ARGS); \
	fi

# Store Apple's notarization credentials securely in Keychain.
release-setup:
	@./scripts/setup-release-notarization.sh

# Cleanup
clean:
	@echo "Cleaning build artifacts..."
	@rm -rf $(DEPS_DIR)
	@echo "Clean complete"
	@rm -rf "$(TEST_DERIVED_DATA)"

# Help
help:
	@echo "Available targets:"
	@echo "  check/healthcheck  Check if required CLI tools are installed"
	@echo "  whisper            Clone and build whisper.cpp XCFramework"
	@echo "  setup              Copy whisper XCFramework to VoxOS project"
	@echo "  build              Build the VoxOS Xcode project"
	@echo "  local              Build, sign with your Apple Development identity, install to /Applications"
	@echo "    LOCAL_CODESIGN_IDENTITY=<SHA or name> overrides automatic Apple Development detection"
	@echo "  run                Launch the installed VoxOS app"
	@echo "  test               Run the unit tests"
	@echo "  lint               Check formatting with swift-format"
	@echo "  format             Reformat sources in place with swift-format"
	@echo "  dev                Build and run the app (for development)"
	@echo "  release            Build DMG and Appcast using release-notes/<version>.html"
	@echo "  release-setup      Store notarization credentials in Keychain"
	@echo "  all                Run full build process (default)"
	@echo "  clean              Remove build artifacts"
	@echo "  help               Show this help message"

# Unit tests. Uses its own derived data so it never disturbs `make local`.
# The full xcodebuild log lands in $(TEST_DERIVED_DATA)/test.log; the console shows
# build errors and test failures, and the run is scored from the .xcresult bundle
# (the console stream omits most swift-testing cases).
test: check
	@mkdir -p $(TEST_DERIVED_DATA) && touch $(TEST_DERIVED_DATA)/.metadata_never_index
	@# Removed so a build failure cannot be scored against the previous green run.
	@# Only this explicit bundle is cleared — deleting Xcode's own Logs/Test store
	@# breaks the log importer and produces an unreadable result bundle.
	@rm -rf $(TEST_RESULT_BUNDLE)
	@mkdir -p $(dir $(TEST_RESULT_BUNDLE))
	@SIGNING_IDENTITY=$$(security find-identity -v -p codesigning 2>/dev/null | awk '/"Apple Development: / { print $$2; exit }'); \
	xcodebuild test -project VoxOS.xcodeproj -scheme VoxOS -destination 'platform=macOS' \
		-derivedDataPath $(TEST_DERIVED_DATA) -xcconfig LocalBuild.xcconfig \
		-resultBundlePath $(TEST_RESULT_BUNDLE) \
		-skipPackagePluginValidation -skipMacroValidation -only-testing:VoxOSTests \
		LOCAL_CODE_SIGN_IDENTITY="$${SIGNING_IDENTITY:--}" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=YES DEVELOPMENT_TEAM="" \
		CODE_SIGN_ENTITLEMENTS="$(CURDIR)/VoxOS/VoxOS.local.entitlements" \
		SWIFT_ACTIVE_COMPILATION_CONDITIONS='$$(inherited) LOCAL_BUILD' ENABLE_TESTABILITY=YES \
		VOXOS_BUNDLE_ID_SUFFIX=$(TEST_BUNDLE_ID_SUFFIX) \
		> $(TEST_DERIVED_DATA)/test.log 2>&1; \
	STATUS=$$?; \
	grep -E "[0-9]+: error:|^error:|✘|recorded an issue|Test run|TEST (SUCCEEDED|FAILED)" $(TEST_DERIVED_DATA)/test.log || true; \
	if [ $$STATUS -ne 0 ] && [ ! -d $(TEST_RESULT_BUNDLE) ]; then \
		echo "xcodebuild failed before running any test — see $(TEST_DERIVED_DATA)/test.log"; \
		exit $$STATUS; \
	fi
	@./scripts/test-summary.sh $(TEST_RESULT_BUNDLE)

# Formatting, configured by .swift-format. swift-format ships inside the Xcode
# toolchain rather than on PATH, hence `xcrun`.
# AlwaysUseLowerCamelCase and ReplaceForEachWithForLoop are off: the first cannot tell
# a Codable property whose name is a wire-format JSON key (PolarService decodes
# limit_activations / organization_id / license_key straight from the licensing API)
# from a badly named constant, and the second is a style opinion with no behaviour change.
SWIFT_FORMAT_PATHS := VoxOS Shared VoxOSTests VoxOSRefineXPC

lint:
	@xcrun swift-format lint --strict --recursive --parallel $(SWIFT_FORMAT_PATHS)

format:
	@xcrun swift-format format --in-place --recursive --parallel $(SWIFT_FORMAT_PATHS)
