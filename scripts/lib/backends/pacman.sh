#!/usr/bin/env bash
# shellcheck shell=bash

# Globals set here (maps, resolution state) are consumed across modules.
# shellcheck disable=SC2034

###############################################################################
# Module:        scripts/lib/backends/pacman.sh
# Description:   Arch Linux backend (pacman).
#
# Contract (see scripts/lib/platform.sh and fonts.sh dispatchers):
#   - pacman_is_available            -> 0 when the pacman binary exists.
#   - pacman_list_fonts              -> canonical ids on stdout.
#   - pacman_is_font_installed <id>  -> 0/1.
#   - pacman_install_fonts <id>...   -> single batched invocation; failures
#                                       are appended to FAILED_FONTS; ret 0.
#   - pacman_uninstall_fonts <id>... -> idem.
#   - pacman_list_installed_fonts    -> ids of installed Nerd Font packages.
#
# Catalog discovery:
#   "pacman -Sgq nerd-fonts" (group members) with a fallback to
#   "pacman -Ssq nerd" when the group is unknown/empty.
#
# Canonical id derivation from a package name:
#   strip "ttf-" prefix, strip trailing "-nerd", drop remaining hyphens
#   (ttf-jetbrains-mono-nerd -> jetbrainsmono).
###############################################################################

pacman_is_available() {
  command -v pacman >/dev/null 2>&1
}

# -----------------------------------------------------------------------------
# Id <-> native resource mapping
# -----------------------------------------------------------------------------

# pacman_normalize_pkg converts a pacman package name into its canonical id.
#
# Arguments:
#   $1 - Package name (e.g., ttf-jetbrains-mono-nerd).
#
# Output:
#   The canonical id or an empty string when the name does not look like a
#   Nerd Fonts package.
pacman_normalize_pkg() {
  local id=$1
  case $id in
  *nerd*) ;;
  *) return 0 ;;
  esac

  id="${id#ttf-}"
  id="${id%-nerd-font}"
  id="${id%-nerd}"
  id="${id//-/}"
  printf '%s' "$id"
}

# pacman_id_to_pkg maps a canonical id back to its package name, preferring
# the catalog map and falling back to the conventional naming scheme.
#
# Arguments:
#   $1 - Canonical font id.
#
# Output:
#   The pacman package name.
pacman_id_to_pkg() {
  local id=$1
  local pkg=""
  pkg=$(map_get PACMAN_FONT_MAP "$id") || pkg="ttf-${id}-nerd"
  printf '%s' "$pkg"
}

# -----------------------------------------------------------------------------
# Catalog
# -----------------------------------------------------------------------------

# pacman_list_fonts prints every available Nerd Fonts package as canonical
# ids, one per line, filling PACMAN_FONT_MAP. Empty output is valid.
pacman_list_fonts() {
  local pkgs
  pkgs=$(pacman -Sgq nerd-fonts 2>/dev/null) || pkgs=""
  if [[ -z "$pkgs" ]]; then
    pkgs=$(pacman -Ssq nerd 2>/dev/null) || pkgs=""
  fi

  PACMAN_FONT_MAP=""

  local pkg
  local id
  while IFS= read -r pkg; do
    [[ -z "$pkg" ]] && continue
    id=$(pacman_normalize_pkg "$pkg")
    [[ -z "$id" ]] && continue
    map_has PACMAN_FONT_MAP "$id" && continue
    map_set PACMAN_FONT_MAP "$id" "$pkg"
    printf '%s\n' "$id"
  done <<<"$pkgs"
}

# pacman_list_installed_fonts prints the canonical ids of every installed
# Nerd Font package (one per line), filling PACMAN_FONT_MAP as well.
pacman_list_installed_fonts() {
  local installed
  installed=$(pacman -Qq 2>/dev/null | grep 'nerd' || true)
  [[ -z "$installed" ]] && return 0

  local pkg
  local id
  while IFS= read -r pkg; do
    [[ -z "$pkg" ]] && continue
    id=$(pacman_normalize_pkg "$pkg")
    [[ -z "$id" ]] && continue
    if ! map_has PACMAN_FONT_MAP "$id"; then
      map_set PACMAN_FONT_MAP "$id" "$pkg"
    fi
    printf '%s\n' "$id"
  done <<<"$installed"
}

# -----------------------------------------------------------------------------
# Installation state / batch operations
# -----------------------------------------------------------------------------

pacman_is_font_installed() {
  local pkg
  pkg=$(pacman_id_to_pkg "$1")
  pacman -Qi "$pkg" >/dev/null 2>&1
}

pacman_dry_run_install() {
  echo "[dry-run] Would install $(pacman_id_to_pkg "$1")."
}

pacman_dry_run_uninstall() {
  echo "[dry-run] Would uninstall $(pacman_id_to_pkg "$1")."
}

# pacman_install_fonts installs every given id with a single "pacman -S"
# invocation, retrying individually on batch failure.
#
# Arguments:
#   $@ - Canonical font ids.
pacman_install_fonts() {
  local ids=("$@")
  local pkgs=()
  local id
  local pkg

  for id in "${ids[@]}"; do
    pkgs+=("$(pacman_id_to_pkg "$id")")
  done

  echo "Installing ${pkgs[*]}..."
  if nf_run_priv pacman -S --noconfirm --needed "${pkgs[@]}"; then
    for pkg in "${pkgs[@]}"; do
      print_success "Successfully installed ${pkg}."
    done
    return 0
  fi

  for pkg in "${pkgs[@]}"; do
    echo "Installing ${pkg}..."
    if nf_run_priv pacman -S --noconfirm --needed "$pkg"; then
      print_success "Successfully installed ${pkg}."
    else
      print_warn "Failed to install ${pkg}."
      FAILED_FONTS+=("$(pacman_normalize_pkg "$pkg")")
    fi
  done
}

# pacman_uninstall_fonts removes every given id with a single "pacman -Rns"
# invocation, retrying individually on batch failure.
#
# Arguments:
#   $@ - Canonical font ids.
pacman_uninstall_fonts() {
  local ids=("$@")
  local pkgs=()
  local id
  local pkg

  for id in "${ids[@]}"; do
    pkgs+=("$(pacman_id_to_pkg "$id")")
  done

  echo "Uninstalling ${pkgs[*]}..."
  if nf_run_priv pacman -Rns --noconfirm "${pkgs[@]}"; then
    for pkg in "${pkgs[@]}"; do
      print_success "Successfully uninstalled ${pkg}."
    done
    return 0
  fi

  for pkg in "${pkgs[@]}"; do
    echo "Uninstalling ${pkg}..."
    if nf_run_priv pacman -Rns --noconfirm "$pkg"; then
      print_success "Successfully uninstalled ${pkg}."
    else
      print_warn "Failed to uninstall ${pkg}."
      FAILED_FONTS+=("$(pacman_normalize_pkg "$pkg")")
    fi
  done
}
