#!/usr/bin/env bash
# shellcheck shell=bash

# Globals set here (maps, resolution state) are consumed across modules.
# shellcheck disable=SC2034

###############################################################################
# Module:        scripts/lib/platform.sh
# Description:   OS detection and installation backend resolution.
#
# Contents:
#   - detect_os
#   - backend_debug
#   - probe_backend_catalog
#   - resolve_backend
#
# Notes:
#   - This module only defines functions; it performs no action when sourced.
#   - Backend candidate order for auto detection:
#       brew -> pacman -> direct
#   - The first available candidate whose font catalog is non-empty wins; if
#     none qualifies, the "direct" backend (official GitHub releases) is used.
#   - The catalog probed during resolution is cached in CACHED_FONT_LIST (and
#     tagged with CACHED_FONT_LIST_BACKEND) so later fetches do not re-query
#     the package manager.
###############################################################################

# -----------------------------------------------------------------------------
# OS / debug helpers
# -----------------------------------------------------------------------------

# detect_os fills the DETECTED_OS global with "macos", "linux" or "unknown"
# based on uname.
detect_os() {
  local uname_out
  uname_out=$(uname -s)
  case "$uname_out" in
  Darwin) DETECTED_OS="macos" ;;
  Linux) DETECTED_OS="linux" ;;
  *) DETECTED_OS="unknown" ;;
  esac
}

# backend_debug prints a debug line to stderr when NF_DEBUG_BACKEND=1.
#
# Arguments:
#   $1 - Message (e.g., "backend=pacman").
backend_debug() {
  if [[ "${NF_DEBUG_BACKEND:-}" == "1" ]]; then
    printf '[debug] %s\n' "$1" >&2
  fi
}

# -----------------------------------------------------------------------------
# Backend resolution
# -----------------------------------------------------------------------------

# probe_backend_catalog runs "<name>_list_fonts" tolerating any failure (the
# subshell may die on broken taps, missing binaries, network errors, ...).
# Successful probes (even when legitimately empty) are cached into
# CACHED_FONT_LIST and reported through PROBE_RESULT; failed probes leave the
# cache untagged so a later fetch can surface the underlying error.
#
# Arguments:
#   $1 - Backend name.
probe_backend_catalog() {
  local name=$1
  local list=""

  if list=$("${name}_list_fonts"); then
    PROBE_RESULT="$list"
    CACHED_FONT_LIST="$list"
    CACHED_FONT_LIST_BACKEND="$name"
  else
    PROBE_RESULT=""
    CACHED_FONT_LIST=""
    CACHED_FONT_LIST_BACKEND=""
  fi
}

# resolve_backend selects the effective installation backend based on the
# --backend option value and populates RESOLVED_BACKEND.
#
# Arguments:
#   $1 - Requested backend ("auto" or one of the concrete backend names).
#
# Behavior:
#   - Explicit request: always honored, even when the backing tool is absent
#     or its catalog is empty (a warning explains the situation).
#   - auto: first candidate (brew -> pacman) that is
#     installed AND reports a non-empty Nerd Fonts catalog. Falls back to
#     "direct" when no package manager qualifies; dies with exit code 2 when
#     direct is also unusable (no curl/wget + tar).
resolve_backend() {
  local requested=${1:-auto}

  detect_os

  if [[ "$requested" != "auto" ]]; then
    RESOLVED_BACKEND="$requested"

    if [[ "$requested" != "direct" ]] && ! "${requested}_is_available"; then
      print_warn "Backend '${requested}' is not available on this system. Using it anyway: its catalog will likely be empty."
    elif [[ "$requested" != "direct" ]]; then
      probe_backend_catalog "$requested"
      if [[ -z "$PROBE_RESULT" ]]; then
        print_warn "Backend '${requested}' reported no Nerd Fonts packages. Proceeding with an empty catalog."
      fi
    fi

    backend_debug "backend=${RESOLVED_BACKEND}"
    return 0
  fi

  # Auto detection: first available package manager with a non-empty catalog.
  local candidate
  for candidate in "${BACKEND_AUTO_ORDER[@]}"; do
    "${candidate}_is_available" || continue
    backend_debug "probing candidate=${candidate}"
    probe_backend_catalog "$candidate"
    if [[ -n "$PROBE_RESULT" ]]; then
      RESOLVED_BACKEND="$candidate"
      backend_debug "backend=${RESOLVED_BACKEND}"
      return 0
    fi
  done

  # No package manager had fonts: fall back to the official release downloads.
  if direct_is_available; then
    RESOLVED_BACKEND="direct"
    # Leave the catalog cache untagged: the direct manifest is loaded lazily
    # by its own backend functions (and may require network access).
    CACHED_FONT_LIST=""
    CACHED_FONT_LIST_BACKEND=""
    backend_debug "backend=${RESOLVED_BACKEND}"
    return 0
  fi

  die 2 "No supported installation backend found. Install one of: brew, pacman; or provide curl (or wget) plus tar for direct downloads."
}
