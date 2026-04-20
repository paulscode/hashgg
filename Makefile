PKG_ID := $(shell yq -e ".id" manifest.yaml)
PKG_VERSION := $(shell yq -e ".version" manifest.yaml)
BUILD_DIR := builds/$(PKG_VERSION)
TS_FILES := $(shell find . -name \*.ts -not -path './startos/*' -not -path './node_modules/*' )

.DELETE_ON_ERROR:

all: verify

verify: $(PKG_ID).s9pk
	@start-sdk verify s9pk $(PKG_ID).s9pk
	@echo " Done!"
	@echo "   Filesize: $(shell du -h $(PKG_ID).s9pk) is ready"

install:
	@if [ ! -f ~/.embassy/config.yaml ]; then echo "You must define \"host: http://server-name.local\" in ~/.embassy/config.yaml config file first."; exit 1; fi
	@echo "\nInstalling to $$(grep -v '^#' ~/.embassy/config.yaml | cut -d'/' -f3) ...\n"
	@[ -f $(PKG_ID).s9pk ] || ( $(MAKE) && echo "\nInstalling to $$(grep -v '^#' ~/.embassy/config.yaml | cut -d'/' -f3) ...\n" )
	@start-cli package install $(PKG_ID).s9pk

release: verify
	rm -rf $(BUILD_DIR)
	mkdir -p $(BUILD_DIR)
	cp $(PKG_ID).s9pk $(BUILD_DIR)/
	cd $(BUILD_DIR) && sha256sum hashgg.s9pk > SHA256SUMS

clean:
	rm -rf docker-images
	rm -f $(PKG_ID).s9pk
	rm -f scripts/*.js

scripts/embassy.js: $(TS_FILES)
	deno run --allow-read --allow-write --allow-net --allow-env scripts/bundle.ts

arm:
	@rm -f docker-images/x86_64.tar
	ARCH=aarch64 $(MAKE)

x86:
	@rm -f docker-images/aarch64.tar
	ARCH=x86_64 $(MAKE)

docker-images/aarch64.tar: Dockerfile docker_entrypoint.sh check-tunnel.sh check-datum.sh app/backend/server.js app/frontend/index.html icon.png INSTRUCTIONS.md
ifeq ($(ARCH),x86_64)
else
	mkdir -p docker-images
	docker buildx build --tag start9/$(PKG_ID)/main:$(PKG_VERSION) --build-arg ARCH=aarch64 --build-arg PLATFORM=arm64 --platform=linux/arm64 -o type=docker,dest=docker-images/aarch64.tar .
endif

docker-images/x86_64.tar: Dockerfile docker_entrypoint.sh check-tunnel.sh check-datum.sh app/backend/server.js app/frontend/index.html icon.png INSTRUCTIONS.md
ifeq ($(ARCH),aarch64)
else
	mkdir -p docker-images
	docker buildx build --tag start9/$(PKG_ID)/main:$(PKG_VERSION) --build-arg ARCH=x86_64 --build-arg PLATFORM=amd64 --platform=linux/amd64 -o type=docker,dest=docker-images/x86_64.tar .
endif

$(PKG_ID).s9pk: manifest.yaml INSTRUCTIONS.md icon.png LICENSE scripts/embassy.js docker-images/aarch64.tar docker-images/x86_64.tar
ifeq ($(ARCH),aarch64)
	@echo "start-sdk: Preparing aarch64 package ..."
else ifeq ($(ARCH),x86_64)
	@echo "start-sdk: Preparing x86_64 package ..."
else
	@echo "start-sdk: Preparing Universal Package ..."
endif
	@start-sdk pack

# === StartOS 0.4.0 targets ===
.PHONY: pack-040 pack-040-x86 pack-040-arm install-040 clean-040 release-all

pack-040: pack-040-x86 pack-040-arm

pack-040-x86: javascript/index.js
	start-cli s9pk pack --arch=x86_64 -o $(PKG_ID)_x86_64.s9pk

pack-040-arm: javascript/index.js
	start-cli s9pk pack --arch=aarch64 -o $(PKG_ID)_aarch64.s9pk

javascript/index.js: $(shell find startos -type f 2>/dev/null) tsconfig.json node_modules
	npm run build

node_modules: package-lock.json
	npm ci

package-lock.json: package.json
	npm i

install-040: pack-040-x86
	@HOST=$$(awk -F'/' '/^host:/ {print $$3}' ~/.startos/config.yaml); \
	if [ -z "$$HOST" ]; then echo "Error: Define \"host: http://server-name.local\" in ~/.startos/config.yaml"; exit 1; fi; \
	printf "\nInstalling to $$HOST ...\n"; \
	start-cli package install -s $(PKG_ID)_x86_64.s9pk

# Build both 0.3.5.1 and 0.4.0 universal packages into builds/<version>/
release-all: verify javascript/index.js
	rm -rf $(BUILD_DIR)
	mkdir -p $(BUILD_DIR)
	cp $(PKG_ID).s9pk $(BUILD_DIR)/hashgg-0351.s9pk
	start-cli s9pk pack -o $(BUILD_DIR)/hashgg-040.s9pk
	cd $(BUILD_DIR) && sha256sum *.s9pk > SHA256SUMS
	@echo ""
	@echo "Release builds:"
	@ls -lh $(BUILD_DIR)/
	@echo ""
	@cat $(BUILD_DIR)/SHA256SUMS

clean-040:
	rm -f $(PKG_ID)_x86_64.s9pk $(PKG_ID)_aarch64.s9pk
	rm -rf javascript node_modules

clean-all: clean clean-040
