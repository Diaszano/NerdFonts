#!/usr/bin/env bash
# shellcheck shell=bash

###############################################################################
# Script:        scripts/install.sh
# Description:   Interactive installer for Nerd Fonts using Homebrew and fzf.
#
# Requirements:
#   - Bash (recommended: 4.x+)
#   - Homebrew (https://brew.sh)
#   - fzf (installed automatically via Homebrew if missing)
#
# Usage:
#   ./scripts/install.sh [OPTIONS]
#
# Options:
#   --all        Install all available Nerd Fonts without interactive selection.
#   -h, --help   Show this help message and exit.
#
# Default behavior:
#   - Discover available Nerd Fonts casks via Homebrew.
#   - Present the list in fzf for multi-selection (TAB to select, ENTER to confirm).
#   - Install all fonts selected in fzf using Homebrew casks.
#
# Exit codes:
#   0   Script completed successfully.
#   1   Validation, dependency or runtime error.
#
# Notes:
#   - Intended for macOS and Linux environments where Homebrew is available.
#   - This script only installs fonts; it does not change your terminal/editor
#     configuration to start using them.
###############################################################################

# Enable strict error handling:
# - -e: exit on any command failure
# - -u: treat unset variables as errors
# - -o pipefail: propagate failures in pipelines
set -euo pipefail
IFS=$'\n\t'

# -----------------------------------------------------------------------------
# Constants
# -----------------------------------------------------------------------------
FZF_PROMPT="Select Nerd Fonts: "
FZF_HEIGHT="60%"
FZF_LAYOUT="reverse"

# -----------------------------------------------------------------------------
# Colors
# -----------------------------------------------------------------------------
COLOR_RED='\033[0;31m'
COLOR_GREEN='\033[0;32m'
COLOR_YELLOW='\033[0;33m'
COLOR_CYAN='\033[0;36m'
COLOR_RESET='\033[0m'

# -----------------------------------------------------------------------------
# Logging & helpers
# -----------------------------------------------------------------------------

# usage prints script usage information and a short help message.
usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Options:
  --all        Install all available Nerd Fonts without interactive selection.
  -h, --help   Show this help message and exit.

Default behavior:
  - Fetch available Nerd Fonts casks via Homebrew.
  - Let you select fonts with fzf (TAB to multi-select, ENTER to confirm).
  - Install all selected fonts via Homebrew casks.

Examples:
  # Interactive selection
  $(basename "$0")

  # Install all available Nerd Fonts without prompts
  $(basename "$0") --all

EOF
}

# is_command_installed checks whether the given command exists in PATH.
#
# Arguments:
#   $1 - Command name to check.
#
# Returns:
#   0 if the command is found, non-zero otherwise.
is_command_installed() {
  command -v "$1" >/dev/null 2>&1
}

# print_step prints a highlighted informational step message.
#
# Usage:
#   print_step "Fetching fonts..."
print_step() {
  echo -e "\n${COLOR_CYAN}➜  $*${COLOR_RESET}\n"
}

# print_success prints a success message.
#
# Usage:
#   print_success "All fonts installed."
print_success() {
  echo -e "\n${COLOR_GREEN}✅  $*${COLOR_RESET}\n"
}

# print_warn prints a non-fatal warning message.
#
# Usage:
#   print_warn "fzf is not installed; installing now..."
print_warn() {
  echo -e "${COLOR_YELLOW}⚠️  $*${COLOR_RESET}"
}

# print_error prints an error message to stderr and exits with status 1.
#
# Usage:
#   print_error "Homebrew is not installed."
print_error() {
  echo -e "${COLOR_RED}❗  $*${COLOR_RESET}" >&2
  exit 1
}

# -----------------------------------------------------------------------------
# Dependency management
# -----------------------------------------------------------------------------

# ensure_brew_available verifies that Homebrew is installed and reachable.
#
# Fails fast with an actionable message when Homebrew is not present.
ensure_brew_available() {
  if ! is_command_installed "brew"; then
    print_error "Homebrew is not installed. Please install it first: https://brew.sh"
  fi
}

# ensure_fzf_available ensures that fzf is installed, installing it via Homebrew
# when it is not already available on the system.
ensure_fzf_available() {
  if is_command_installed "fzf"; then
    return 0
  fi

  print_warn "fzf is not installed. Attempting to install it with Homebrew..."
  if brew install fzf; then
    print_success "fzf successfully installed."
  else
    print_error "Failed to install fzf. Please install it manually and re-run this script."
  fi
}

# check_dependencies validates all required dependencies before proceeding with
# the main workflow. This function is idempotent and safe to call multiple times.
check_dependencies() {
  ensure_brew_available
  ensure_fzf_available
}

# -----------------------------------------------------------------------------
# Domain logic
# -----------------------------------------------------------------------------

# is_font_installed checks if a given font cask is already installed via Homebrew.
#
# Arguments:
#   $1 - Font cask name (e.g., font-jetbrains-mono-nerd-font).
#
# Returns:
#   0 if the cask is already installed, non-zero otherwise.
is_font_installed() {
  local font=$1

  if brew list --cask "$font" >/dev/null 2>&1; then
    return 0
  else
    return 1
  fi
}

# fetch_nerd_fonts retrieves the list of available Nerd Fonts casks via Homebrew.
#
# Output:
#   Prints one cask name per line to stdout.
#
# Notes:
#   - In case of a Homebrew tap inconsistency, a set of suggested recovery
#     commands is printed to help the user restore the taps.
fetch_nerd_fonts() {
  local search_output
  if ! search_output=$(brew search '/font-.*-nerd-font/' 2>/dev/null); then
    print_error "Failed to search Nerd Fonts via Homebrew.

Suggested manual recovery steps (use with caution):

  rm -rf \"\$(brew --repo homebrew/core)\"
  brew tap homebrew/core --force
  brew untap --force homebrew/cask || true
  brew tap homebrew/cask --force

After that, re-run this script."
  fi

  echo "$search_output" |
    awk '{ print $1 }'
}

# select_fonts opens an interactive fzf selector and returns the chosen fonts.
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

# install_single_font installs a single font cask via Homebrew.
#
# Arguments:
#   $1 - Font cask name.
#
# Behavior:
#   - Skips installation if the font is already installed.
#   - Logs success or failure for each font.
install_single_font() {
  local font=$1

  if is_font_installed "$font"; then
    print_warn "${font} is already installed. Skipping."
    return 0
  fi

  echo "Installing ${font}..."
  if brew install --cask "$font"; then
    print_success "Successfully installed ${font}."
  else
    print_warn "Failed to install ${font}."
  fi
}

# install_all_fonts installs all fonts provided in the input list without any
# interactive confirmation per font.
#
# Arguments:
#   $1 - List of fonts (one per line) to be installed.
install_all_fonts() {
  local fonts=$1

  print_step "Installing all available Nerd Fonts..."

  while IFS= read -r font; do
    [[ -z "$font" ]] && continue
    install_single_font "$font"
  done <<<"$fonts"
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

  while IFS= read -r font; do
    [[ -z "$font" ]] && continue
    install_single_font "$font"
  done <<<"$fonts"
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------

# main is the entrypoint that orchestrates the installation workflow.
#
# Responsibilities:
#   - Parse CLI arguments.
#   - Validate dependencies.
#   - Fetch available Nerd Fonts.
#   - Orchestrate interactive selection or bulk installation (--all).
main() {
  local install_all=false

  # Argument parsing
  while [[ $# -gt 0 ]]; do
    case "$1" in
    --all)
      install_all=true
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      print_error "Unknown argument: $1"
      ;;
    esac
  done

  check_dependencies

  print_step "Fetching available Nerd Fonts from Homebrew..."
  local fonts
  fonts=$(fetch_nerd_fonts)

  if [[ -z "$fonts" ]]; then
    print_error "No Nerd Fonts found. Please ensure Homebrew is up to date (brew update)."
  fi

  if [[ "$install_all" == true ]]; then
    install_all_fonts "$fonts"
    return 0
  fi

  print_step "Select the Nerd Fonts you want to install (TAB to select multiple, ENTER to confirm)."

  local selected_fonts
  selected_fonts=$(select_fonts "$fonts")

  if [[ -z "$selected_fonts" ]]; then
    print_warn "No fonts selected. Exiting without changes."
    exit 0
  fi

  print_step "Installing selected Nerd Fonts..."
  prompt_install_selected_fonts "$selected_fonts"
}

# -----------------------------------------------------------------------------
# Script execution
# -----------------------------------------------------------------------------
main "$@"
