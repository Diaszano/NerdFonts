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
# Key/value maps (bash 3.2 compatible)
# -----------------------------------------------------------------------------

# map_set inserts or updates the entry "key|value" in the map stored in the
# variable named by $1.
#
# Arguments:
#   $1 - Name of the variable holding the map.
#   $2 - Key (must not contain "|" or newlines).
#   $3 - Value (must not contain newlines).
map_set() {
  local map_name=$1
  local key=$2
  local value=$3
  local data="${!map_name:-}"
  local out=""
  local entry
  local id
  local found=0

  while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue
    id="${entry%%|*}"
    if [[ "$id" == "$key" ]]; then
      out+="${out:+$'\n'}${key}|${value}"
      found=1
    else
      out+="${out:+$'\n'}${entry}"
    fi
  done <<<"$data"

  if [[ "$found" == 0 ]]; then
    out+="${out:+$'\n'}${key}|${value}"
  fi

  printf -v "$map_name" '%s' "$out"
}

# map_get prints the value associated with $2 in the map stored in the
# variable named by $1.
#
# Arguments:
#   $1 - Name of the variable holding the map.
#   $2 - Key to look up.
#
# Output:
#   The value, when found.
#
# Returns:
#   0 if the key exists, 1 otherwise.
map_get() {
  local map_name=$1
  local key=$2
  local data="${!map_name:-}"
  local entry
  local id

  while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue
    id="${entry%%|*}"
    if [[ "$id" == "$key" ]]; then
      printf '%s' "${entry#*|}"
      return 0
    fi
  done <<<"$data"

  return 1
}

# map_has tests whether $2 exists in the map stored in the variable named by
# $1, without printing anything.
#
# Arguments:
#   $1 - Name of the variable holding the map.
#   $2 - Key to look up.
#
# Returns:
#   0 if the key exists, 1 otherwise.
map_has() {
  map_get "$1" "$2" >/dev/null
}

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

# -----------------------------------------------------------------------------
# Backend dry-run hooks
# -----------------------------------------------------------------------------
# Backends may override these with "<name>_dry_run_install" /
# "<name>_dry_run_uninstall" to print backend-specific action lines
# (e.g., brew prints native cask names). These defaults are used when no
# override exists.

# backend_dry_run_install default dry-run line for installing font id $1.
backend_dry_run_install() {
  echo "[dry-run] Would install ${1}."
}

# backend_dry_run_uninstall default dry-run line for uninstalling font id $1.
backend_dry_run_uninstall() {
  echo "[dry-run] Would uninstall ${1}."
}
