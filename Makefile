# -----------------------------------------------------------------------------
# Makefile – Development Environment Orchestration
#
# Purpose:
#   Standardize the setup of the development environment, including:
#     - Homebrew installation (macOS and Linux)
#     - pre-commit installation and hook configuration
#     - Execution of the main install script
#
# Usage:
#   make dev-install   # Configure full development environment
#   make brew-install  # Ensure Homebrew is installed
#   make pre-commit    # Run pre-commit on all files
#   make run           # Execute scripts/install.sh
#   make help          # Show this help message
# -----------------------------------------------------------------------------

# Default goal when running `make` without arguments
.DEFAULT_GOAL := help

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------

# Path to the main install script
INSTALL_SCRIPT := scripts/install.sh

# Arguments to pass to the install script
RUN_ARGS ?= # e.g.: RUN_ARGS=--all


# -----------------------------------------------------------------------------
# Meta targets
# -----------------------------------------------------------------------------
.PHONY: help
help: ## Show available targets and their descriptions
	@echo "Available targets:"
	@grep -E '^[a-zA-Z_-]+:.*?## ' Makefile | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[1m%-20s\033[0m %s\n", $$1, $$2}'

.PHONY: dev-install
dev-install: pre-commit-install ## Configure the full development environment
	@echo "[dev-install] Development environment successfully configured."

# -----------------------------------------------------------------------------
# Homebrew
# -----------------------------------------------------------------------------
.PHONY: brew-install
brew-install: ## Ensure Homebrew is installed (macOS and Linux)
	@set -eu; \
	if command -v brew >/dev/null 2>&1; then \
		echo "[brew] Homebrew already installed."; \
	else \
		tmp_script=$$(mktemp); \
		trap 'rm -f "$$tmp_script"' EXIT; \
		curl -fSL -o "$$tmp_script" https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh; \
		/bin/bash "$$tmp_script"; \
		brew_path=""; \
		for candidate in /opt/homebrew/bin/brew /usr/local/bin/brew /home/linuxbrew/.linuxbrew/bin/brew; do \
			if [ -x "$$candidate" ]; then brew_path=$$candidate; break; fi; \
		done; \
		[ -n "$$brew_path" ] || { echo "Homebrew installation did not produce a usable brew executable." >&2; exit 1; }; \
		"$$brew_path" --version; \
		echo "[brew] Homebrew installed. Add its shellenv to your shell profile."; \
	fi

# -----------------------------------------------------------------------------
# pre-commit
# -----------------------------------------------------------------------------
.PHONY: pre-commit-install
pre-commit-install: brew-install ## Install pre-commit via Homebrew and configure git hooks
	@set -eu; \
	if ! command -v brew >/dev/null 2>&1; then \
		for candidate in /opt/homebrew/bin/brew /usr/local/bin/brew /home/linuxbrew/.linuxbrew/bin/brew; do \
			if [ -x "$$candidate" ]; then eval "$$($$candidate shellenv)"; break; fi; \
		done; \
	fi; \
	if ! command -v pre-commit >/dev/null 2>&1; then brew install pre-commit; fi; \
	pre-commit install; \
	pre-commit install --hook-type commit-msg; \
	echo "[pre-commit] Hooks installed successfully."

.PHONY: pre-commit
pre-commit: ## Run pre-commit hooks against all files in the repository
	@echo "[pre-commit] Running pre-commit on all files..."
	@pre-commit run --all-files

# -----------------------------------------------------------------------------
# Main install script
# -----------------------------------------------------------------------------
.PHONY: run
run: ## Execute the main install script (scripts/install.sh). Use RUN_ARGS=--all to install all fonts.
	@echo "[run] Executing $(INSTALL_SCRIPT) $(RUN_ARGS)..."
	@if [ -f "$(INSTALL_SCRIPT)" ]; then \
		bash "$(INSTALL_SCRIPT)" $(RUN_ARGS); \
	else \
		echo "[run] ERROR: $(INSTALL_SCRIPT) not found." >&2; \
		exit 1; \
	fi

.PHONY: run-all
run-all: ## Install all available Nerd Fonts without confirmation.
	RUN_ARGS=--all $(MAKE) run

.PHONY: test lint check
test: ## Run offline behavior tests
	bash tests/run.sh

lint: ## Check Bash syntax, ShellCheck and formatting
	bash -n scripts/install.sh
	shellcheck -x scripts/install.sh tests/*.sh
	shfmt -d -i 2 -ci scripts/install.sh tests/*.sh

check: test lint ## Run all offline project checks
