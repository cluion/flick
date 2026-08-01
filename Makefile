FLUTTER ?= fvm flutter
DART ?= fvm dart
GO ?= go
ifeq ($(OS),Windows_NT)
EXECUTABLE_SUFFIX := .exe
else
EXECUTABLE_SUFFIX :=
endif

BRIDRA := $(GO) run github.com/cluion/bridra/backend/cmd/bridra
SIDECAR := $(CURDIR)/build/sidecar/bridra_backend$(EXECUTABLE_SUFFIX)
SERVER := $(CURDIR)/build/server/bridra_server$(EXECUTABLE_SUFFIX)
BACKEND_TOKEN ?= dev-token
BUILD_MODE ?= release

.PHONY: doctor generate codegen-check backend-build backend-serve run test analyze verify \
	linux-build macos-build windows-build

doctor:
	cd backend && $(BRIDRA) doctor --root ..

generate:
	cd backend && $(BRIDRA) generate \
		--schema ../schema/bridra.json \
		--root .. \
		--framework-import github.com/cluion/bridra/backend/framework \
		--dart-runtime-import package:bridra_flutter/bridra_flutter.dart

codegen-check:
	cd backend && $(BRIDRA) generate \
		--schema ../schema/bridra.json \
		--root .. \
		--framework-import github.com/cluion/bridra/backend/framework \
		--dart-runtime-import package:bridra_flutter/bridra_flutter.dart \
		--check

backend-build:
	mkdir -p $(dir $(SIDECAR)) $(dir $(SERVER))
	cd backend && CGO_ENABLED=0 $(GO) build -trimpath -o $(SIDECAR) ./cmd/sidecar
	cd backend && CGO_ENABLED=0 $(GO) build -trimpath -o $(SERVER) ./cmd/server

backend-serve: backend-build
	BRIDRA_BACKEND_TOKEN=$(BACKEND_TOKEN) $(SERVER)

run: backend-build
	BRIDRA_SIDECAR_PATH=$(SIDECAR) $(FLUTTER) run

test:
	cd backend && $(GO) test ./...
	$(FLUTTER) test

analyze:
	$(FLUTTER) analyze

verify: doctor codegen-check test analyze

linux-build:
	cd backend && $(BRIDRA) build linux --root .. --mode $(BUILD_MODE)

macos-build:
	cd backend && $(BRIDRA) build macos --root .. --mode $(BUILD_MODE)

windows-build:
	cd backend && $(BRIDRA) build windows --root .. --mode $(BUILD_MODE)
