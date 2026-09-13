#!/usr/bin/env bash
# shellcheck shell=bash

###############################################################################
# Module:        scripts/lib/main.sh
# Description:   Entrypoint orchestration (action dispatch and workflow).
#
# Contents:
#   - cmd_list_fonts
#   - cmd_list_installed_fonts
#   - run_install
#   - run_uninstall
#   - main
#
# Notes:
#   - This module only defines functions; it performs no action when sourced.
#   - Relies on every other lib module, which must be sourced beforehand
#     (see scripts/install.sh for the sourcing order).
#   - The installation backend is resolved (resolve_backend) before every
#     action, including --list and --installed. Partial failures are tracked
#     through the FAILED_FONTS array filled by the backends and mapped to
#     exit code 4.
#   - Catalog/installed listings go through load_font_catalog /
#     load_installed_fonts and the CACHED_* globals: those loaders MUST run
#     in the current shell (they populate backend id maps), so they are never
#     wrapped in command substitutions.
###############################################################################

# Option state, helpers and domain functions come from the other lib modules.
# shellcheck disable=SC2154

# -----------------------------------------------------------------------------
# Actions
# -----------------------------------------------------------------------------

# cmd_list_fonts prints every available Nerd Font id, one per line (plain
# output, no banners/colors). Does not require fzf.
#
# Exit codes: 2 (backend failure), 3 (no fonts available).
cmd_list_fonts() {
  load_font_catalog

  if [[ -z "$CACHED_FONT_LIST" ]]; then
    if [[ "$RESOLVED_BACKEND" == "brew" ]]; then
      die 3 "No Nerd Fonts found. Please ensure Homebrew is up to date (brew update)."
    fi
    die 3 "No Nerd Fonts found for the '${RESOLVED_BACKEND}' backend."
  fi

  printf '%s\n' "$CACHED_FONT_LIST"
}

# cmd_list_installed_fonts prints every installed Nerd Font id, one per line
# (plain output, no colors).
#
# Exit codes: none beyond dependency handling (empty means none installed).
cmd_list_installed_fonts() {
  load_installed_fonts

  if [[ -z "$CACHED_INSTALLED_LIST" ]]; then
    print_warn "No Nerd Fonts are currently installed."
    return 0
  fi

  printf '%s\n' "$CACHED_INSTALLED_LIST"
}

# run_install executes the install workflow for the requested mode:
# named fonts (--fonts), everything (--all) or the interactive default.
run_install() {
  load_font_catalog

  if [[ -n "$OPT_FONTS" ]]; then
    local requested
    requested=$(normalize_font_list "$OPT_FONTS")
    if [[ -z "$requested" ]]; then
      die 1 "Option --fonts requires at least one font name."
    fi

    print_step "Fetching available Nerd Fonts..."

    if [[ -z "$CACHED_FONT_LIST" ]]; then
      if [[ "$RESOLVED_BACKEND" == "brew" ]]; then
        die 3 "No Nerd Fonts found. Please ensure Homebrew is up to date (brew update)."
      fi
      die 3 "No Nerd Fonts found for the '${RESOLVED_BACKEND}' backend."
    fi

    install_named_fonts "$requested" "$CACHED_FONT_LIST"
    if has_failed_fonts; then
      die 4 "Some fonts failed to install (${FAILED_FONTS[*]}). Please review the output above."
    fi
    return 0
  fi

  print_step "Fetching available Nerd Fonts..."

  if [[ -z "$CACHED_FONT_LIST" ]]; then
    if [[ "$RESOLVED_BACKEND" == "brew" ]]; then
      die 3 "No Nerd Fonts found. Please ensure Homebrew is up to date (brew update)."
    fi
    die 3 "No Nerd Fonts found for the '${RESOLVED_BACKEND}' backend."
  fi

  if [[ "$OPT_ALL" == 1 ]]; then
    print_step "Installing all available Nerd Fonts..."
    dispatch_install_fonts "$CACHED_FONT_LIST"
    if has_failed_fonts; then
      die 4 "Some fonts failed to install (${FAILED_FONTS[*]}). Please review the output above."
    fi
    return 0
  fi

  ensure_fzf_available

  print_step "Select the Nerd Fonts you want to install (TAB to select multiple, ENTER to confirm)."

  local selected_fonts
  selected_fonts=$(select_fonts "$CACHED_FONT_LIST")

  if [[ -z "$selected_fonts" ]]; then
    print_warn "No fonts selected. Exiting without changes."
    exit 0
  fi

  print_step "Installing selected Nerd Fonts..."
  dispatch_install_fonts "$selected_fonts"
  if has_failed_fonts; then
    die 4 "Some fonts failed to install (${FAILED_FONTS[*]}). Please review the output above."
  fi
}

# run_uninstall executes the uninstall workflow for the requested mode:
# interactive fzf selection (default), every installed font ("all") or the
# named fonts (comma-separated list).
run_uninstall() {
  load_installed_fonts

  if [[ "$OPT_UNINSTALL_MODE" == "interactive" ]]; then
    ensure_fzf_available

    if [[ -z "$CACHED_INSTALLED_LIST" ]]; then
      print_warn "No Nerd Fonts are currently installed. Nothing to uninstall."
      exit 0
    fi

    print_step "Select the Nerd Fonts you want to uninstall (TAB to select multiple, ENTER to confirm)."

    local selected
    selected=$(select_fonts "$CACHED_INSTALLED_LIST")

    if [[ -z "$selected" ]]; then
      print_warn "No fonts selected. Exiting without changes."
      exit 0
    fi

    dispatch_uninstall_fonts "$selected"
    if has_failed_fonts; then
      die 4 "Some fonts failed to uninstall (${FAILED_FONTS[*]}). Please review the output above."
    fi
    return 0
  fi

  if [[ "$OPT_UNINSTALL_MODE" == "all" ]]; then
    if [[ -z "$CACHED_INSTALLED_LIST" ]]; then
      print_warn "No Nerd Fonts are currently installed. Nothing to uninstall."
      exit 0
    fi

    print_step "Uninstalling all installed Nerd Fonts..."
    dispatch_uninstall_fonts "$CACHED_INSTALLED_LIST"
    if has_failed_fonts; then
      die 4 "Some fonts failed to uninstall (${FAILED_FONTS[*]}). Please review the output above."
    fi
    return 0
  fi

  local requested
  requested=$(normalize_font_list "$OPT_UNINSTALL_MODE")
  if [[ -z "$requested" ]]; then
    die 1 "Option --uninstall requires a value: all, a comma-separated font list, or nothing for interactive selection."
  fi

  uninstall_named_fonts "$requested" "$CACHED_INSTALLED_LIST"
  if has_failed_fonts; then
    die 4 "Some fonts failed to uninstall (${FAILED_FONTS[*]}). Please review the output above."
  fi
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------

# main is the entrypoint that orchestrates the installer workflow.
#
# Responsibilities:
#   - Parse and validate CLI arguments.
#   - Register INT/TERM signal handlers.
#   - Resolve the installation backend and validate its dependencies.
#   - Dispatch the requested action in order: version/help/list/installed,
#     uninstall, then install (named fonts, --all or interactive default).
main() {
  parse_args "$@"
  validate_arg_combination

  # Abort cleanly on interrupts, with conventional exit codes.
  trap 'printf "\n[abort] Interrupted.\n" >&2; exit 130' INT
  trap 'printf "\n[abort] Interrupted.\n" >&2; exit 143' TERM

  if [[ "$OPT_VERSION" == 1 ]]; then
    printf 'nerdfonts-installer %s\n' "$INSTALLER_VERSION"
    return 0
  fi

  if [[ "$OPT_HELP" == 1 ]]; then
    usage
    return 0
  fi

  # Backend resolution must happen before any action: --list/--installed also
  # read from the resolved backend's catalog/state.
  detect_os
  resolve_backend "$OPT_BACKEND"
  check_dependencies

  if [[ "$OPT_LIST" == 1 ]]; then
    cmd_list_fonts
    return 0
  fi

  if [[ "$OPT_INSTALLED" == 1 ]]; then
    cmd_list_installed_fonts
    return 0
  fi

  if [[ -n "$OPT_UNINSTALL_MODE" ]]; then
    run_uninstall
    return 0
  fi

  run_install
}
