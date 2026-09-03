# ============================================================================
# Makefile — Build, test, and release automation
# ============================================================================

VERSION := $(shell cat VERSION)
DIST_DIR := dist/ocprobe-$(VERSION)
PACKAGE := dist/ocprobe-$(VERSION).tar.gz

.PHONY: all lint test test-unit test-integration build package install uninstall clean help man

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

lint:
	@echo "Running shellcheck..."
	@shellcheck bin/ocprobe lib/*.sh
	@echo "Checking bash syntax..."
	@for f in bin/ocprobe lib/*.sh; do bash -n "$$f" || exit 1; done
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
	@cd dist && tar -c ocprobe-$(VERSION)/ | gzip -n > ocprobe-$(VERSION).tar.gz
	@cd dist && sha256sum ocprobe-$(VERSION).tar.gz > ocprobe-$(VERSION).tar.gz.sha256
	@echo "Package: $(PACKAGE)"

$(DIST_DIR):
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
	@mkdir -p ~/.local/bin ~/.local/lib ~/.local/share/ocprobe
	@tar -xzf $(PACKAGE) -C /tmp/
	@cp /tmp/ocprobe-$(VERSION)/bin/ocprobe ~/.local/bin/ocprobe
	@chmod +x ~/.local/bin/ocprobe
	@cp -r /tmp/ocprobe-$(VERSION)/lib ~/.local/lib/ocprobe
	@cp -r /tmp/ocprobe-$(VERSION)/config ~/.local/share/ocprobe
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