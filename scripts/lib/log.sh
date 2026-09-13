#!/usr/bin/env bash
# shellcheck shell=bash

###############################################################################
# Module:        scripts/lib/log.sh
# Description:   Logging helpers and small utility functions.
#
# Contents:
#   - is_command_installed
#   - print_step
#   - print_success
#   - print_warn
#   - die
#   - print_error
#
# Notes:
#   - This module only defines functions; it performs no action when sourced.
#   - Color codes and option flags are imported from scripts/lib/constants.sh,
#     which is always sourced before this module (see scripts/install.sh).
#   - print_step/print_success/print_warn honor OPT_QUIET (--quiet / QUIET=1);
#     errors are always printed.
###############################################################################

# shellcheck disable=SC2154

# print_step prints a highlighted informational step message.
#
# Usage:
#   print_step "Fetching fonts..."
print_step() {
  if [[ "$OPT_QUIET" == 1 ]]; then
    return 0
  fi
  echo -e "\n${COLOR_CYAN}➜  $*${COLOR_RESET}\n"
}

# print_success prints a success message.
#
# Usage:
#   print_success "All fonts installed."
print_success() {
  if [[ "$OPT_QUIET" == 1 ]]; then
    return 0
  fi
  echo -e "\n${COLOR_GREEN}✅  $*${COLOR_RESET}\n"
}

# print_warn prints a non-fatal warning message.
#
# Usage:
#   print_warn "fzf is not installed; installing now..."
print_warn() {
  if [[ "$OPT_QUIET" == 1 ]]; then
    return 0
  fi
  echo -e "${COLOR_YELLOW}⚠️  $*${COLOR_RESET}"
}

# die prints an error message to stderr and exits with the given status code.
#
# Arguments:
#   $1 - Exit code (see the exit codes table in cli.sh::usage).
#   $2 - Error message.
#
# Usage:
#   die 2 "Homebrew is not installed."
die() {
  local code=$1
  shift
  echo -e "${COLOR_RED}❗  $*${COLOR_RESET}" >&2
  exit "$code"
}
