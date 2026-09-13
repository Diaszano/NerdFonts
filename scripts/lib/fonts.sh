#!/usr/bin/env bash
# shellcheck shell=bash

###############################################################################
# Module:        scripts/lib/fonts.sh
# Description:   Font discovery, selection and install/uninstall dispatch.
#
# Contents:
#   - is_font_installed
#   - fetch_nerd_fonts
#   - select_fonts
#   - dispatch_install_fonts
#   - dispatch_uninstall_fonts
#   - install_all_fonts
#   - prompt_install_selected_fonts
#   - install_named_fonts
#   - list_installed_fonts
#   - uninstall_named_fonts
#   - uninstall_all_fonts
#
# Notes:
#   - This module only defines functions; it performs no action when sourced.
#   - Every backend-specific operation is dispatched through the resolved
#     backend's "<name>_*" contract functions (see scripts/lib/backends/).
#   - The dispatchers collect pending fonts first (filtering out fonts that
#     are already installed / not installed, with a skip warning) and then
#     invoke "<backend>_install_fonts" / "<backend>_uninstall_fonts" ONCE,
#     so package managers run a single batched transaction.
#   - FAILED_FONTS (indexed array) is reset by each dispatcher and filled by
#     the backends; callers decide the final exit code (4 = partial failure).
###############################################################################

# Logging helpers, fzf constants and CLI option flags are imported from
# scripts/lib/{constants,log}.sh, which are always sourced before this module.

# shellcheck disable=SC2154

# -----------------------------------------------------------------------------
# Domain logic
# -----------------------------------------------------------------------------

# is_font_installed checks whether a font id is already installed through the
# resolved backend.
#
# Arguments:
#   $1 - Canonical font id (e.g., jetbrainsmono).
#
# Returns:
#   0 if installed, non-zero otherwise.
is_font_installed() {
  "${RESOLVED_BACKEND}_is_font_installed" "$1"
}

# load_font_catalog ensures CACHED_FONT_LIST holds the resolved backend's
# catalog, running "<backend>_list_fonts" in the CURRENT shell when needed.
#
# Exit codes:
#   Propagates fatal backend errors (e.g., direct manifest failures -> 2).
#
# Notes:
#   - "<backend>_list_fonts" is executed in the CURRENT shell (stdout routed
#     through a temp file) so its side effects survive: the <NAME>_FONT_MAP
#     globals used for id <-> native-resource translation must stay available
#     to the dispatchers. Wrapping this call in a command substitution would
#     run it in a subshell and silently discard those maps.
#   - Callers must read "$CACHED_FONT_LIST" instead of capturing the output
#     of this function.
load_font_catalog() {
  if [[ "$CACHED_FONT_LIST_BACKEND" == "$RESOLVED_BACKEND" && -n "$CACHED_FONT_LIST" ]]; then
    return 0
  fi
  CACHED_FONT_LIST=$("${RESOLVED_BACKEND}_list_fonts")
  CACHED_FONT_LIST_BACKEND="$RESOLVED_BACKEND"
}

load_installed_fonts() {
  if [[ -n "$CACHED_INSTALLED_LIST" ]]; then
    return 0
  fi
  CACHED_INSTALLED_LIST=$("${RESOLVED_BACKEND}_list_installed_fonts")
}

# fetch_nerd_fonts prints the canonical ids of every Nerd Font offered by the
# resolved backend (kept for compatibility; new code should call
# load_font_catalog and read "$CACHED_FONT_LIST").
#
# Output:
#   Prints one canonical font id per line to stdout.
fetch_nerd_fonts() {
  load_font_catalog

  if [[ -n "$CACHED_FONT_LIST" ]]; then
    printf '%s\n' "$CACHED_FONT_LIST"
  fi
  return 0
}

# list_installed_fonts prints the canonical ids of every Nerd Font currently
# installed through the resolved backend (one per line). Always succeeds;
# empty output means none installed.
#
# Output:
#   Prints one canonical font id per line to stdout.
list_installed_fonts() {
  load_installed_fonts

  if [[ -n "$CACHED_INSTALLED_LIST" ]]; then
    printf '%s\n' "$CACHED_INSTALLED_LIST"
  fi
  return 0
}

# select_fonts opens an interactive fzf selector and returns the chosen ids.
#
# Arguments:
#   $1 - List of fonts (one per line).
#
# Output:
#   Prints the selected fonts (one per line) to stdout.
select_fonts() {
  local fonts_list=$1

  echo "$fonts_list" | fzf \
    --multi \
    --prompt="$FZF_PROMPT" \
    --height="$FZF_HEIGHT" \
    --layout="$FZF_LAYOUT"
}

# -----------------------------------------------------------------------------
# Batch dispatchers (single backend invocation per operation)
# -----------------------------------------------------------------------------

# dispatch_install_fonts installs the given fonts through the resolved
# backend in one batched call.
#
# Arguments:
#   $1 - Fonts to install (newline-separated canonical ids).
#
# Behavior:
#   - Resets FAILED_FONTS for this operation.
#   - Dry-run mode delegates every id to "<backend>_dry_run_install".
#   - Otherwise filters out already-installed fonts (with a skip warning)
#     and invokes "<backend>_install_fonts" once with the pending ids.
dispatch_install_fonts() {
  local fonts=$1
  local id
  local pending=()

  FAILED_FONTS=()

  while IFS= read -r id; do
    [[ -z "$id" ]] && continue
    if [[ "$OPT_DRY_RUN" == 1 ]]; then
      "${RESOLVED_BACKEND}_dry_run_install" "$id"
    elif is_font_installed "$id"; then
      print_warn "${id} is already installed. Skipping."
    else
      pending+=("$id")
    fi
  done <<<"$fonts"

  [[ "$OPT_DRY_RUN" == 1 ]] && return 0
  [[ ${#pending[@]} -eq 0 ]] && return 0

  "${RESOLVED_BACKEND}_install_fonts" "${pending[@]}"
}

# dispatch_uninstall_fonts uninstalls the given fonts through the resolved
# backend in one batched call.
#
# Arguments:
#   $1 - Fonts to uninstall (newline-separated canonical ids).
#
# Behavior:
#   - Resets FAILED_FONTS for this operation.
#   - Dry-run mode delegates every id to "<backend>_dry_run_uninstall".
#   - Otherwise filters out fonts that are not installed (skip warning) and
#     invokes "<backend>_uninstall_fonts" once with the pending ids.
dispatch_uninstall_fonts() {
  local fonts=$1
  local id
  local pending=()

  FAILED_FONTS=()

  while IFS= read -r id; do
    [[ -z "$id" ]] && continue
    if [[ "$OPT_DRY_RUN" == 1 ]]; then
      "${RESOLVED_BACKEND}_dry_run_uninstall" "$id"
    elif ! is_font_installed "$id"; then
      print_warn "${id} is not installed. Skipping."
    else
      pending+=("$id")
    fi
  done <<<"$fonts"

  [[ "$OPT_DRY_RUN" == 1 ]] && return 0
  [[ ${#pending[@]} -eq 0 ]] && return 0

  "${RESOLVED_BACKEND}_uninstall_fonts" "${pending[@]}"
}

# has_failed_fonts reports whether the last dispatched operation recorded
# failures in FAILED_FONTS.
#
# Returns:
#   0 when at least one font failed, 1 otherwise.
has_failed_fonts() {
  [[ ${#FAILED_FONTS[@]} -gt 0 ]]
}

# -----------------------------------------------------------------------------
# Install workflows
# -----------------------------------------------------------------------------

# install_all_fonts installs all fonts provided in the input list without any
# interactive confirmation.
#
# Arguments:
#   $1 - List of fonts (one per line) to be installed.
install_all_fonts() {
  local fonts=$1

  print_step "Installing all available Nerd Fonts..."

  dispatch_install_fonts "$fonts"
}

# prompt_install_selected_fonts installs all fonts selected via fzf.
#
# Arguments:
#   $1 - List of selected fonts (one per line).
#
# Notes:
#   - Despite the name, this function does not prompt per font; it installs
#     all fonts passed as input. The only interactive step is the fzf selection.
prompt_install_selected_fonts() {
  local fonts=$1

  print_step "Installing selected Nerd Fonts..."

  dispatch_install_fonts "$fonts"
}

# install_named_fonts validates a requested font list against the available
# fonts and installs the matching ones. Unknown names log a warning and are
# skipped; if none of the names is valid, it fails with exit code 3.
#
# Arguments:
#   $1 - Requested fonts (normalized, one per line).
#   $2 - Available fonts (one per line).
install_named_fonts() {
  local requested=$1
  local available=$2
  local font
  local to_install=""

  while IFS= read -r font; do
    [[ -z "$font" ]] && continue
    if list_contains "$font" "$available"; then
      to_install+="${to_install:+$'\n'}${font}"
    else
      print_warn "Unknown font '${font}'. Skipping."
    fi
  done <<<"$requested"

  if [[ -z "$to_install" ]]; then
    die 3 "None of the requested fonts are available. Run with --list to see the valid names."
  fi

  dispatch_install_fonts "$to_install"
}

# -----------------------------------------------------------------------------
# Uninstall workflows
# -----------------------------------------------------------------------------

# uninstall_named_fonts validates a requested font list against the installed
# fonts and removes the matching ones. Names that are not installed log a
# warning and are skipped; if none of the names matches, it fails with exit 3.
#
# Arguments:
#   $1 - Requested fonts (normalized, one per line).
#   $2 - Installed fonts (one per line).
uninstall_named_fonts() {
  local requested=$1
  local installed=$2
  local font
  local to_uninstall=""

  while IFS= read -r font; do
    [[ -z "$font" ]] && continue
    if list_contains "$font" "$installed"; then
      to_uninstall+="${to_uninstall:+$'\n'}${font}"
    else
      print_warn "'${font}' is not installed. Skipping."
    fi
  done <<<"$requested"

  if [[ -z "$to_uninstall" ]]; then
    die 3 "None of the requested fonts are installed. Run with --installed to see what is present."
  fi

  dispatch_uninstall_fonts "$to_uninstall"
}

# uninstall_all_fonts removes every installed Nerd Font passed as input.
#
# Arguments:
#   $1 - Installed fonts (one per line).
uninstall_all_fonts() {
  local installed=$1

  print_step "Uninstalling all installed Nerd Fonts..."

  dispatch_uninstall_fonts "$installed"
}
