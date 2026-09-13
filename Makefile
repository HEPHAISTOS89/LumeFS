SHELL := /bin/zsh
PROJECT := LumeFS.xcodeproj
SCHEME := LumeFS
DERIVED_DATA := DerivedData

.PHONY: generate build test clean run

generate:
	@command -v xcodegen >/dev/null || { echo "Install XcodeGen: brew install xcodegen"; exit 1; }
	xcodegen generate

build:
	xcodebuild \
		-project $(PROJECT) \
		-scheme $(SCHEME) \
		-configuration Debug \
		-destination 'platform=macOS' \
		-derivedDataPath $(DERIVED_DATA) \
		build

test:
	xcodebuild \
		-project $(PROJECT) \
		-scheme $(SCHEME) \
		-configuration Debug \
		-destination 'platform=macOS' \
		-derivedDataPath $(DERIVED_DATA) \
		test

run: build
	open $(DERIVED_DATA)/Build/Products/Debug/LumeFS.app

clean:
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) clean
