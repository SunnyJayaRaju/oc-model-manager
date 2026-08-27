# ============================================================================
# Makefile — Build, test, and release automation
# ============================================================================

VERSION := $(shell cat VERSION)
DIST_DIR := dist/ocm-$(VERSION)
PACKAGE := dist/ocm-$(VERSION).tar.gz

.PHONY: all lint test test-unit test-integration build package install uninstall clean help

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
	@echo "  make release        - Create GitHub release (requires tag)"

lint:
	@echo "Running shellcheck..."
	@shellcheck bin/ocm lib/*.sh
	@echo "Checking bash syntax..."
	@for f in bin/ocm lib/*.sh; do bash -n "$$f" || exit 1; done
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
	@cd dist && tar -c ocm-$(VERSION)/ | gzip -n > ocm-$(VERSION).tar.gz
	@cd dist && sha256sum ocm-$(VERSION).tar.gz > ocm-$(VERSION).tar.gz.sha256
	@echo "Package: $(PACKAGE)"

$(DIST_DIR):
	@mkdir -p $(DIST_DIR)
	@cp -r bin lib config VERSION CHANGELOG.md LICENSE README.md CONTRIBUTING.md docs $(DIST_DIR)/
	# Normalize timestamps for reproducible builds
	@find $(DIST_DIR) -exec touch -t 202401010000 {} +

install: $(PACKAGE)
	@echo "Installing to ~/.local/bin..."
	@mkdir -p ~/.local/bin
	@tar -xzf $(PACKAGE) -C /tmp/
	@cp /tmp/ocm-$(VERSION)/bin/ocm ~/.local/bin/ocm
	@chmod +x ~/.local/bin/ocm
	@echo "Installed. Ensure ~/.local/bin is in PATH"

uninstall:
	@rm -f ~/.local/bin/ocm
	@echo "Uninstalled"

clean:
	@rm -rf dist/
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

# Check version consistency
version-check:
	@grep -r "OCM_VERSION" bin/ lib/ | grep -v "$(VERSION)" && echo "Version mismatch!" && exit 1 || echo "Version consistent"