#!/usr/bin/env bash
# shellcheck shell=bash

###############################################################################
# Module:        scripts/lib/deps.sh
# Description:   Backend-aware dependency management (brew, fzf, direct).
#
# Contents:
#   - ensure_brew_available
#   - ensure_fzf_available
#   - ensure_direct_available
#   - check_dependencies
#
# Notes:
#   - This module only defines functions; it performs no action when sourced.
#   - Dependency checks depend on RESOLVED_BACKEND:
#       brew   -> the brew binary must exist.
#       direct -> curl (or wget) plus tar must exist.
#       pacman -> nothing extra (the manager binary was
#         already validated during backend resolution).
#   - fzf is only required by interactive flows and is validated at those
#     call sites via ensure_fzf_available.
###############################################################################

# -----------------------------------------------------------------------------
# Dependency management
# -----------------------------------------------------------------------------

# ensure_brew_available verifies that Homebrew is installed and reachable.
#
# Fails fast with an actionable message when Homebrew is not present.
# Exit code: 2 (missing dependency).
ensure_brew_available() {
  if ! is_command_installed "brew"; then
    die 2 "Homebrew is not installed. Please install it first: https://brew.sh"
  fi
}

# ensure_fzf_available ensures that fzf is installed for interactive
# selection. When missing, it is installed automatically only through the
# brew backend; other backends get an actionable manual-install hint.
#
# Exit code: 2 (fzf unavailable and not auto-installable).
ensure_fzf_available() {
  if is_command_installed "fzf"; then
    return 0
  fi

  if [[ "$RESOLVED_BACKEND" == "brew" ]]; then
    print_warn "fzf is not installed. Attempting to install it with Homebrew..."
    if brew install fzf; then
      print_success "fzf successfully installed."
      return 0
    fi
    die 2 "Failed to install fzf. Please install it manually and re-run this script."
  fi

  die 2 "fzf is required for interactive selection but is not installed. Please install fzf manually (e.g., with your system package manager) or use --all/--fonts/--uninstall all."
}

# ensure_direct_available verifies that the direct backend can operate:
# curl or wget for downloads plus tar (with xz support) for extraction.
#
# Exit code: 2 (missing dependency).
ensure_direct_available() {
  if ! direct_is_available; then
    die 2 "The direct backend requires curl (or wget) and tar. Please install them first, or pick another --backend."
  fi
}

# check_dependencies validates the dependencies of the resolved backend
# before proceeding with the main workflow. Idempotent; does NOT cover fzf
# (interactive-only; see ensure_fzf_available).
check_dependencies() {
  case "$RESOLVED_BACKEND" in
  brew)
    ensure_brew_available
    ;;
  direct)
    ensure_direct_available
    ;;
  *)
    # Package manager backends were already validated during resolution.
    ;;
  esac
}
