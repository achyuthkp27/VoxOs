# Define a directory for dependencies in the user's home folder
DEPS_DIR := $(HOME)/VoxOS-Dependencies
WHISPER_CPP_DIR := $(DEPS_DIR)/whisper.cpp
FRAMEWORK_PATH := $(WHISPER_CPP_DIR)/build-apple/whisper.xcframework
LOCAL_DERIVED_DATA := $(CURDIR)/.local-build
LOCAL_CODESIGN_IDENTITY ?=
# `make local` installs straight to /Applications so no stray copies are left
# lying around in ~/Downloads for Spotlight to index.
INSTALL_PATH ?= /Applications/VoxOS.app

.PHONY: all clean whisper setup build local check healthcheck help dev run release release-setup test

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

# Build process
whisper:
	@mkdir -p $(DEPS_DIR)
	@if [ ! -d "$(FRAMEWORK_PATH)" ]; then \
		echo "Building whisper.xcframework in $(DEPS_DIR)..."; \
		if [ ! -d "$(WHISPER_CPP_DIR)" ]; then \
			git clone https://github.com/ggerganov/whisper.cpp.git $(WHISPER_CPP_DIR); \
		else \
			(cd $(WHISPER_CPP_DIR) && git pull); \
		fi; \
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

# Help
help:
	@echo "Available targets:"
	@echo "  check/healthcheck  Check if required CLI tools are installed"
	@echo "  whisper            Clone and build whisper.cpp XCFramework"
	@echo "  setup              Copy whisper XCFramework to VoxOS project"
	@echo "  build              Build the VoxOS Xcode project"
	@echo "  local              Build locally with stable signing when available"
	@echo "    LOCAL_CODESIGN_IDENTITY=<SHA or name> overrides automatic Apple Development detection"
	@echo "  run                Launch the built VoxOS app"
	@echo "  dev                Build and run the app (for development)"
	@echo "  release            Build DMG and Appcast using release-notes/<version>.html"
	@echo "  release-setup      Store notarization credentials in Keychain"
	@echo "  all                Run full build process (default)"
	@echo "  clean              Remove build artifacts"
	@echo "  help               Show this help message"

# Unit tests (agent logic). Uses its own derived data so it never disturbs `make local`.
test: check
	@mkdir -p .local-build-tests && touch .local-build-tests/.metadata_never_index
	@SIGNING_IDENTITY=$$(security find-identity -v -p codesigning 2>/dev/null | awk '/"Apple Development: / { print $$2; exit }'); \
	xcodebuild test -project VoxOS.xcodeproj -scheme VoxOS -destination 'platform=macOS' \
		-derivedDataPath .local-build-tests -xcconfig LocalBuild.xcconfig \
		-skipPackagePluginValidation -skipMacroValidation -only-testing:VoxOSTests \
		LOCAL_CODE_SIGN_IDENTITY="$${SIGNING_IDENTITY:--}" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=YES DEVELOPMENT_TEAM="" \
		CODE_SIGN_ENTITLEMENTS="$(CURDIR)/VoxOS/VoxOS.local.entitlements" \
		SWIFT_ACTIVE_COMPILATION_CONDITIONS='$$(inherited) LOCAL_BUILD' ENABLE_TESTABILITY=YES \
		2>&1 | grep -E "Test case|Executed|error:" | sed -E "s/ on 'My Mac.*//" | sort -u
