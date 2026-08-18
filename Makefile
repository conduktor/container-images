# Dev targets for conduktor/container-images.
#
# Enter the dev shell first: `nix develop` (or `direnv allow` if you use direnv),
# or install apko / cosign / trivy / grype / yamllint / actionlint / shellcheck /
# pre-commit yourself.
#
# Usage:
#   make                    # help
#   make build IMAGE=debug  # build one image locally
#   make build-all
#   make lint
#   make scan IMAGE=debug
#   make sbom IMAGE=debug
#   make clean

SHELL := bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := help

# Image inventory — also read by scripts/image-build.sh and both workflows.
MANIFEST      := images/images.json
IMAGES        := $(shell jq -r '[.[].dir] | join(" ")' $(MANIFEST) 2>/dev/null)
IMAGE         ?=
IMAGE_REF     ?=
REPO_ROOT     := $(shell git rev-parse --show-toplevel 2>/dev/null || pwd)
WORKFLOWS_DIR := .github/workflows
# The cdk-* support scripts have no .sh suffix (they are commands), and
# bash.bashrc is named by bash rather than by us, so match both by name rather
# than leaving them unlinted — a syntax error in the bashrc would break every
# interactive shell in the debug image.
SHELL_FILES   := $(shell find . -path ./.git -prune -o -type f \
                   \( -name '*.sh' -o -name 'cdk-*' -o -name 'bash.bashrc' \) \
                   -print 2>/dev/null)
# Tests are discovered, not listed: they live next to what they test, so
# scripts/ has its own and the CI-only ones sit under .github/. A find keeps a
# new tests/ directory from being silently left out of `make test`.
TESTS         := $(shell find . -path ./.git -prune -o -path '*/tests/test-*.sh' -print 2>/dev/null | sort)

.PHONY: help
help: ## Show this help
	@awk 'BEGIN {FS = ":.*##"; printf "Targets:\n"} \
		/^[a-zA-Z_-]+:.*?##/ { printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2 }' $(MAKEFILE_LIST)
	@echo
	@echo "Images: $(IMAGES)"

# --- build -----------------------------------------------------------------

# Local builds are host-arch only — they are test artifacts, and the foreign arch
# would run melange under qemu emulation (minutes, not seconds). The nightly is
# what produces multi-arch; reproduce it with ARCHES=x86_64,aarch64.
ARCHES        ?=

.PHONY: build
build: ## Build one image locally for the host arch (usage: make build IMAGE=debug [IMAGE_REF=...])
	@test -n "$(IMAGE)" || { echo "IMAGE=<one of: $(IMAGES)> is required" >&2; exit 2; }
	MELANGE_ARCHES=$(ARCHES) ./scripts/image-build.sh $(IMAGE) $(IMAGE_REF)

.PHONY: build-all
build-all: ## Build every image locally for the host arch
	@for img in $(IMAGES); do MELANGE_ARCHES=$(ARCHES) ./scripts/image-build.sh $$img; done

.PHONY: packages
packages: ## Build one image's melange*.yaml into local APKs (usage: make packages IMAGE=base-monitoring [ARCHES=...])
	@test -n "$(IMAGE)" || { echo "IMAGE=<one of: $(IMAGES)> is required" >&2; exit 2; }
	./scripts/melange-build.sh $(IMAGE) $(ARCHES)

.PHONY: debug-scripts
debug-scripts: ## Alias for `make packages IMAGE=debug`
	./scripts/melange-build.sh debug $(ARCHES)

.PHONY: debug-shell
debug-shell: ## Build the debug image and drop into it (usage: make debug-shell [TARGET=<container>])
	./scripts/image-build.sh debug
	@if [ -n "$(TARGET)" ]; then \
		echo ">> attaching to container $(TARGET) namespaces as uid 10001"; \
		docker run --rm -it --pid "container:$(TARGET)" --network "container:$(TARGET)" \
			--user 10001:10001 conduktor/conduktor-debug:local bash; \
	else \
		docker run --rm -it conduktor/conduktor-debug:local bash; \
	fi

# --- lint ------------------------------------------------------------------

.PHONY: lint
lint: lint-yaml lint-workflows lint-apko lint-shell ## Run every linter

.PHONY: lint-yaml
lint-yaml: ## yamllint on image configs + workflows
	yamllint -s images/ $(WORKFLOWS_DIR)/

.PHONY: lint-workflows
lint-workflows: ## actionlint on GitHub Actions workflows
	actionlint

.PHONY: lint-apko
lint-apko: ## Validate every apko.yaml parses (apko has no `lint`; show-config does the same job)
	@for img in $(IMAGES); do \
		echo ">> apko show-config images/$$img/apko.yaml"; \
		( cd images/$$img && apko show-config apko.yaml > /dev/null ); \
	done

.PHONY: lint-shell
lint-shell: ## shellcheck every shell script (scripts/, .github/scripts/, image tools/)
	@# Uses whatever shellcheck is on PATH. CI runs the version pinned in
	@# .pre-commit-config.yaml instead — see `make precommit-run` if they disagree.
	shellcheck -x $(SHELL_FILES)

# --- test ------------------------------------------------------------------

.PHONY: test
test: ## Run the script unit tests (fixture-based, no network)
	@for t in $(TESTS); do echo ">> $$t"; bash $$t; done

# --- scan ------------------------------------------------------------------

.PHONY: scan
scan: ## Trivy + Grype scan of a locally-built image tar (usage: make scan IMAGE=debug)
	@test -n "$(IMAGE)" || { echo "IMAGE=<one of: $(IMAGES)> is required" >&2; exit 2; }
	@test -f images/$(IMAGE)/$(IMAGE).tar || { echo "images/$(IMAGE)/$(IMAGE).tar missing — run 'make build IMAGE=$(IMAGE)' first" >&2; exit 2; }
	@echo ">> Trivy scan images/$(IMAGE)/$(IMAGE).tar"
	trivy image --input images/$(IMAGE)/$(IMAGE).tar --severity CRITICAL,HIGH,MEDIUM --ignore-unfixed
	@echo ">> Grype scan images/$(IMAGE)/$(IMAGE).tar"
	grype "docker-archive:images/$(IMAGE)/$(IMAGE).tar" --only-fixed=false

.PHONY: sbom
sbom: ## Print the SPDX SBOM produced by the last apko build (usage: make sbom IMAGE=debug)
	@test -n "$(IMAGE)" || { echo "IMAGE=<one of: $(IMAGES)> is required" >&2; exit 2; }
	@ls images/$(IMAGE)/*.spdx.json >/dev/null 2>&1 || { echo "no SBOM found in images/$(IMAGE)/ — run 'make build IMAGE=$(IMAGE)' first" >&2; exit 2; }
	@jq . images/$(IMAGE)/*.spdx.json | less -R

# --- pre-commit ------------------------------------------------------------

.PHONY: precommit-install
precommit-install: ## Install pre-commit git hooks
	pre-commit install --install-hooks
	pre-commit install --hook-type commit-msg || true

.PHONY: precommit-run
precommit-run: ## Run every pre-commit hook against all files
	pre-commit run --all-files

# --- clean -----------------------------------------------------------------

.PHONY: clean
clean: ## Remove local build artifacts (tars + SBOM files)
	@for img in $(IMAGES); do \
		rm -f images/$$img/$$img.tar; \
		rm -f images/$$img/*.spdx.json; \
	done
	@echo "cleaned"
