# The CAPTF documentation book (https://captf.io/docs/), split out of
# cluster-api-provider-terraform. The pages live in src and render from
# there; book.toml is at the repo root.
#
# Every tool is installed at a pinned version into hack/tools/bin as
# <name>-<version> plus an unversioned symlink, so bumping a version
# re-downloads.

SHELL := /usr/bin/env bash
.SHELLFLAGS := -euo pipefail -c
.DEFAULT_GOAL := help

ROOT_DIR := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))

## --------------------------------------
## Versions
## --------------------------------------

# The mdBook the Cluster API book pins (hack/scripts/ensure/ensure-mdbook.sh
# in the provider repo).
MDBOOK_VER := v0.5.4
# First mdbook-mermaid release on the mdbook-preprocessor 0.5.x crate, so the
# first one compatible with mdBook 0.5.4 (v0.16.2 and earlier build against
# the mdbook 0.4 crate and are rejected as version-mismatched).
MDBOOK_MERMAID_VER := v0.17.1
# Link checker over the built book; offline, no `vale sync`-style network use.
LYCHEE_VER := lychee-v0.24.2
VALE_VER := v3.23.0
# markdownlint-cli2 is installed with npm (hack/tools/markdownlint), not a
# release binary; the version is pinned in hack/tools/markdownlint/package.json.

## --------------------------------------
## Tool binaries
## --------------------------------------

TOOLS_DIR := $(ROOT_DIR)/hack/tools
TOOLS_BIN := $(TOOLS_DIR)/bin

MDBOOK := $(TOOLS_BIN)/mdbook-$(MDBOOK_VER)
MDBOOK_MERMAID := $(TOOLS_BIN)/mdbook-mermaid-$(MDBOOK_MERMAID_VER)
LYCHEE := $(TOOLS_BIN)/lychee-$(LYCHEE_VER)
VALE := $(TOOLS_BIN)/vale-$(VALE_VER)
MARKDOWNLINT := $(TOOLS_DIR)/markdownlint/node_modules/.bin/markdownlint-cli2
# The mermaid JS the book loads (book.toml additional-js), extracted from the
# pinned mdbook-mermaid binary rather than committed.
MERMAID_JS := mermaid.min.js mermaid-init.js

HOST_OS := $(shell go env GOOS 2>/dev/null || uname -s | tr '[:upper:]' '[:lower:]')
HOST_ARCH := $(shell go env GOARCH 2>/dev/null || { a="$$(uname -m)"; [[ "$$a" == x86_64 ]] && echo amd64 || { [[ "$$a" == aarch64 || "$$a" == arm64 ]] && echo arm64 || echo "$$a"; }; })

# mdBook comes out of the release tarball for the host's Rust target (musl
# for linux/arm64, which has no gnu build). mdBook publishes no checksums;
# these are sha256sum of each v0.5.4 asset as downloaded on 2026-09-28.
MDBOOK_TARGET_linux_amd64 := x86_64-unknown-linux-gnu
MDBOOK_TARGET_linux_arm64 := aarch64-unknown-linux-musl
MDBOOK_TARGET_darwin_amd64 := x86_64-apple-darwin
MDBOOK_TARGET_darwin_arm64 := aarch64-apple-darwin
MDBOOK_SHA256_linux_amd64 := 3f28de05dafca9d0f2eab99c662116b0e37b89b1d96a08f8f430b9eeae958cd7
MDBOOK_SHA256_linux_arm64 := 753e5c5c363ee8a56972344dcf91466f005a51db84a7aeffe427ae3ef83d6d44
MDBOOK_SHA256_darwin_amd64 := a47d7bf0d5d670cff9ee6cce95537cbeb62dc10704d9e7131ffbd13e2b59a5de
MDBOOK_SHA256_darwin_arm64 := 03e8a6d8b13a2971e0b3280affd03b388373c1485e26f73407c3a76b0b1838df
# mdbook-mermaid v0.17.1 depends on mdbook-preprocessor 0.5.0, the first
# release built against mdBook's 0.5 preprocessor API (mdBook 0.5.4 accepts
# it with an informational "built against 0.5.0" notice, not a WARN/ERROR
# line). No aarch64-unknown-linux-gnu asset is published, only musl. No
# checksums file is published; these are sha256sum of each v0.17.1 asset as
# downloaded on 2026-09-28.
MDBOOK_MERMAID_TARGET_linux_amd64 := x86_64-unknown-linux-gnu
MDBOOK_MERMAID_TARGET_linux_arm64 := aarch64-unknown-linux-musl
MDBOOK_MERMAID_TARGET_darwin_amd64 := x86_64-apple-darwin
MDBOOK_MERMAID_TARGET_darwin_arm64 := aarch64-apple-darwin
MDBOOK_MERMAID_SHA256_linux_amd64 := 9afcfa5b8463afe606d48595a7ae338564302903e626ea5b6edb8007d29393a5
MDBOOK_MERMAID_SHA256_linux_arm64 := b1782ecaf775bfbe069dead6cdd8ac7cc739d5e62d138bd0e800efec6467cf3a
MDBOOK_MERMAID_SHA256_darwin_amd64 := 9b752cc4f26251eaa5d85564345a6f7c8447a922ba6acbfa6ee4f2a17a68ef7e
MDBOOK_MERMAID_SHA256_darwin_arm64 := 5be76bfffefd36efe5abf876c52530ba03c16df5f44c94164cc9ca88d16df1e1
# lychee release assets are Rust target triples; the sha256 is the release's
# own published `<asset>.sha256` file, fetched 2026-09-28.
LYCHEE_TARGET_linux_amd64 := x86_64-unknown-linux-gnu
LYCHEE_TARGET_linux_arm64 := aarch64-unknown-linux-gnu
LYCHEE_TARGET_darwin_amd64 := x86_64-apple-darwin
LYCHEE_TARGET_darwin_arm64 := aarch64-apple-darwin
LYCHEE_SHA256_linux_amd64 := 1f4e0ef7f6554a6ed33dd7ac144fb2e1bbed98598e7af973042fc5cd43951c9a
LYCHEE_SHA256_linux_arm64 := 91a7bd65685da41b90ccb9bc867a3d649a7818042dae04ff405e55a25bddee4c
LYCHEE_SHA256_darwin_amd64 := 887503a9cff667d322b8d0892b40bf49976eb9507af8483220a3706cdad55978
LYCHEE_SHA256_darwin_arm64 := c9d3740ea2d891854d37116c9fba840f37b6e7c89d330e7db84ac333631c4977
# vale release assets use mixed-case OS/arch names, not target triples; the
# sha256 is from the release's published vale_<version>_checksums.txt,
# fetched 2026-09-28.
VALE_ASSET_linux_amd64 := Linux_64-bit
VALE_ASSET_linux_arm64 := Linux_arm64
VALE_ASSET_darwin_amd64 := macOS_64-bit
VALE_ASSET_darwin_arm64 := macOS_arm64
VALE_SHA256_linux_amd64 := cc35445a45186b8f0b01e11c01359694cf941e72cf6ab0fc44774f0e54c9d5fc
VALE_SHA256_linux_arm64 := 45720aadcb01401ac394641287a2c74e094045a89a450f5edcf98c8969df0884
VALE_SHA256_darwin_amd64 := 416fdd3ba32e32dc71c87b479cb86757bb6437bcebc7a3e4a095e863b7ce583d
VALE_SHA256_darwin_arm64 := b913574b2c83b541d8bc2d8938e53a58a2fb06bab15135efcc755afb074f4430

##@ Documentation

.PHONY: build
build: $(MDBOOK) $(MDBOOK_MERMAID) $(MERMAID_JS) ## Build the book (book.toml) into bin/book.
	MDBOOK_preprocessor__mermaid__command="$(MDBOOK_MERMAID)" "$(MDBOOK)" build .

.PHONY: serve
serve: $(MDBOOK) $(MDBOOK_MERMAID) $(MERMAID_JS) ## Serve the book on http://localhost:3001, rebuilding on change.
	MDBOOK_preprocessor__mermaid__command="$(MDBOOK_MERMAID)" "$(MDBOOK)" serve . -p 3001

.PHONY: verify-book
verify-book: $(MDBOOK) $(MDBOOK_MERMAID) $(MERMAID_JS) ## Build the book and fail on any mdBook WARN/ERROR (mdBook has no fail-on-warning flag).
	@status=0; \
	out="$$(MDBOOK_preprocessor__mermaid__command="$(MDBOOK_MERMAID)" "$(MDBOOK)" build . 2>&1)" || status=$$?; \
	echo "$$out"; \
	if [[ $$status -ne 0 ]]; then echo "verify-book: mdbook build failed" >&2; exit 1; fi; \
	if grep -qE '^[[:space:]]*(WARN|ERROR)[[:space:]]' <<<"$$out"; then \
		echo "verify-book: mdbook reported WARN/ERROR" >&2; exit 1; fi

# The book is served under /docs/ (book.toml site-url), so 404.html links
# absolutely to /docs/...; --remap maps that prefix back onto bin/book.
.PHONY: links
links: verify-book $(LYCHEE) ## Check every internal link and #fragment in the rendered book (offline).
	"$(LYCHEE)" --offline --include-fragments --root-dir "$(ROOT_DIR)/bin/book" \
		--remap '^file://$(ROOT_DIR)/bin/book/docs(/|$$) file://$(ROOT_DIR)/bin/book/' \
		"$(ROOT_DIR)/bin/book"

.PHONY: lint-md
lint-md: $(MARKDOWNLINT) ## Lint Markdown docs with markdownlint-cli2 (part of verify).
	@log="$$(mktemp)"; trap 'rm -f "$$log"' EXIT; \
	status=0; \
	cd "$(ROOT_DIR)" && { "$(MARKDOWNLINT)" >"$$log" 2>&1 || status=$$?; }; \
	cat "$$log"; \
	echo; echo "lint-md: violations by rule:"; \
	grep -oE 'MD[0-9]+/[a-zA-Z-]+' "$$log" | sort | uniq -c | sort -rn || true; \
	exit $$status

.PHONY: lint-prose
lint-prose: $(VALE) ## Lint doc prose with vale against the house style (part of verify).
	@log="$$(mktemp)"; trap 'rm -f "$$log"' EXIT; \
	status=0; \
	cd "$(ROOT_DIR)" && { "$(VALE)" --config .vale.ini src README.md >"$$log" 2>&1 || status=$$?; }; \
	cat "$$log"; \
	echo; echo "lint-prose: violations by rule:"; \
	grep -oE 'CAPTF\.[A-Za-z]+' "$$log" | sort | uniq -c | sort -rn || true; \
	{ grep -qE 'CAPTF\.[A-Za-z]+' "$$log" && status=1; } || true; \
	exit $$status

##@ Verify

.PHONY: verify
verify: verify-book links lint-md lint-prose ## Run all verifications.

##@ Tools

$(MDBOOK):
	@mkdir -p "$(TOOLS_BIN)"
	@echo "Downloading mdbook $(MDBOOK_VER) ($(HOST_OS)/$(HOST_ARCH))"
	@want="$(MDBOOK_SHA256_$(HOST_OS)_$(HOST_ARCH))"; \
	if [[ -z "$$want" ]]; then echo "mdbook: no pinned sha256 for $(HOST_OS)/$(HOST_ARCH)" >&2; exit 1; fi; \
	work="$$(mktemp -d "$(TOOLS_BIN)/.mdbook.XXXXXX")"; \
	trap 'if [[ "$$work" == "$(TOOLS_BIN)/.mdbook."* ]]; then rm -rf -- "$$work"; fi' EXIT; \
	curl -fsSL -o "$$work/m.tar.gz" "https://github.com/rust-lang/mdBook/releases/download/$(MDBOOK_VER)/mdbook-$(MDBOOK_VER)-$(MDBOOK_TARGET_$(HOST_OS)_$(HOST_ARCH)).tar.gz"; \
	echo "$$want  $$work/m.tar.gz" | sha256sum -c --quiet -; \
	tar -xzf "$$work/m.tar.gz" -C "$$work" mdbook; \
	mv "$$work/mdbook" "$@"; \
	ln -sfn "$(notdir $@)" "$(TOOLS_BIN)/mdbook"

$(MDBOOK_MERMAID):
	@mkdir -p "$(TOOLS_BIN)"
	@echo "Downloading mdbook-mermaid $(MDBOOK_MERMAID_VER) ($(HOST_OS)/$(HOST_ARCH))"
	@want="$(MDBOOK_MERMAID_SHA256_$(HOST_OS)_$(HOST_ARCH))"; \
	if [[ -z "$$want" ]]; then echo "mdbook-mermaid: no pinned sha256 for $(HOST_OS)/$(HOST_ARCH)" >&2; exit 1; fi; \
	work="$$(mktemp -d "$(TOOLS_BIN)/.mdbook-mermaid.XXXXXX")"; \
	trap 'if [[ "$$work" == "$(TOOLS_BIN)/.mdbook-mermaid."* ]]; then rm -rf -- "$$work"; fi' EXIT; \
	curl -fsSL -o "$$work/mm.tar.gz" "https://github.com/badboy/mdbook-mermaid/releases/download/$(MDBOOK_MERMAID_VER)/mdbook-mermaid-$(MDBOOK_MERMAID_VER)-$(MDBOOK_MERMAID_TARGET_$(HOST_OS)_$(HOST_ARCH)).tar.gz"; \
	echo "$$want  $$work/mm.tar.gz" | sha256sum -c --quiet -; \
	tar -xzf "$$work/mm.tar.gz" -C "$$work" mdbook-mermaid; \
	mv "$$work/mdbook-mermaid" "$@"; \
	ln -sfn "$(notdir $@)" "$(TOOLS_BIN)/mdbook-mermaid"

$(LYCHEE):
	@mkdir -p "$(TOOLS_BIN)"
	@echo "Downloading lychee $(LYCHEE_VER) ($(HOST_OS)/$(HOST_ARCH))"
	@want="$(LYCHEE_SHA256_$(HOST_OS)_$(HOST_ARCH))"; \
	if [[ -z "$$want" ]]; then echo "lychee: no pinned sha256 for $(HOST_OS)/$(HOST_ARCH)" >&2; exit 1; fi; \
	target="$(LYCHEE_TARGET_$(HOST_OS)_$(HOST_ARCH))"; \
	work="$$(mktemp -d "$(TOOLS_BIN)/.lychee.XXXXXX")"; \
	trap 'if [[ "$$work" == "$(TOOLS_BIN)/.lychee."* ]]; then rm -rf -- "$$work"; fi' EXIT; \
	curl -fsSL -o "$$work/ly.tar.gz" "https://github.com/lycheeverse/lychee/releases/download/$(LYCHEE_VER)/lychee-$$target.tar.gz"; \
	echo "$$want  $$work/ly.tar.gz" | sha256sum -c --quiet -; \
	tar -xzf "$$work/ly.tar.gz" -C "$$work" "lychee-$$target/lychee"; \
	mv "$$work/lychee-$$target/lychee" "$@"; \
	ln -sfn "$(notdir $@)" "$(TOOLS_BIN)/lychee"

$(VALE):
	@mkdir -p "$(TOOLS_BIN)"
	@echo "Downloading vale $(VALE_VER) ($(HOST_OS)/$(HOST_ARCH))"
	@want="$(VALE_SHA256_$(HOST_OS)_$(HOST_ARCH))"; \
	if [[ -z "$$want" ]]; then echo "vale: no pinned sha256 for $(HOST_OS)/$(HOST_ARCH)" >&2; exit 1; fi; \
	asset="$(VALE_ASSET_$(HOST_OS)_$(HOST_ARCH))"; \
	ext="tar.gz"; \
	work="$$(mktemp -d "$(TOOLS_BIN)/.vale.XXXXXX")"; \
	trap 'if [[ "$$work" == "$(TOOLS_BIN)/.vale."* ]]; then rm -rf -- "$$work"; fi' EXIT; \
	curl -fsSL -o "$$work/vale.$$ext" "https://github.com/errata-ai/vale/releases/download/$(VALE_VER)/vale_$(VALE_VER:v%=%)_$$asset.$$ext"; \
	echo "$$want  $$work/vale.$$ext" | sha256sum -c --quiet -; \
	tar -xzf "$$work/vale.$$ext" -C "$$work" vale; \
	mv "$$work/vale" "$@"; \
	ln -sfn "$(notdir $@)" "$(TOOLS_BIN)/vale"

# mdbook-mermaid install writes the JS next to a book.toml and edits that
# file, so it runs against a scratch book and only the JS is copied out.
mermaid.min.js: $(MDBOOK_MERMAID)
	@work="$$(mktemp -d)"; trap 'rm -rf -- "$$work"' EXIT; \
	printf '[book]\ntitle = "mermaid"\n' >"$$work/book.toml"; \
	"$(MDBOOK_MERMAID)" install "$$work" >/dev/null 2>&1; \
	cp "$$work/mermaid.min.js" "$$work/mermaid-init.js" .

mermaid-init.js: mermaid.min.js

# markdownlint-cli2 is pinned via hack/tools/markdownlint/package.json and a
# committed package-lock.json, installed hermetically with `npm ci` (no
# version resolution against the registry beyond what the lockfile records).
$(MARKDOWNLINT): hack/tools/markdownlint/package.json hack/tools/markdownlint/package-lock.json
	npm ci --prefix hack/tools/markdownlint
	@touch "$@"

##@ Cleanup

.PHONY: clean
clean: ## Remove build output (bin/) and extracted mermaid JS.
	rm -rf bin/ mermaid.min.js mermaid-init.js

##@ General

.PHONY: help
help: ## Display this help.
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} /^[a-zA-Z_0-9-]+:.*?##/ { printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)
