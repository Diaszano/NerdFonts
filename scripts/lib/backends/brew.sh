#!/usr/bin/env bash
# shellcheck shell=bash

# Globals set here (maps, resolution state) are consumed across modules.
# shellcheck disable=SC2034

###############################################################################
# Module:        scripts/lib/backends/brew.sh
# Description:   Homebrew backend (casks font-*-nerd-font).
#
# Contract (see scripts/lib/platform.sh and fonts.sh dispatchers):
#   - brew_is_available            -> 0 when the brew binary exists.
#   - brew_list_fonts              -> canonical ids on stdout.
#   - brew_is_font_installed <id>  -> 0/1.
#   - brew_install_fonts <id>...   -> single batched invocation; failures are
#                                     appended to FAILED_FONTS; returns 0.
#   - brew_uninstall_fonts <id>... -> idem.
#   - brew_list_installed_fonts    -> ids of installed Nerd Fonts casks.
#
# Canonical id derivation from a cask "font-X-nerd-font":
#   strip "font-" prefix, strip "-nerd-font" suffix, drop remaining hyphens
#   (font-jetbrains-mono-nerd-font -> jetbrainsmono).
#
# Notes:
#   - BREW_FONT_MAP (id -> cask) is filled by brew_list_fonts; reverse lookup
#     falls back to the conventional "font-<id>-nerd-font" name.
#   - A failed batch install is retried per-cask so individual culprits can be
#     reported precisely in FAILED_FONTS.
###############################################################################

# -----------------------------------------------------------------------------
# Availability
# -----------------------------------------------------------------------------

brew_is_available() {
  command -v brew >/dev/null 2>&1
}

# -----------------------------------------------------------------------------
# Id <-> native resource mapping
# -----------------------------------------------------------------------------

# brew_cask_to_id converts a Nerd Font cask name into its canonical id.
#
# Arguments:
#   $1 - Cask name (e.g., font-jetbrains-mono-nerd-font).
#
# Output:
#   The canonical id (e.g., jetbrainsmono).
brew_cask_to_id() {
  local id=$1
  id="${id#font-}"
  id="${id%-nerd-font}"
  id="${id//-/}"
  printf '%s' "$id"
}

# brew_id_to_cask maps a canonical id back to its cask name.
#
# Arguments:
#   $1 - Canonical font id.
#
# Output:
#   The Homebrew cask name.
brew_id_to_cask() {
  printf 'font-%s-nerd-font' "$1"
}

# -----------------------------------------------------------------------------
# Catalog
# -----------------------------------------------------------------------------

# brew_list_fonts prints every available Nerd Font cask as canonical ids,
# one per line.
#
# Exit codes:
#   2 - Homebrew search failed (e.g., tap inconsistency); a set of suggested
#       recovery commands is printed.
brew_list_fonts() {
  local search_output
  if ! search_output=$(brew search '/font-.*-nerd-font/' 2>/dev/null); then
    die 2 "Failed to search Nerd Fonts via Homebrew.

Suggested manual recovery steps (use with caution):

  rm -rf \"\$(brew --repo homebrew/core)\"
  brew tap homebrew/core --force
  brew untap --force homebrew/cask || true
  brew tap homebrew/cask --force

After that, re-run this script."
  fi

  local cask
  local id
  while IFS= read -r cask; do
    [[ -z "$cask" ]] && continue
    cask=$(printf '%s' "$cask" | awk '{ print $1 }')
    case $cask in
    font-*-nerd-font) ;;
    *) continue ;;
    esac

    id=$(brew_cask_to_id "$cask")
    [[ -z "$id" ]] && continue
    printf '%s\n' "$id"
  done <<<"$search_output"
}

# brew_list_installed_fonts prints the canonical ids of every installed Nerd
# Font cask (one per line).
brew_list_installed_fonts() {
  local installed
  installed=$(brew list --cask 2>/dev/null | grep 'nerd-font' || true)
  [[ -z "$installed" ]] && return 0

  local cask
  local id
  while IFS= read -r cask; do
    [[ -z "$cask" ]] && continue
    id=$(brew_cask_to_id "$cask")
    [[ -z "$id" ]] && continue
    printf '%s\n' "$id"
  done <<<"$installed"
}

# -----------------------------------------------------------------------------
# Installation state / batch operations
# -----------------------------------------------------------------------------

brew_is_font_installed() {
  local cask
  cask=$(brew_id_to_cask "$1")
  brew list --cask "$cask" >/dev/null 2>&1
}

# brew_dry_run_install dry-run line using the native cask name.
brew_dry_run_install() {
  echo "[dry-run] Would install $(brew_id_to_cask "$1")."
}

# brew_dry_run_uninstall dry-run line using the native cask name.
brew_dry_run_uninstall() {
  echo "[dry-run] Would uninstall $(brew_id_to_cask "$1")."
}

# brew_install_fonts installs every given id with a single "brew install
# --cask" invocation. On batch failure each cask is retried individually so
# only real offenders land in FAILED_FONTS.
#
# Arguments:
#   $@ - Canonical font ids.
brew_install_fonts() {
  local ids=("$@")
  local casks=()
  local id
  local cask

  for id in "${ids[@]}"; do
    casks+=("$(brew_id_to_cask "$id")")
  done

  echo "Installing ${casks[*]}..."
  if brew install --cask "${casks[@]}"; then
    for cask in "${casks[@]}"; do
      print_success "Successfully installed ${cask}."
    done
    return 0
  fi

  # Batch failed: retry one by one to pinpoint the failures.
  for cask in "${casks[@]}"; do
    echo "Installing ${cask}..."
    if brew install --cask "$cask"; then
      print_success "Successfully installed ${cask}."
    else
      print_warn "Failed to install ${cask}."
      FAILED_FONTS+=("$(brew_cask_to_id "$cask")")
    fi
  done
}

# brew_uninstall_fonts removes every given id with a single "brew uninstall
# --cask" invocation, retrying individually on batch failure.
#
# Arguments:
#   $@ - Canonical font ids.
brew_uninstall_fonts() {
  local ids=("$@")
  local casks=()
  local id
  local cask

  for id in "${ids[@]}"; do
    casks+=("$(brew_id_to_cask "$id")")
  done

  echo "Uninstalling ${casks[*]}..."
  if brew uninstall --cask "${casks[@]}"; then
    for cask in "${casks[@]}"; do
      print_success "Successfully uninstalled ${cask}."
    done
    return 0
  fi

  for cask in "${casks[@]}"; do
    echo "Uninstalling ${cask}..."
    if brew uninstall --cask "$cask"; then
      print_success "Successfully uninstalled ${cask}."
    else
      print_warn "Failed to uninstall ${cask}."
      FAILED_FONTS+=("$(brew_cask_to_id "$cask")")
    fi
  done
}
