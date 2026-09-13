#!/usr/bin/env bash
# shellcheck shell=bash

###############################################################################
# Module:        scripts/lib/util.sh
# Description:   Generic data-structure and backend-dispatch helpers.
#
# Contents:
#   - map_set / map_get / map_has        (bash 3.2 compatible "hash map")
#   - list_contains                      (newline-list membership test)
#   - to_lowercase                       (bash 3.2 safe ${var,,} replacement)
#   - backend_dry_run_install            (default per-backend dry-run hooks)
#   - backend_dry_run_uninstall
#
# Notes:
#   - This module only defines functions; it performs no action when sourced.
#   - The map implementation stores entries as a single string with one
#     "key|value" pair per line. Keys must not contain "|" or newlines
#     (font ids never do). Values may contain any character except newline.
#   - Maps are passed by variable NAME so callers keep plain string state:
#       MY_MAP=""
#       map_set MY_MAP "hack" "ttf-hack-nerd"
#       map_get MY_MAP "hack"   # -> ttf-hack-nerd
###############################################################################

# -----------------------------------------------------------------------------
# Newline-list helpers
# -----------------------------------------------------------------------------

# list_contains tests whether the newline-separated list in $2 contains the
# exact element $1.
#
# Arguments:
#   $1 - Element to look for.
#   $2 - Newline-separated list.
#
# Returns:
#   0 if present, 1 otherwise.
list_contains() {
  local needle=$1
  local haystack=$2

  printf '%s\n' "$haystack" | grep -Fxq -- "$needle"
}

# to_lowercase prints $1 converted to lowercase (bash 3.2 safe replacement
# for the "${var,,}" expansion).
#
# Arguments:
#   $1 - Input string.
#
# Output:
#   The lowercase string.
to_lowercase() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

# -----------------------------------------------------------------------------
# Privilege helper
# -----------------------------------------------------------------------------

# nf_run_priv runs the given command directly when already root (or when sudo
# is unavailable) and through sudo otherwise. Used by the system package
# manager backend (pacman).
#
# Arguments:
#   $@ - Command and its arguments.
nf_run_priv() {
  if [[ $EUID -eq 0 ]] || ! command -v sudo >/dev/null 2>&1; then
    "$@"
  else
    sudo "$@"
  fi
}

