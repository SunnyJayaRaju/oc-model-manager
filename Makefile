# ============================================================================
# Makefile — Build, test, and release automation
# ============================================================================

VERSION := $(shell cat VERSION)
DIST_DIR := dist/ocprobe-$(VERSION)
PACKAGE := dist/ocprobe-$(VERSION).tar.gz

.PHONY: all lint test test-unit test-integration build package install uninstall clean help man drift-check

all: lint test build

help:
	@echo "Available targets:"
	@echo "  make lint           - Run shellcheck on all scripts"
	@echo "  make test           - Run all tests (unit + integration)"
	@echo "  make test-unit      - Run unit tests only"
	@echo "  make test-integration - Run integration tests only"
	@echo "  make build          - Create distribution package"
	@echo "  make install        - Install to ~/.local/bin"
	@echo "  make uninstall      - Remove from ~/.local/bin"
	@echo "  make clean          - Clean build artifacts"
	@echo "  make man            - Generate man page from Markdown"
	@echo "  make release        - Create GitHub release (requires tag)"
	@echo "  make drift-check    - Check version/tag/binary/PATH drift"

lint:
	@echo "Running shellcheck..."
	@# This list is kept identical to the Lint job's in .github/workflows/ci.yml,
	@# so that `make lint` locally and the CI gate check the same files. Two gaps
	@# came from them drifting apart:
	@#   - `scripts/*.sh` alone matched exactly ONE file. A shell glob does not
	@#     cross a directory boundary, so all seven of scripts/ci/ were unlinted --
	@#     including verify-release.sh -- and the gate reported "clean" about
	@#     scripts it had never looked at.
	@#   - bin/oc-model-audit.sh, bin/oc-model-manager and bin/oc-session-backup
	@#     were in the CI list but not in this one, so a developer running
	@#     `make lint` saw less than CI did.
	@# test/unit/lint_coverage.bats fails if the two lists stop covering every
	@# tracked shell script.
	@shellcheck --severity=warning bin/ocprobe bin/oc-model-manager bin/oc-model-audit.sh bin/oc-session-backup lib/*.sh scripts/*.sh scripts/*/*.sh
	@echo "Checking bash syntax..."
	@for f in bin/ocprobe bin/oc-model-manager bin/oc-model-audit.sh bin/oc-session-backup lib/*.sh scripts/*.sh scripts/*/*.sh; do bash -n "$$f" || exit 1; done
	@echo "Lint passed"

test: test-unit test-integration

test-unit:
	@echo "Running unit tests..."
	@bats test/unit/

test-integration:
	@echo "Running integration tests..."
	@bats test/integration/

build: $(PACKAGE)

$(PACKAGE): $(DIST_DIR)
	@echo "Creating package..."
	# COPYFILE_DISABLE=1: on macOS, bsdtar synthesises an AppleDouble ._* file
	# for every file it archives that carries an extended attribute, so the
	# tarball grows one junk member per real file (35 of 70 for v3.1.3). They are
	# never on disk -- `find -delete` finds nothing -- because they are created at
	# archive time. The variable is meaningless to GNU tar, which is what the
	# release build job runs. Enforced by test/unit/package_tarball_clean.bats.
	@cd dist && COPYFILE_DISABLE=1 tar -c ocprobe-$(VERSION)/ | gzip -n > ocprobe-$(VERSION).tar.gz
	@cd dist && sha256sum ocprobe-$(VERSION).tar.gz > ocprobe-$(VERSION).tar.gz.sha256
	@echo "Package: $(PACKAGE)"

$(DIST_DIR):
	@if [ ! -f docs/ocprobe.1 ]; then \
		echo "WARNING: docs/ocprobe.1 (man page) not found — run 'make man' first (requires pandoc) if you need it in this build. Packaging will continue without it." >&2; \
	fi
	@mkdir -p $(DIST_DIR)
	@cp -r bin lib config VERSION CHANGELOG.md LICENSE README.md CONTRIBUTING.md docs $(DIST_DIR)/
	# Normalize timestamps for reproducible builds
	@find $(DIST_DIR) -exec touch -t 202401010000 {} +

# Man page generation
man: docs/ocprobe.1

docs/ocprobe.1: docs/ocprobe.1.md
	pandoc docs/ocprobe.1.md -s -t man -o docs/ocprobe.1

install: $(PACKAGE)
	@echo "Installing to ~/.local..."
	@mkdir -p ~/.local/bin ~/.local/lib/ocprobe ~/.local/share/ocprobe
	@tar -xzf $(PACKAGE) -C /tmp/
	@cp /tmp/ocprobe-$(VERSION)/bin/ocprobe ~/.local/bin/ocprobe
	@chmod +x ~/.local/bin/ocprobe
	@# Copy CONTENTS, not the directory: `cp -r lib DIR` nests as DIR/lib on
	@# re-install (when DIR already exists), silently breaking every upgrade.
	@rm -rf ~/.local/lib/ocprobe && cp -r /tmp/ocprobe-$(VERSION)/lib ~/.local/lib/ocprobe
	@rm -rf ~/.local/share/ocprobe/config && cp -r /tmp/ocprobe-$(VERSION)/config ~/.local/share/ocprobe
	@cp /tmp/ocprobe-$(VERSION)/VERSION ~/.local/share/ocprobe/VERSION
	@echo "Installed. Ensure ~/.local/bin is in PATH"

uninstall:
	@rm -f ~/.local/bin/ocprobe
	@rm -rf ~/.local/lib/ocprobe
	@rm -rf ~/.local/share/ocprobe
	@echo "Uninstalled"

clean:
	@rm -rf dist/
	@rm -rf /tmp/ocprobe-*
	@rm -rf /tmp/ocm-*
	@rm -rf /tmp/ocm-mock-*
	@rm -rf /tmp/ocm-test-*
	@echo "Cleaned"

# Development helpers
dev-install: build install

dev-test: lint test

# Release helper (run after tagging)
release-check:
	@if [ -z "$$(git tag -l v$(VERSION))" ]; then echo "Tag v$(VERSION) not found"; exit 1; fi
	@echo "Tag v$(VERSION) exists, ready for release"

# Check version consistency (README badge must match VERSION file)
version-check:
	@BADGE_VERSION=$$(grep -o 'version-[0-9.]\+-blue' README.md | sed 's/version-\(.*\)-blue/\1/'); \
	if [[ "$(VERSION)" != "$$BADGE_VERSION" ]]; then \
		echo "README badge version ($$BADGE_VERSION) != VERSION ($(VERSION))"; exit 1; \
	fi; \
	echo "README badge version ($$BADGE_VERSION) matches VERSION ($(VERSION))"

drift-check: version-check
	@echo "=== drift-check ==="
	@echo "VERSION: $(VERSION)"
	@if git rev-parse --git-dir >/dev/null 2>&1; then \
	  if git tag -l "v$(VERSION)" | grep -q "v$(VERSION)"; then echo "Local tag v$(VERSION): FOUND"; \
	  else echo "Local tag v$(VERSION): MISSING (ok if not released from this clone)"; fi; \
	else echo "Not a git checkout — skip tag check"; fi
	@if command -v ocprobe >/dev/null 2>&1; then \
	  echo "Installed: $$(ocprobe version 2>/dev/null || true)"; \
	  cnt=$$(type -a ocprobe 2>/dev/null | wc -l | tr -d ' '); \
	  if [ "$$cnt" -gt 1 ]; then echo "WARN: multiple ocprobe on PATH (shadow risk)"; type -a ocprobe; \
	  else echo "PATH: single ocprobe"; fi; \
	else echo "ocprobe not on PATH"; fi
	@echo "drift-check done"

# Development helpers
dev-install: build install

dev-test: lint test

# Release helper (run after tagging)
