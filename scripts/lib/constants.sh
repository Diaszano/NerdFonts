#!/usr/bin/env bash
# shellcheck shell=bash

###############################################################################
# Module:        scripts/lib/constants.sh
# Description:   Shared constants used across the installer modules.
#
# Contents:
#   - Installer version (bundle-injected, "dev" fallback).
#   - Default CLI option state (OPT_*).
#   - Quiet/no-color environment handling (QUIET, NO_COLOR).
#   - ANSI color codes used by the logging helpers.
#   - fzf UI configuration (prompt, height, layout).
#   - Multi-backend state and direct-download configuration (GitHub repo,
#     cache dir/TTL/jobs, auto-detection order, resolution globals).
#
# Notes:
#   - This module only defines constants; it performs no action when sourced.
#   - Must be sourced before any module that relies on these values
#     (see scripts/install.sh for the sourcing order).
#
#   Constants below are consumed by other lib modules, never by this file.
###############################################################################

# shellcheck disable=SC2034

# -----------------------------------------------------------------------------
# Installer version
# -----------------------------------------------------------------------------
# Injected by scripts/build.sh when generating the single-file bundle; in
# development mode (scripts/install.sh) it falls back to "dev". The :- default
# also keeps this expansion safe under `set -u`.
INSTALLER_VERSION="${INSTALLER_VERSION:-dev}"

# -----------------------------------------------------------------------------
# CLI option state (defaults)
# -----------------------------------------------------------------------------
# Defaults live here (not only in cli.sh) so that logging helpers can safely
# reference them under `set -u` even before argument parsing runs. cli.sh
# overwrites them while parsing; user-facing output only happens afterwards.
OPT_ALL=0             # --all
OPT_FONTS=""          # --fonts (raw comma-separated value)
OPT_LIST=0            # --list
OPT_INSTALLED=0       # --installed
OPT_UNINSTALL_MODE="" # --uninstall: "", "interactive", "all" or a font list
OPT_DRY_RUN=0         # --dry-run
OPT_YES=0             # --yes (reserved for future prompts)
OPT_BACKEND="auto"    # --backend
OPT_VERSION=0         # --version
OPT_HELP=0            # -h/--help

# Quiet mode: enabled through --quiet or the QUIET=1 environment variable.
OPT_QUIET=0
if [[ "${QUIET:-}" == "1" ]]; then
  OPT_QUIET=1
fi

# -----------------------------------------------------------------------------
# Colors
# -----------------------------------------------------------------------------
# Disabled through --no-color or the industry-standard NO_COLOR environment
# variable. cli.sh::disable_colors reapplies this after flag parsing.
OPT_NO_COLOR=0
if [[ -n "${NO_COLOR:-}" ]]; then
  OPT_NO_COLOR=1
fi

if [[ "$OPT_NO_COLOR" == 1 ]]; then
  COLOR_RED=''
  COLOR_GREEN=''
  COLOR_YELLOW=''
  COLOR_CYAN=''
  COLOR_RESET=''
else
  COLOR_RED='\033[0;31m'
  COLOR_GREEN='\033[0;32m'
  COLOR_YELLOW='\033[0;33m'
  COLOR_CYAN='\033[0;36m'
  COLOR_RESET='\033[0m'
fi

# -----------------------------------------------------------------------------
# fzf UI configuration
# -----------------------------------------------------------------------------
FZF_PROMPT="Select Nerd Fonts: "
FZF_HEIGHT="60%"
FZF_LAYOUT="reverse"

# -----------------------------------------------------------------------------
# Multi-backend state and direct-download configuration
# -----------------------------------------------------------------------------
GITHUB_REPO="ryanoasis/nerd-fonts"
GITHUB_RELEASE_API="https://api.github.com/repos/${GITHUB_REPO}/releases/latest"

# Cache root for the direct backend (manifest cache + install markers).
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/nerdfonts-installer"

# Manifest cache TTL in hours (override with DIRECT_CACHE_TTL_HOURS).
DIRECT_CACHE_TTL_HOURS="${DIRECT_CACHE_TTL_HOURS:-24}"

# Set to 1 to bypass the direct-backend manifest cache.
DIRECT_NO_CACHE="${DIRECT_NO_CACHE:-0}"

# Parallel downloads used by the direct backend (override with DIRECT_JOBS).
DIRECT_JOBS="${DIRECT_JOBS:-4}"

# Candidate order for --backend auto (first available package manager with a
# non-empty Nerd Fonts catalog wins; direct is the final fallback).
BACKEND_AUTO_ORDER=(brew pacman direct)

# Resolved backend ("auto" resolution output; see platform.sh).
RESOLVED_BACKEND=""

# OS reported by detect_os ("macos", "linux" or "unknown").
DETECTED_OS=""

# Catalog cache filled during backend probing/fetching, tagged with its
# backend so stale entries from other backends are never reused.
CACHED_FONT_LIST=""
CACHED_FONT_LIST_BACKEND=""

# "1" once the catalog was loaded by load_font_catalog in the current shell
# (backend maps populated); probes only fill the cached text, not the maps.
CATALOG_SHELL_LOADED=""

# Installed-ids cache filled by load_installed_fonts (same shell guarantees
# as CACHED_FONT_LIST; tagged implicitly by INSTALLED_SHELL_LOADED).
CACHED_INSTALLED_LIST=""
INSTALLED_SHELL_LOADED=""

# Canonical ids that failed during the last dispatched operation. Reset per
# operation by the fonts.sh dispatchers; length > 0 maps to exit code 4.
FAILED_FONTS=()
