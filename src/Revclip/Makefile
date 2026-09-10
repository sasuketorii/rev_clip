# Copyright (c) 2024-2026 Revclip. Licensed under the MIT License.
# Revclip Makefile - run all workflows from the terminal.

.PHONY: setup build debug release test clean run sign dmg

PROJECT = Revclip.xcodeproj
SCHEME = Revclip
CONFIG_DEBUG = Debug
CONFIG_RELEASE = Release
BUILD_DIR = $(CURDIR)/build
APP_DEBUG = $(BUILD_DIR)/Debug/Revclip.app
APP_RELEASE = $(BUILD_DIR)/Release/Revclip.app

setup:
	xcodegen generate

build: debug

debug:
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration $(CONFIG_DEBUG) \
		SYMROOT=$(BUILD_DIR) build

release:
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration $(CONFIG_RELEASE) \
		-arch arm64 -arch x86_64 ONLY_ACTIVE_ARCH=NO \
		CODE_SIGN_IDENTITY="$(CODE_SIGN_IDENTITY)" \
		OTHER_CODE_SIGN_FLAGS="--options=runtime" \
		SYMROOT=$(BUILD_DIR) build

test:
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration $(CONFIG_DEBUG) \
		SYMROOT=$(BUILD_DIR) test

clean:
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) clean
	rm -rf $(BUILD_DIR)

run: debug
	open $(APP_DEBUG)

sign:
	codesign --verify --verbose=4 $(APP_RELEASE)
	spctl --assess --type execute --verbose $(APP_RELEASE)

dmg:
	bash Scripts/create_dmg.sh
