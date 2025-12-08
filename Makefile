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

# Path to the main install script
INSTALL_SCRIPT := scripts/install.sh

# -----------------------------------------------------------------------------
# Meta targets
# -----------------------------------------------------------------------------
.PHONY: help
help: ## Show available targets and their descriptions
	@echo "Available targets:"
	@grep -E '^[a-zA-Z_-]+:.*?## ' Makefile | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[1m%-20s\033[0m %s\n", $$1, $$2}'

.PHONY: dev-install
dev-install: brew-install pre-commit-install ## Configure the full development environment
	@echo "[dev-install] Development environment successfully configured."

# -----------------------------------------------------------------------------
# Homebrew
# -----------------------------------------------------------------------------
.PHONY: brew-install
brew-install: ## Ensure Homebrew is installed (macOS and Linux)
	@echo "[brew] Checking Homebrew installation..."
	@if command -v brew >/dev/null 2>&1; then \
		echo "[brew] Homebrew already installed. Skipping."; \
	else \
		echo "[brew] Homebrew not found. Installing..."; \
		/bin/bash -c "$$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"; \
		echo "[brew] Homebrew installation script executed."; \
		echo "[brew] If brew is not available, please ensure your shell PATH includes the Homebrew bin directory."; \
	fi

# -----------------------------------------------------------------------------
# pre-commit
# -----------------------------------------------------------------------------
.PHONY: pre-commit-install
pre-commit-install: ## Install pre-commit via Homebrew and configure git hooks
	@echo "[pre-commit] Ensuring pre-commit is installed..."
	@if command -v pre-commit >/dev/null 2>&1; then \
		echo "[pre-commit] pre-commit already installed. Skipping brew install."; \
	else \
		echo "[pre-commit] pre-commit not found. Installing via Homebrew..."; \
		brew install pre-commit; \
	fi
	@echo "[pre-commit] Installing git hooks..."
	@pre-commit install
	@pre-commit install --hook-type commit-msg
	@echo "[pre-commit] pre-commit hooks installed successfully."

.PHONY: pre-commit
pre-commit: ## Run pre-commit hooks against all files in the repository
	@echo "[pre-commit] Running pre-commit on all files..."
	@pre-commit run --all-files

# -----------------------------------------------------------------------------
# Main install script
# -----------------------------------------------------------------------------
.PHONY: run
run: ## Execute the main install script (scripts/install.sh)
	@echo "[run] Executing $(INSTALL_SCRIPT)..."
	@if [ -f "$(INSTALL_SCRIPT)" ]; then \
		if [ -x "$(INSTALL_SCRIPT)" ]; then \
			"$(INSTALL_SCRIPT)"; \
		else \
			sh "$(INSTALL_SCRIPT)"; \
		fi; \
	else \
		echo "[run] ERROR: $(INSTALL_SCRIPT) not found." >&2; \
		exit 1; \
	fi
