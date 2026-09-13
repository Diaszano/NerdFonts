#!/usr/bin/env bash
# shellcheck shell=bash

###############################################################################
# Module:        scripts/lib/cli.sh
# Description:   CLI state handling, argument parsing, validation and usage.
#
# Contents:
#   - usage
#   - disable_colors
#   - normalize_font_list
#   - parse_args
#   - validate_arg_combination
#
# Notes:
#   - This module only defines functions; it performs no action when sourced.
#   - Option state defaults are declared in scripts/lib/constants.sh and are
#     overwritten here while parsing. User-facing output only happens after
#     parsing completes, so flag effects apply to every printed message.
###############################################################################

# Option state variables are assigned here and consumed by the other modules.
# shellcheck disable=SC2034

# -----------------------------------------------------------------------------
# Help text
# -----------------------------------------------------------------------------

# usage prints script usage information, supported options, the exit codes
# table and a few examples.
usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Install, inspect and uninstall Nerd Fonts through multiple backends
(Homebrew, system package managers or direct downloads).

Actions:
  (default)                Interactive fzf multi-select installation.
  --all                    Install all available Nerd Fonts (non-interactive).
  --fonts "FONT[,FONT]"    Install the named fonts (non-interactive). Spaces
                           after commas are tolerated; unknown names produce a
                           warning and are skipped. FONT values are canonical
                           ids (e.g., firacode, jetbrainsmono, hack).
  --list                   Print the available Nerd Fonts (one per line) and exit.
  --installed              Print the installed Nerd Fonts ids (one per line) and exit.
  --uninstall [all|LIST]   Uninstall fonts. Without a value, opens the fzf
                           selector over the installed fonts. With "all",
                           removes every installed Nerd Font. Otherwise LIST is
                           a comma-separated set of fonts to remove.

Options:
  --backend auto|brew|pacman|direct
                           Installation backend (default: auto). With "auto",
                           the first package manager that reports a non-empty
                           Nerd Fonts catalog wins, in this order:
                           brew -> pacman; when none qualifies, fonts come
                           straight from the official GitHub releases ("direct").
                           An explicit backend is always honored (even with an
                           empty catalog).
  --dry-run                Print what would be done without touching the system.
  --yes                    Reserved: accept future prompts (no effect yet).
  --quiet                  Suppress step/success/warning messages (errors are
                           still printed). Equivalent to QUIET=1.
  --no-color               Disable colored output. The NO_COLOR environment
                           variable is honored automatically as well.
  --version                Print version information and exit.
  -h, --help               Show this help message and exit.

Environment variables:
  GITHUB_TOKEN               GitHub API token (direct backend; avoids 403s).
  DIRECT_CACHE_TTL_HOURS     Manifest cache TTL in hours (default: 24).
  DIRECT_NO_CACHE=1          Bypass the direct-backend manifest cache.
  DIRECT_JOBS                Parallel downloads of the direct backend (default: 4).
  NF_DEBUG_BACKEND=1         Print backend resolution debug info to stderr.

Exit codes:
  0   Success.
  1   Invalid argument, usage or validation error.
  2   Missing dependency (e.g., brew/fzf/curl/tar missing, manifest fetch failed).
  3   No Nerd Fonts found or available for the requested operation.
  4   Partial failure: some fonts failed to install or uninstall.

Examples:
  $(basename "$0")                                     # Interactive selection
  $(basename "$0") --all                               # Install all fonts
  $(basename "$0") --fonts "firacode"                  # Install named fonts
  $(basename "$0") --fonts "firacode, hack" --dry-run
  $(basename "$0") --backend pacman --list             # Arch Linux catalog
  $(basename "$0") --installed                         # Show installed fonts
  $(basename "$0") --uninstall all                     # Remove every Nerd Font

EOF
}

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------

# disable_colors turns off colored output by emptying the color variables.
disable_colors() {
  OPT_NO_COLOR=1
  COLOR_RED=""
  COLOR_GREEN=""
  COLOR_YELLOW=""
  COLOR_CYAN=""
  COLOR_RESET=""
}

# normalize_font_list converts a comma-separated font list into a trimmed,
# newline-separated list with empty entries removed ("a, b ,c" -> "a\nb\nc").
#
# Arguments:
#   $1 - Raw comma-separated font list.
#
# Output:
#   Prints the normalized list (one font per line).
normalize_font_list() {
  printf '%s' "$1" | tr -d ' ' | tr ',' '\n' | grep -v '^$'
}

# -----------------------------------------------------------------------------
# Argument parsing
# -----------------------------------------------------------------------------

# parse_args populates the global OPT_* state from the CLI arguments.
# Value-taking options require an argument (--fonts alone is a usage error);
# values containing spaces are supported.
#
# Arguments:
#   $@ - Raw CLI arguments.
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
    --all)
      OPT_ALL=1
      shift
      ;;
    --fonts)
      if [[ $# -lt 2 ]]; then
        die 1 "Option --fonts requires a value (e.g., --fonts \"font-fira-code-nerd-font\")."
      fi
      if [[ -z "$2" ]]; then
        die 1 "Option --fonts requires a non-empty value."
      fi
      OPT_FONTS=$2
      shift 2
      ;;
    --list)
      OPT_LIST=1
      shift
      ;;
    --installed)
      OPT_INSTALLED=1
      shift
      ;;
    --uninstall)
      if [[ $# -ge 2 && "$2" != -* ]]; then
        OPT_UNINSTALL_MODE=$2
        shift 2
      else
        OPT_UNINSTALL_MODE="interactive"
        shift
      fi
      ;;
    --dry-run)
      OPT_DRY_RUN=1
      shift
      ;;
    --yes)
      OPT_YES=1
      shift
      ;;
    --quiet)
      OPT_QUIET=1
      shift
      ;;
    --no-color)
      disable_colors
      shift
      ;;
    --backend)
      if [[ $# -lt 2 ]]; then
        die 1 "Option --backend requires a value. Valid backends: auto, brew, pacman, direct."
      fi
      case "$2" in
      auto | brew | pacman | direct)
        OPT_BACKEND=$2
        ;;
      *)
        die 1 "Invalid backend '${2}'. Valid backends: auto, brew, pacman, direct."
        ;;
      esac
      shift 2
      ;;
    --version)
      OPT_VERSION=1
      shift
      ;;
    -h | --help)
      OPT_HELP=1
      shift
      ;;
    *)
      die 1 "Unknown argument: $1"
      ;;
    esac
  done
}

# validate_arg_combination rejects mutually exclusive option combinations:
#   - --list / --installed cannot be combined with any other action.
#   - --all cannot be combined with --fonts.
#   - --uninstall cannot be combined with --all or --fonts.
validate_arg_combination() {
  local actions=0
  [[ "$OPT_ALL" == 1 ]] && actions=$((actions + 1))
  [[ -n "$OPT_FONTS" ]] && actions=$((actions + 1))
  [[ "$OPT_LIST" == 1 ]] && actions=$((actions + 1))
  [[ "$OPT_INSTALLED" == 1 ]] && actions=$((actions + 1))
  [[ -n "$OPT_UNINSTALL_MODE" ]] && actions=$((actions + 1))

  if ((actions > 1)); then
    die 1 "Apenas uma ação (--all, --fonts, --list, --installed, --uninstall) pode ser especificada."
  fi
}
