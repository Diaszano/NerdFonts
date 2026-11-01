#!/usr/bin/env bash
# shellcheck shell=bash
set -euo pipefail

###############################################################################
# Script:        scripts/install.sh
# Description:   Self-contained installer for Nerd Fonts supporting Homebrew,
#                Pacman, and direct GitHub release downloads.
###############################################################################

INSTALLER_VERSION="dev"
[[ -n "${INSTALLER_VERSION_OVERRIDE:-}" ]] && INSTALLER_VERSION="$INSTALLER_VERSION_OVERRIDE"

# CLI option state
OPT_ALL=0
OPT_FONTS=""
OPT_LIST=0
OPT_INSTALLED=0
OPT_UNINSTALL_MODE=""
OPT_DRY_RUN=0
OPT_BACKEND="auto"
OPT_VERSION=0
OPT_HELP=0
OPT_QUIET="${QUIET:-0}"
OPT_JOBS="${NF_JOBS:-4}"

# Colors (disabled when NO_COLOR is set or --no-color is specified)
COLOR_RED='\033[0;31m'
COLOR_GREEN='\033[0;32m'
COLOR_YELLOW='\033[0;33m'
COLOR_CYAN='\033[0;36m'
COLOR_RESET='\033[0m'

if [[ -n "${NO_COLOR:-}" ]]; then
  COLOR_RED=''
  COLOR_GREEN=''
  COLOR_YELLOW=''
  COLOR_CYAN=''
  COLOR_RESET=''
fi

disable_colors() {
  COLOR_RED=''
  COLOR_GREEN=''
  COLOR_YELLOW=''
  COLOR_CYAN=''
  COLOR_RESET=''
}

# FZF default styling
FZF_PROMPT="Select Nerd Fonts: "
FZF_HEIGHT="60%"
FZF_LAYOUT="reverse"

GITHUB_REPO="${GITHUB_REPO:-ryanoasis/nerd-fonts}"
RESOLVED_BACKEND=""
DETECTED_OS=""
CACHED_FONT_LIST=""
CACHED_FONT_LIST_BACKEND=""
CACHED_INSTALLED_LIST=""
FAILED_FONTS=()
PACKAGE_MAP=""

# -----------------------------------------------------------------------------
# Logging and Output Helpers
# -----------------------------------------------------------------------------

die() {
  local code=$1
  shift
  echo -e "${COLOR_RED}❗  $*${COLOR_RESET}" >&2
  exit "$code"
}

print_step() {
  [[ "$OPT_QUIET" == 1 ]] && return 0
  echo -e "\n${COLOR_CYAN}➜  $*${COLOR_RESET}\n"
}

print_success() {
  [[ "$OPT_QUIET" == 1 ]] && return 0
  echo -e "\n${COLOR_GREEN}✅  $*${COLOR_RESET}\n"
}

print_warn() {
  [[ "$OPT_QUIET" == 1 ]] && return 0
  echo -e "${COLOR_YELLOW}⚠️  $*${COLOR_RESET}" >&2
}

backend_debug() {
  if [[ "${NF_DEBUG_BACKEND:-}" == "1" ]]; then
    printf '[debug] %s\n' "$1" >&2
  fi
}

nf_run_priv() {
  if [[ $EUID -eq 0 ]] || ! command -v sudo >/dev/null 2>&1; then
    "$@"
  else
    sudo "$@"
  fi
}

# -----------------------------------------------------------------------------
# OS Detection & Backend Resolution
# -----------------------------------------------------------------------------

detect_os() {
  case "$(uname -s)" in
    Darwin) DETECTED_OS="macos" ;;
    Linux) DETECTED_OS="linux" ;;
    *) DETECTED_OS="unknown" ;;
  esac
}

resolve_backend() {
  local requested=${1:-auto}
  detect_os
  [[ "$DETECTED_OS" != unknown ]] || die 2 "Unsupported operating system."
  if [[ "$requested" != auto ]]; then
    if [[ "$requested" != direct ]]; then
      "${requested}_is_available" || die 2 "Backend '$requested' is unavailable. Try --backend direct."
    fi
    RESOLVED_BACKEND="$requested"
  elif [[ "$DETECTED_OS" == macos ]] && brew_is_available; then
    RESOLVED_BACKEND=brew
  else
    RESOLVED_BACKEND=direct
  fi
  backend_debug "backend=$RESOLVED_BACKEND"
}

# -----------------------------------------------------------------------------
# CLI Parsing & Validation
# -----------------------------------------------------------------------------

usage() {
  cat <<'EOF'
Usage: install.sh [OPTIONS]

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
                           Installation backend (default: auto).
  -j, --jobs NUM           Number of parallel download jobs for direct backend (default: 4).
  --dry-run                Print what would be done without touching the system.
  --yes                    Reserved: accept future prompts (no effect yet).
  --quiet                  Suppress step/success/warning messages.
  --no-color               Disable colored output.
  --version                Print version information and exit.
  -h, --help               Show this help message and exit.
EOF
}

normalize_font_list() {
  printf '%s' "$1" | tr -d ' ' | tr ',' '\n' | awk 'NF && !seen[$0]++'
}

validate_arg_combination() {
  case "$OPT_BACKEND" in
    auto | brew | pacman | direct) ;;
    *) die 1 "Unknown backend '$OPT_BACKEND'. Use auto, brew, pacman or direct." ;;
  esac
  [[ "$OPT_JOBS" =~ ^[1-9][0-9]*$ ]] || die 1 "NF_JOBS/--jobs requires a positive integer."
  if [[ -n "${XDG_DATA_HOME:-}" && "$XDG_DATA_HOME" != /* ]]; then
    die 1 "XDG_DATA_HOME must be an absolute path."
  fi

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

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --all)
        OPT_ALL=1
        shift
        ;;
      --fonts)
        [[ $# -lt 2 ]] && die 1 "Option --fonts requires an argument."
        OPT_FONTS=$2
        shift 2
        ;;
      --fonts=*)
        OPT_FONTS="${1#*=}"
        shift
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
        if [[ $# -ge 2 && "$2" != --* ]]; then
          OPT_UNINSTALL_MODE=$2
          shift 2
        else
          OPT_UNINSTALL_MODE="interactive"
          shift
        fi
        ;;
      --uninstall=*)
        OPT_UNINSTALL_MODE="${1#*=}"
        shift
        ;;
      --backend)
        [[ $# -lt 2 ]] && die 1 "Option --backend requires an argument."
        OPT_BACKEND=$2
        shift 2
        ;;
      --backend=*)
        OPT_BACKEND="${1#*=}"
        shift
        ;;
      -j | --jobs)
        [[ $# -lt 2 ]] && die 1 "Option --jobs requires an argument."
        if ! [[ "$2" =~ ^[1-9][0-9]*$ ]]; then
          die 1 "Option --jobs requires a positive integer."
        fi
        OPT_JOBS=$2
        shift 2
        ;;
      --jobs=*)
        local val="${1#*=}"
        if ! [[ "$val" =~ ^[1-9][0-9]*$ ]]; then
          die 1 "Option --jobs requires a positive integer."
        fi
        OPT_JOBS="$val"
        shift
        ;;
      --dry-run)
        OPT_DRY_RUN=1
        shift
        ;;
      --yes) shift ;;
      --quiet)
        OPT_QUIET=1
        shift
        ;;
      --no-color)
        disable_colors
        shift
        ;;
      --version)
        OPT_VERSION=1
        shift
        ;;
      -h | --help)
        OPT_HELP=1
        shift
        ;;
      *) die 1 "Unknown argument: $1" ;;
    esac
  done
}

# -----------------------------------------------------------------------------
# Dependency Management
# -----------------------------------------------------------------------------

ensure_fzf_available() {
  if command -v fzf >/dev/null 2>&1; then
    return 0
  fi

  if [[ "$RESOLVED_BACKEND" == "brew" ]]; then
    print_warn "fzf não está instalado. Tentando instalar via Homebrew..."
    if brew install fzf; then
      print_success "fzf instalado com sucesso."
      return 0
    fi
  fi

  die 2 "fzf é necessário para o modo interativo. Instale-o manualmente ou use --all / --fonts."
}

check_dependencies() {
  case "$RESOLVED_BACKEND" in
    brew | pacman)
      command -v "$RESOLVED_BACKEND" >/dev/null 2>&1 || die 2 "Backend '$RESOLVED_BACKEND' is unavailable."
      ;;
    direct)
      # Listing, removal and previews never need a downloader or extraction tool.
      if [[ "$OPT_LIST" == 1 || "$OPT_INSTALLED" == 1 || -n "$OPT_UNINSTALL_MODE" || "$OPT_DRY_RUN" == 1 ]]; then
        return 0
      fi
      direct_is_available || die 2 "Direct installation requires curl or wget and tar with xz support."
      ;;
  esac
}

# -----------------------------------------------------------------------------
# Backend: Homebrew
# -----------------------------------------------------------------------------

brew_is_available() { command -v brew >/dev/null 2>&1; }

canonical_id() {
  case "$1" in
    caskaydiacove) echo cascadiacode ;;
    caskaydiamono) echo cascadiamono ;;
    saucecodepro) echo sourcecodepro ;;
    shuretechmono) echo sharetechmono ;;
    meslolg) echo meslo ;;
    symbolsonly) echo nerdfontssymbolsonly ;;
    proggycleantt) echo proggyclean ;;
    recursivemono) echo recursive ;;
    terminessttf) echo terminess ;;
    hurmit) echo hermit ;;
    imwriting) echo iawriter ;;
    intonemono | intefont) echo intelonemono ;;
    blexmono) echo ibmplexmono ;;
    roboto) echo robotomono ;;
    *) printf '%s\n' "$1" ;;
  esac
}

package_lookup() {
  local wanted=$1 id package
  while IFS='|' read -r id package; do
    if [[ "$id" == "$wanted" ]]; then
      printf '%s' "$package"
      return 0
    fi
  done <<<"$PACKAGE_MAP"
  print_warn "No $RESOLVED_BACKEND package found for '$wanted'."
  return 1
}

brew_cask_to_id() {
  local id=$1
  id="${id#font-}"
  id="${id%-nerd-font}"
  id="${id//-/}"
  canonical_id "$id"
}

brew_id_to_cask() { package_lookup "$1"; }

brew_list_fonts() {
  local search_output
  search_output=$(brew search '/font-.*-nerd-font/' 2>/dev/null) || die 2 "Failed to search Nerd Fonts via Homebrew."
  local cask
  while IFS= read -r cask; do
    [[ -z "$cask" ]] && continue
    cask=$(printf '%s' "$cask" | awk '{ print $1 }')
    case $cask in
      font-*-nerd-font)
        local id
        id=$(brew_cask_to_id "$cask")
        [[ -n "$id" ]] && printf '%s\n' "$id"
        ;;
    esac
  done <<<"$search_output"
}

brew_list_installed_fonts() {
  local installed
  installed=$(brew list --cask 2>/dev/null | grep 'nerd-font' || true)
  [[ -z "$installed" ]] && return 0
  local cask
  while IFS= read -r cask; do
    [[ -z "$cask" ]] && continue
    local id
    id=$(brew_cask_to_id "$cask")
    [[ -n "$id" ]] && printf '%s\n' "$id"
  done <<<"$installed"
}

brew_is_font_installed() {
  brew list --cask "$(brew_id_to_cask "$1")" >/dev/null 2>&1
}

brew_dry_run_install() {
  echo "[dry-run] Would install $(brew_id_to_cask "$1")."
}

brew_dry_run_uninstall() {
  echo "[dry-run] Would uninstall $(brew_id_to_cask "$1")."
}

brew_install_fonts() {
  local ids=("$@")
  local casks=()
  local id
  for id in "${ids[@]}"; do
    casks+=("$(brew_id_to_cask "$id")")
    [[ -n "${casks[${#casks[@]} - 1]}" ]] || die 2 "Cannot resolve cask for $id."
  done

  echo "Installing ${casks[*]}..."
  brew install --cask --dry-run "${casks[@]}" || die 2 "Homebrew cannot install the selected casks on this system. Try --backend direct."
  if brew install --cask "${casks[@]}"; then
    for cask in "${casks[@]}"; do
      print_success "Successfully installed ${cask}."
    done
    return 0
  fi

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

brew_uninstall_fonts() {
  local ids=("$@")
  local casks=()
  local id
  for id in "${ids[@]}"; do
    casks+=("$(brew_id_to_cask "$id")")
    [[ -n "${casks[${#casks[@]} - 1]}" ]] || die 2 "Cannot resolve cask for $id."
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

# -----------------------------------------------------------------------------
# Backend: Pacman
# -----------------------------------------------------------------------------

pacman_is_available() { command -v pacman >/dev/null 2>&1; }

pacman_normalize_pkg() {
  local id=$1
  [[ "$id" != *nerd* ]] && return 0
  id="${id#ttf-}"
  id="${id#otf-}"
  id="${id%-nerd-font}"
  id="${id%-nerd}"
  id="${id//-/}"
  canonical_id "$id"
}

pacman_id_to_pkg() {
  package_lookup "$1"
}

pacman_list_fonts() {
  local pkgs
  pkgs=$(pacman -Sgq nerd-fonts 2>/dev/null) || pkgs=$(pacman -Ssq nerd 2>/dev/null) || pkgs=""
  local pkg
  while IFS= read -r pkg; do
    [[ -z "$pkg" ]] && continue
    local id
    id=$(pacman_normalize_pkg "$pkg")
    [[ -n "$id" ]] && printf '%s\n' "$id"
  done <<<"$pkgs"
}

pacman_list_installed_fonts() {
  local installed
  installed=$(pacman -Qq 2>/dev/null | grep 'nerd' || true)
  [[ -z "$installed" ]] && return 0
  local pkg
  while IFS= read -r pkg; do
    [[ -z "$pkg" ]] && continue
    local id
    id=$(pacman_normalize_pkg "$pkg")
    [[ -n "$id" ]] && printf '%s\n' "$id"
  done <<<"$installed"
}

pacman_is_font_installed() {
  pacman -Qi "$(pacman_id_to_pkg "$1")" >/dev/null 2>&1
}

pacman_dry_run_install() {
  echo "[dry-run] Would install $(pacman_id_to_pkg "$1")."
}

pacman_dry_run_uninstall() {
  echo "[dry-run] Would uninstall $(pacman_id_to_pkg "$1")."
}

pacman_install_fonts() {
  local ids=("$@")
  local pkgs=()
  local id
  for id in "${ids[@]}"; do
    pkgs+=("$(pacman_id_to_pkg "$id")")
    [[ -n "${pkgs[${#pkgs[@]} - 1]}" ]] || die 2 "Cannot resolve package for $id."
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

pacman_uninstall_fonts() {
  local ids=("$@")
  local pkgs=()
  local id
  for id in "${ids[@]}"; do
    pkgs+=("$(pacman_id_to_pkg "$id")")
    [[ -n "${pkgs[${#pkgs[@]} - 1]}" ]] || die 2 "Cannot resolve package for $id."
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

# -----------------------------------------------------------------------------
# Backend: Direct (GitHub Releases)
# -----------------------------------------------------------------------------

direct_is_available() {
  # Actual xz support is checked against the downloaded archive before publication.
  if command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1; then
    command -v tar >/dev/null 2>&1
  else
    return 1
  fi
}

direct_font_dir() {
  if [[ "${DETECTED_OS:-}" == "macos" ]] || [[ "$(uname -s)" == "Darwin" ]]; then
    printf '%s' "${HOME}/Library/Fonts"
  else
    printf '%s' "${XDG_DATA_HOME:-$HOME/.local/share}/fonts"
  fi
}

DIRECT_CATALOG="0xproto|0xProto.tar.xz
3270|3270.tar.xz
adwaitamono|AdwaitaMono.tar.xz
agave|Agave.tar.xz
annotationmono|AnnotationMono.tar.xz
anonymouspro|AnonymousPro.tar.xz
arimo|Arimo.tar.xz
atkynsonmono|AtkinsonHyperlegibleMono.tar.xz
aurulentsansmono|AurulentSansMono.tar.xz
bigblueterminal|BigBlueTerminal.tar.xz
bitstreamverasansmono|BitstreamVeraSansMono.tar.xz
cascadiacode|CascadiaCode.tar.xz
cascadiamono|CascadiaMono.tar.xz
codenewroman|CodeNewRoman.tar.xz
comicshannsmono|ComicShannsMono.tar.xz
commitmono|CommitMono.tar.xz
cousine|Cousine.tar.xz
d2coding|D2Coding.tar.xz
daddytimemono|DaddyTimeMono.tar.xz
dejavusansmono|DejaVuSansMono.tar.xz
departuremono|DepartureMono.tar.xz
droidsansmono|DroidSansMono.tar.xz
envycoder|EnvyCodeR.tar.xz
fantasquesansmono|FantasqueSansMono.tar.xz
firacode|FiraCode.tar.xz
firamono|FiraMono.tar.xz
geistmono|GeistMono.tar.xz
gohufont|Gohu.tar.xz
gomono|Go-Mono.tar.xz
googlesanscode|GoogleSansCode.tar.xz
hack|Hack.tar.xz
hasklig|Hasklig.tar.xz
heavydata|HeavyData.tar.xz
hermit|Hermit.tar.xz
iawriter|iA-Writer.tar.xz
ibmplexmono|IBMPlexMono.tar.xz
inconsolata|Inconsolata.tar.xz
inconsolatago|InconsolataGo.tar.xz
inconsolatalgc|InconsolataLGC.tar.xz
intelonemono|IntelOneMono.tar.xz
iosevka|Iosevka.tar.xz
iosevkaterm|IosevkaTerm.tar.xz
iosevkatermslab|IosevkaTermSlab.tar.xz
jetbrainsmono|JetBrainsMono.tar.xz
lekton|Lekton.tar.xz
liberationmono|LiberationMono.tar.xz
lilex|Lilex.tar.xz
martianmono|MartianMono.tar.xz
meslo|Meslo.tar.xz
monaspace|Monaspace.tar.xz
monofur|Monofur.tar.xz
monoid|Monoid.tar.xz
mononoki|Mononoki.tar.xz
mplus|MPlus.tar.xz
nerdfontssymbolsonly|NerdFontsSymbolsOnly.tar.xz
noto|Noto.tar.xz
opendyslexic|OpenDyslexic.tar.xz
overpass|Overpass.tar.xz
profont|ProFont.tar.xz
proggyclean|ProggyClean.tar.xz
recursive|Recursive.tar.xz
robotomono|RobotoMono.tar.xz
sharetechmono|ShareTechMono.tar.xz
sourcecodepro|SourceCodePro.tar.xz
spacemono|SpaceMono.tar.xz
terminess|Terminus.tar.xz
tinos|Tinos.tar.xz
ubuntu|Ubuntu.tar.xz
ubuntumono|UbuntuMono.tar.xz
ubuntusans|UbuntuSans.tar.xz
victormono|VictorMono.tar.xz
zedmono|ZedMono.tar.xz"

direct_id_to_asset() {
  local id asset
  while IFS='|' read -r id asset; do
    if [[ "$id" == "$1" ]]; then
      printf '%s' "$asset"
      return 0
    fi
  done <<<"$DIRECT_CATALOG"
  print_warn "Unknown release asset for '$1'."
  return 1
}

direct_list_fonts() {
  local id asset
  while IFS='|' read -r id asset; do printf '%s\n' "$id"; done <<<"$DIRECT_CATALOG"
}

# Managed paths are private to this installer; legacy flat font files are untouched.
direct_family_dir() { printf '%s/NerdFonts/%s' "$(direct_font_dir)" "$1"; }

safe_relative_path() {
  case "$1" in '' | /* | . | .. | ../* | */../* | */.. | ./* | */./* | */. | *\\* | *$'\t'* | *$'\n'*) return 1 ;; esac
}

safe_managed_path() {
  local base=$1 relative=$2 component current
  safe_relative_path "$relative" || return 1
  [[ ! -L "$base" && ! -L "$(dirname "$base")" ]] || return 1
  current=$base
  while [[ "$relative" == */* ]]; do
    component=${relative%%/*}
    relative=${relative#*/}
    current="$current/$component"
    [[ ! -L "$current" ]] || return 1
  done
  [[ ! -L "$current/$relative" ]]
}

manifest_read() {
  local id=$1 require_files=${2:-0} family manifest line key value count=0
  family=$(direct_family_dir "$id")
  manifest="$family/.nerdfonts-manifest"
  MANIFEST_FILES=""
  [[ -f "$manifest" && ! -L "$manifest" && ! -L "$family" && ! -L "$(dirname "$family")" ]] || return 1
  {
    IFS= read -r line && [[ "$line" == nerdfonts-manifest-v1 ]] || return 1
    IFS= read -r line && [[ "$line" == $'id\t'"$id" ]] || return 1
    IFS= read -r line && [[ "$line" == $'asset\t'*.tar.xz ]] || return 1
    IFS= read -r line && [[ "$line" == $'source\thttps://'* ]] || return 1
    while IFS=$'\t' read -r key value; do
      [[ "$key" == file ]] || return 1
      safe_managed_path "$family" "$value" || return 1
      case "$value" in *.ttf | *.otf | *.TTF | *.OTF) ;; *) return 1 ;; esac
      if [[ "$require_files" == 1 ]]; then [[ -f "$family/$value" ]] || return 1; fi
      MANIFEST_FILES+="${MANIFEST_FILES:+$'\n'}$value"
      count=$((count + 1))
    done
  } <"$manifest"
  [[ "$count" -gt 0 ]]
}

direct_is_font_installed() { manifest_read "$1" 1; }

direct_list_installed_fonts() {
  local root id family
  root="$(direct_font_dir)/NerdFonts"
  [[ -d "$root" && ! -L "$root" ]] || return 0
  for family in "$root"/*; do
    [[ -d "$family" && ! -L "$family" ]] || continue
    id=${family##*/}
    [[ "$id" =~ ^[a-z0-9]+$ ]] || continue
    if manifest_read "$id" 1; then
      printf '%s\n' "$id"
    else
      print_warn "Incomplete or invalid managed installation: $id. Reinstall to repair."
    fi
  done
}

direct_dry_run_install() {
  local asset
  asset=$(direct_id_to_asset "$1") || return 1
  echo "[dry-run] Would download https://github.com/${GITHUB_REPO}/releases/latest/download/${asset} and install to $(direct_family_dir "$1")."
}

direct_dry_run_uninstall() {
  local relative
  manifest_read "$1" || die 4 "Invalid manifest for '$1'; refusing removal."
  while IFS= read -r relative; do
    printf '[dry-run] Would remove %s/%s.\n' "$(direct_family_dir "$1")" "$relative"
  done <<<"$MANIFEST_FILES"
}

# Download policy is shared by all direct installation jobs.
download_asset() {
  # This function runs as a background job. Keep trap state in its process
  # scope: Bash 3.2 releases function locals before running EXIT traps.
  url=$1 dest=$2 attempt=1 transfer_pid="" timer_pid="" client=""
  trap '[[ -z "$transfer_pid" ]] || kill -TERM "$transfer_pid" 2>/dev/null || true; [[ -z "$timer_pid" ]] || kill -TERM "$timer_pid" 2>/dev/null || true; wait 2>/dev/null || true' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  while ((attempt <= 3)); do
    status=0
    if command -v curl >/dev/null 2>&1; then
      client=curl
      curl -fSL --connect-timeout 15 --max-time 300 -w '%{http_code}' -o "$dest" "$url" >"$dest.http" &
      transfer_pid=$!
      wait "$transfer_pid" || status=$?
      transfer_pid=""
      http=$(cat "$dest.http")
    else
      client=wget
      wget --server-response --timeout=15 --tries=1 -O "$dest" "$url" 2>"$dest.http" &
      transfer_pid=$!
      # Portable watchdog also bounds slow transfers with wget.
      (
        sleep 300 &
        watchdog_sleep=$!
        trap 'kill -TERM "$watchdog_sleep" 2>/dev/null || true; wait "$watchdog_sleep" 2>/dev/null || true; exit' TERM INT
        wait "$watchdog_sleep"
        kill -TERM "$transfer_pid" 2>/dev/null || true
      ) &
      timer_pid=$!
      wait "$transfer_pid" || status=$?
      transfer_pid=""
      kill -TERM "$timer_pid" 2>/dev/null || true
      wait "$timer_pid" 2>/dev/null || true
      timer_pid=""
      http=$(awk '/HTTP\/[0-9.]+ [0-9]+/ { code=$2 } END { print code }' "$dest.http")
      if [[ "$status" != 0 ]]; then cat "$dest.http" >&2; fi
    fi
    if [[ "$status" == 0 && -s "$dest" ]]; then return 0; fi
    print_warn "Download failed (attempt $attempt/3, HTTP ${http:-unknown}, status $status): $url"
    case "$http" in
      408 | 429 | 5?? | 000 | '') ;;
      4??) return 1 ;;
      *)
        # A response header can be successful even if its body is truncated.
        case "$client:$status" in
          curl:5 | curl:6 | curl:7 | curl:18 | curl:28 | curl:35 | curl:52 | curl:55 | curl:56 | wget:4 | wget:143) ;;
          *) return 1 ;;
        esac
        ;;
    esac
    ((attempt < 3)) || return 1
    attempt=$((attempt + 1))
    sleep 1
  done
}

validate_archive() {
  local archive=$1 listing=$2 name entry
  tar -tJf "$archive" >"$listing" || return 1
  tar -tvJf "$archive" >"$listing.types" || return 1
  while IFS= read -r entry; do
    case "$entry" in [-d]*) ;; *)
      print_warn "Archive contains a link or special file."
      return 1
      ;;
    esac
  done <"$listing.types"
  while IFS= read -r name; do
    while [[ "$name" == ./* ]]; do name=${name#./}; done
    name=${name%/}
    [[ -z "$name" || "$name" == . ]] && continue
    safe_relative_path "$name" || {
      print_warn "Unsafe archive path: $name"
      return 1
    }
  done <"$listing"
}

direct_install_single() {
  # Background worker owns this state until its EXIT cleanup completes.
  id=$1 target_dir=$2 status_dir=$3 failed=0 download_pid=""
  root="$target_dir/NerdFonts"
  family="$root/$id"
  lock="$root/.$id.lock"
  [[ ! -L "$root" && ! -L "$family" ]] || {
    print_warn "Refusing symlink destination for $id."
    return 1
  }
  mkdir -p "$root" || return 1
  mkdir "$lock" || {
    print_warn "Another operation holds the lock for $id."
    return 1
  }
  stage=$(mktemp -d "$root/.$id.stage.XXXXXX") || {
    rmdir "$lock"
    return 1
  }
  trap '[[ -z "$download_pid" ]] || kill -TERM "$download_pid" 2>/dev/null || true
    wait 2>/dev/null || true
    if [[ -d "$stage/previous" && ! -e "$family" ]]; then
      if ! mv "$stage/previous" "$family"; then
        print_warn "Recovery required: previous installation preserved at $stage/previous"
        rmdir "$lock" 2>/dev/null || true
        exit 1
      fi
    fi
    rm -rf "$stage"
    rmdir "$lock" 2>/dev/null || true' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  asset=$(direct_id_to_asset "$id") || return 1
  url="https://github.com/${GITHUB_REPO}/releases/latest/download/${asset}"
  echo "Installing $id ($asset)..."
  {
    download_asset "$url" "$stage/archive"
    exit "$?"
  } &
  download_pid=$!
  if ! wait "$download_pid"; then
    print_warn "$id: download failed."
    return 1
  fi
  download_pid=""
  validate_archive "$stage/archive" "$stage/list" || {
    print_warn "$id: invalid archive."
    return 1
  }
  mkdir "$stage/extract" "$stage/new"
  tar -xJf "$stage/archive" -C "$stage/extract" || {
    print_warn "$id: extraction failed."
    return 1
  }
  find "$stage/extract" -type f \( -iname '*.ttf' -o -iname '*.otf' \) >"$stage/fonts"
  {
    printf 'nerdfonts-manifest-v1\nid\t%s\nasset\t%s\nsource\t%s\n' "$id" "$asset" "$url"
    while IFS= read -r file; do
      relative=${file#"$stage/extract/"}
      safe_relative_path "$relative" || {
        failed=1
        break
      }
      mkdir -p "$stage/new/$(dirname "$relative")" || {
        failed=1
        break
      }
      cp "$file" "$stage/new/$relative" || {
        failed=1
        break
      }
      printf 'file\t%s\n' "$relative"
    done <"$stage/fonts"
  } >"$stage/new/.nerdfonts-manifest"
  [[ "$failed" == 0 && -s "$stage/fonts" ]] || {
    print_warn "$id: archive contains no usable font files."
    return 1
  }
  # Never replace untracked files in an existing directory.
  if [[ -e "$family" ]]; then
    if ! manifest_read "$id"; then
      print_warn "$id: invalid existing manifest; refusing replacement."
      return 1
    fi
    find "$family" ! -type d >"$stage/existing"
    while IFS= read -r file; do
      relative=${file#"$family/"}
      [[ "$relative" == .nerdfonts-manifest ]] && continue
      if ! list_contains "$relative" "$MANIFEST_FILES"; then
        print_warn "$id: untracked files prevent replacement."
        return 1
      fi
    done <"$stage/existing"
    mv "$family" "$stage/previous" || return 1
  fi
  if ! mv "$stage/new" "$family"; then
    if [[ -d "$stage/previous" ]]; then mv "$stage/previous" "$family"; fi
    return 1
  fi
  touch "$status_dir/$id.ok"
  print_success "Successfully installed $id."
}

refresh_font_cache() {
  if [[ "$DETECTED_OS" == linux ]] && command -v fc-cache >/dev/null 2>&1; then
    fc-cache -f "$(direct_font_dir)" || print_warn "Fonts changed, but fontconfig cache refresh failed. Run fc-cache -f manually."
  fi
}

direct_install_fonts() {
  local target_dir status_dir id pid active=0 changed=0
  local pids=()
  target_dir=$(direct_font_dir)
  status_dir=$(mktemp -d)
  trap 'for pid in ${pids[@]+"${pids[@]}"}; do kill -TERM "$pid" 2>/dev/null || true; done; wait || true; rm -rf "$status_dir"; exit 130' INT
  trap 'for pid in ${pids[@]+"${pids[@]}"}; do kill -TERM "$pid" 2>/dev/null || true; done; wait || true; rm -rf "$status_dir"; exit 143' TERM
  for id in "$@"; do
    {
      direct_install_single "$id" "$target_dir" "$status_dir"
      exit "$?"
    } &
    pids+=("$!")
    active=$((active + 1))
    if ((active >= OPT_JOBS)); then
      for pid in ${pids[@]+"${pids[@]}"}; do wait "$pid" || true; done
      pids=()
      active=0
    fi
  done
  for pid in ${pids[@]+"${pids[@]}"}; do wait "$pid" || true; done
  for id in "$@"; do
    if [[ -f "$status_dir/$id.ok" ]]; then changed=1; else FAILED_FONTS+=("$id"); fi
  done
  rm -rf "$status_dir"
  trap 'exit 130' INT
  trap 'exit 143' TERM
  if [[ "$changed" == 1 ]]; then refresh_font_cache; fi
}

direct_uninstall_single() (
  id=$1 failed=0
  family=$(direct_family_dir "$id")
  root=$(dirname "$family")
  lock="$root/.$id.lock"
  [[ ! -L "$root" && ! -L "$family" ]] || return 1
  mkdir "$lock" || return 1
  trap 'rmdir "$lock" 2>/dev/null || true' EXIT
  manifest_read "$id" || {
    print_warn "$id: invalid manifest; refusing removal."
    return 1
  }
  while IFS= read -r relative; do
    if [[ -e "$family/$relative" ]] && ! rm -f "$family/$relative"; then failed=1; fi
  done <<<"$MANIFEST_FILES"
  [[ "$failed" == 0 ]] || return 1
  rm -f "$family/.nerdfonts-manifest" || return 1
  find "$family" -depth -type d -exec rmdir '{}' \; 2>/dev/null || true
  if [[ -d "$family" ]]; then print_warn "$id: preserved untracked files in $family."; fi
  print_success "Successfully uninstalled $id."
)

direct_uninstall_fonts() {
  local id changed=0
  for id in "$@"; do
    if direct_uninstall_single "$id"; then changed=1; else FAILED_FONTS+=("$id"); fi
  done
  if [[ "$changed" == 1 ]]; then refresh_font_cache; fi
}

# -----------------------------------------------------------------------------
# Font Management & Dispatch Core
# -----------------------------------------------------------------------------

load_package_catalog() {
  local mode=$1 raw package id
  if [[ "$RESOLVED_BACKEND" == brew ]]; then
    if [[ "$mode" == installed ]]; then
      raw=$(brew list --cask) || die 2 "Failed to read installed Homebrew casks."
    else
      raw=$(brew search '/font-.*-nerd-font/') || return 1
    fi
  else
    if [[ "$mode" == installed ]]; then
      raw=$(pacman -Qq) || die 2 "Failed to read installed Pacman packages."
    else
      raw=$(pacman -Sgq nerd-fonts) || raw=$(pacman -Ssq nerd) || return 1
    fi
  fi
  PACKAGE_MAP=""
  CATALOG_IDS=""
  while IFS= read -r package; do
    package=${package%% *}
    if [[ "$RESOLVED_BACKEND" == brew ]]; then
      case "$package" in font-*-nerd-font) id=$(brew_cask_to_id "$package") ;; *) continue ;; esac
    else
      case "$package" in
        ttf-*-nerd | otf-*-nerd | ttf-*-nerd-font | otf-*-nerd-font | ttf-nerd-fonts-symbols | ttf-nerd-fonts-symbols-mono)
          id=$(pacman_normalize_pkg "$package")
          ;;
        *) continue ;;
      esac
    fi
    [[ -n "$id" ]] || continue
    PACKAGE_MAP+="${PACKAGE_MAP:+$'\n'}$id|$package"
    CATALOG_IDS+="${CATALOG_IDS:+$'\n'}$id"
  done <<<"$raw"
}

load_font_catalog() {
  if [[ "$CACHED_FONT_LIST_BACKEND" == "$RESOLVED_BACKEND" && -n "$CACHED_FONT_LIST" ]]; then
    return 0
  fi
  if [[ "$RESOLVED_BACKEND" == direct ]]; then
    CACHED_FONT_LIST=$(direct_list_fonts)
  elif load_package_catalog available && [[ -n "$CATALOG_IDS" ]]; then
    CACHED_FONT_LIST=$CATALOG_IDS
  elif [[ "$OPT_BACKEND" == auto && "$DETECTED_OS" == macos ]]; then
    print_warn "Homebrew catalog unavailable; using direct downloads."
    RESOLVED_BACKEND=direct
    check_dependencies
    CACHED_FONT_LIST=$(direct_list_fonts)
  else
    die 2 "Cannot load $RESOLVED_BACKEND font catalog. Try --backend direct."
  fi
  CACHED_FONT_LIST_BACKEND=$RESOLVED_BACKEND
}

load_installed_fonts() {
  if [[ "$RESOLVED_BACKEND" == direct ]]; then
    CACHED_INSTALLED_LIST=$(direct_list_installed_fonts)
  else
    load_package_catalog installed
    CACHED_INSTALLED_LIST=$CATALOG_IDS
  fi
}

is_font_installed() {
  "${RESOLVED_BACKEND}_is_font_installed" "$1"
}

select_fonts() {
  local fonts_list=$1
  printf '%s\n' "$fonts_list" | fzf \
    --multi \
    --prompt="$FZF_PROMPT" \
    --height="$FZF_HEIGHT" \
    --layout="$FZF_LAYOUT"
}

list_contains() {
  local needle=$1
  local haystack=$2
  grep -Fxq "$needle" <<<"$haystack"
}

filter_font_list() {
  local requested=$1
  local target_list=$2
  local warn_pattern=$3
  local matched=""
  local font

  while IFS= read -r font; do
    [[ -z "$font" ]] && continue
    font=$(canonical_id "$font")
    if list_contains "$font" "$matched"; then continue; fi
    if list_contains "$font" "$target_list"; then
      matched+="${matched:+$'\n'}${font}"
    else
      # shellcheck disable=SC2059 # Callers provide a fixed format, never user input.
      print_warn "$(printf "$warn_pattern" "$font")"
    fi
  done <<<"$requested"

  printf '%s' "$matched"
}

install_named_fonts() {
  local to_install
  to_install=$(filter_font_list "$1" "$2" "Unknown font '%s'. Skipping.")
  if [[ -z "$to_install" ]]; then
    die 3 "None of the requested fonts are available. Run with --list to see the valid names."
  fi
  dispatch_install_fonts "$to_install"
}

uninstall_named_fonts() {
  local to_uninstall
  to_uninstall=$(filter_font_list "$1" "$2" "'%s' is not installed. Skipping.")
  if [[ -z "$to_uninstall" ]]; then
    die 3 "None of the requested fonts are installed. Run with --installed to see what is present."
  fi
  dispatch_uninstall_fonts "$to_uninstall"
}

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

dispatch_uninstall_fonts() {
  local fonts=$1
  local id
  local pending=()
  FAILED_FONTS=()

  while IFS= read -r id; do
    [[ -z "$id" ]] && continue
    if [[ "$OPT_DRY_RUN" == 1 ]]; then
      "${RESOLVED_BACKEND}_dry_run_uninstall" "$id"
    elif [[ "$RESOLVED_BACKEND" != direct ]] && ! is_font_installed "$id"; then
      print_warn "${id} is not installed. Skipping."
    else
      pending+=("$id")
    fi
  done <<<"$fonts"

  [[ "$OPT_DRY_RUN" == 1 ]] && return 0
  [[ ${#pending[@]} -eq 0 ]] && return 0
  "${RESOLVED_BACKEND}_uninstall_fonts" "${pending[@]}"
}

has_failed_fonts() {
  [[ ${#FAILED_FONTS[@]} -gt 0 ]]
}

# -----------------------------------------------------------------------------
# Command Actions & Orchestration
# -----------------------------------------------------------------------------

cmd_list_fonts() {
  load_font_catalog
  if [[ -z "$CACHED_FONT_LIST" ]]; then
    die 3 "No Nerd Fonts found for the '${RESOLVED_BACKEND}' backend."
  fi
  printf '%s\n' "$CACHED_FONT_LIST"
}

cmd_list_installed_fonts() {
  load_installed_fonts
  if [[ -z "$CACHED_INSTALLED_LIST" ]]; then
    print_warn "No Nerd Fonts are currently installed."
    return 0
  fi
  printf '%s\n' "$CACHED_INSTALLED_LIST"
}

run_install() {
  load_font_catalog

  if [[ -n "$OPT_FONTS" ]]; then
    local requested
    requested=$(normalize_font_list "$OPT_FONTS")
    [[ -z "$requested" ]] && die 1 "Option --fonts requires at least one font name."

    print_step "Fetching available Nerd Fonts..."
    [[ -z "$CACHED_FONT_LIST" ]] && die 3 "No Nerd Fonts found for backend '${RESOLVED_BACKEND}'."

    install_named_fonts "$requested" "$CACHED_FONT_LIST"
    if has_failed_fonts; then
      die 4 "Some fonts failed to install (${FAILED_FONTS[*]})."
    fi
    return 0
  fi

  print_step "Fetching available Nerd Fonts..."
  [[ -z "$CACHED_FONT_LIST" ]] && die 3 "No Nerd Fonts found for backend '${RESOLVED_BACKEND}'."

  if [[ "$OPT_ALL" == 1 ]]; then
    print_step "Installing all available Nerd Fonts..."
    dispatch_install_fonts "$CACHED_FONT_LIST"
    if has_failed_fonts; then
      die 4 "Some fonts failed to install (${FAILED_FONTS[*]})."
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
    die 4 "Some fonts failed to install (${FAILED_FONTS[*]})."
  fi
}

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
      die 4 "Some fonts failed to uninstall (${FAILED_FONTS[*]})."
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
      die 4 "Some fonts failed to uninstall (${FAILED_FONTS[*]})."
    fi
    return 0
  fi

  local requested
  requested=$(normalize_font_list "$OPT_UNINSTALL_MODE")
  [[ -z "$requested" ]] && die 1 "Option --uninstall requires a value: all, a comma-separated list, or nothing."

  if [[ "$RESOLVED_BACKEND" == direct ]]; then
    local candidate
    while IFS= read -r candidate; do
      candidate=$(canonical_id "$candidate")
      [[ "$candidate" =~ ^[a-z0-9]+$ ]] || continue
      if [[ -f "$(direct_family_dir "$candidate")/.nerdfonts-manifest" ]]; then
        CACHED_INSTALLED_LIST+="${CACHED_INSTALLED_LIST:+$'\n'}$candidate"
      fi
    done <<<"$requested"
  fi
  uninstall_named_fonts "$requested" "$CACHED_INSTALLED_LIST"
  if has_failed_fonts; then
    die 4 "Some fonts failed to uninstall (${FAILED_FONTS[*]})."
  fi
}

# -----------------------------------------------------------------------------
# Main Entrypoint
# -----------------------------------------------------------------------------

main() {
  parse_args "$@"
  validate_arg_combination

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

main "$@"
