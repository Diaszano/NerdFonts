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
OPT_YES=0
OPT_BACKEND="auto"
OPT_VERSION=0
OPT_HELP=0
OPT_QUIET="${QUIET:-0}"
OPT_NO_COLOR=0
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
BACKEND_AUTO_ORDER=(brew pacman direct)
RESOLVED_BACKEND=""
DETECTED_OS=""
CACHED_FONT_LIST=""
CACHED_FONT_LIST_BACKEND=""
CACHED_INSTALLED_LIST=""
FAILED_FONTS=()

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
    Linux)  DETECTED_OS="linux" ;;
    *)      DETECTED_OS="unknown" ;;
  esac
}

probe_backend_catalog() {
  local name=$1
  local list=""
  if list=$("${name}_list_fonts" 2>/dev/null); then
    PROBE_RESULT="$list"
    CACHED_FONT_LIST="$list"
    CACHED_FONT_LIST_BACKEND="$name"
  else
    PROBE_RESULT=""
    CACHED_FONT_LIST=""
    CACHED_FONT_LIST_BACKEND=""
  fi
}

resolve_backend() {
  local requested=${1:-auto}
  detect_os

  if [[ "$requested" != "auto" ]]; then
    RESOLVED_BACKEND="$requested"
    if [[ "$requested" != "direct" ]] && ! "${requested}_is_available"; then
      print_warn "Backend '${requested}' is not available on this system."
    elif [[ "$requested" != "direct" ]]; then
      probe_backend_catalog "$requested"
      if [[ -z "$PROBE_RESULT" ]]; then
        print_warn "Backend '${requested}' reported no Nerd Fonts packages."
      fi
    fi
    backend_debug "backend=${RESOLVED_BACKEND}"
    return 0
  fi

  local candidate
  for candidate in "${BACKEND_AUTO_ORDER[@]}"; do
    "${candidate}_is_available" || continue
    backend_debug "probing candidate=${candidate}"
    probe_backend_catalog "$candidate"
    if [[ -n "$PROBE_RESULT" ]]; then
      RESOLVED_BACKEND="$candidate"
      backend_debug "backend=${RESOLVED_BACKEND}"
      return 0
    fi
  done

  if direct_is_available; then
    RESOLVED_BACKEND="direct"
    CACHED_FONT_LIST=""
    CACHED_FONT_LIST_BACKEND=""
    backend_debug "backend=${RESOLVED_BACKEND}"
    return 0
  fi

  die 2 "No supported installation backend found. Install one of: brew, pacman; or provide curl (or wget) plus tar for direct downloads."
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
  printf '%s' "$1" | tr -d ' ' | tr ',' '\n' | grep -v '^$'
}

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

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
    --all) OPT_ALL=1; shift ;;
    --fonts)
      [[ $# -lt 2 ]] && die 1 "Option --fonts requires an argument."
      OPT_FONTS=$2; shift 2 ;;
    --fonts=*) OPT_FONTS="${1#*=}"; shift ;;
    --list) OPT_LIST=1; shift ;;
    --installed) OPT_INSTALLED=1; shift ;;
    --uninstall)
      if [[ $# -ge 2 && "$2" != --* ]]; then
        OPT_UNINSTALL_MODE=$2; shift 2
      else
        OPT_UNINSTALL_MODE="interactive"; shift
      fi ;;
    --uninstall=*) OPT_UNINSTALL_MODE="${1#*=}"; shift ;;
    --backend)
      [[ $# -lt 2 ]] && die 1 "Option --backend requires an argument."
      OPT_BACKEND=$2; shift 2 ;;
    --backend=*) OPT_BACKEND="${1#*=}"; shift ;;
    -j | --jobs)
      [[ $# -lt 2 ]] && die 1 "Option --jobs requires an argument."
      if ! [[ "$2" =~ ^[1-9][0-9]*$ ]]; then
        die 1 "Option --jobs requires a positive integer."
      fi
      OPT_JOBS=$2; shift 2 ;;
    --jobs=*)
      local val="${1#*=}"
      if ! [[ "$val" =~ ^[1-9][0-9]*$ ]]; then
        die 1 "Option --jobs requires a positive integer."
      fi
      OPT_JOBS="$val"; shift ;;
    --dry-run) OPT_DRY_RUN=1; shift ;;
    --yes) OPT_YES=1; shift ;;
    --quiet) OPT_QUIET=1; shift ;;
    --no-color) OPT_NO_COLOR=1; disable_colors; shift ;;
    --version) OPT_VERSION=1; shift ;;
    -h | --help) OPT_HELP=1; shift ;;
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
  brew)
    command -v brew >/dev/null 2>&1 || die 2 "Homebrew não encontrado: https://brew.sh"
    ;;
  direct)
    (command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1) && command -v tar >/dev/null 2>&1 || \
      die 2 "O backend direct requer curl/wget e tar."
    ;;
  esac
}

# -----------------------------------------------------------------------------
# Backend: Homebrew
# -----------------------------------------------------------------------------

brew_is_available() { command -v brew >/dev/null 2>&1; }

brew_cask_to_id() {
  local id=$1
  id="${id#font-}"
  id="${id%-nerd-font}"
  id="${id//-/}"
  printf '%s' "$id"
}

brew_id_to_cask() {
  printf 'font-%s-nerd-font' "$1"
}

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
  done

  echo "Installing ${casks[*]}..."
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
  id="${id%-nerd-font}"
  id="${id%-nerd}"
  id="${id//-/}"
  printf '%s' "$id"
}

pacman_id_to_pkg() {
  printf 'ttf-%s-nerd' "$1"
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
  { command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1; } && command -v tar >/dev/null 2>&1
}

direct_font_dir() {
  if [[ "${DETECTED_OS:-}" == "macos" ]] || [[ "$(uname -s)" == "Darwin" ]]; then
    printf '%s' "${HOME}/Library/Fonts"
  else
    printf '%s' "${HOME}/.local/share/fonts"
  fi
}

direct_id_to_asset() {
  local id
  id=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -d '-')
  case "$id" in
    0xproto) printf '0xProto.tar.xz' ;;
    3270) printf '3270.tar.xz' ;;
    agave) printf 'Agave.tar.xz' ;;
    anonymouspro) printf 'AnonymousPro.tar.xz' ;;
    arimo) printf 'Arimo.tar.xz' ;;
    aurulentsansmono) printf 'AurulentSansMono.tar.xz' ;;
    bigblueterminal) printf 'BigBlueTerminal.tar.xz' ;;
    bitstreamverasansmono) printf 'BitstreamVeraSansMono.tar.xz' ;;
    cascadiacode) printf 'CascadiaCode.tar.xz' ;;
    cascadiamono) printf 'CascadiaMono.tar.xz' ;;
    codenewroman) printf 'CodeNewRoman.tar.xz' ;;
    comicshannsmono) printf 'ComicShannsMono.tar.xz' ;;
    cousine) printf 'Cousine.tar.xz' ;;
    daddytimemono) printf 'DaddyTimeMono.tar.xz' ;;
    dejavusansmono) printf 'DejaVuSansMono.tar.xz' ;;
    droidsansmono) printf 'DroidSansMono.tar.xz' ;;
    envycoder) printf 'EnvyCodeR.tar.xz' ;;
    fantasquesansmono) printf 'FantasqueSansMono.tar.xz' ;;
    firamono) printf 'FiraMono.tar.xz' ;;
    firacode) printf 'FiraCode.tar.xz' ;;
    geistmono) printf 'GeistMono.tar.xz' ;;
    gomono) printf 'Go-Mono.tar.xz' ;;
    gohufont) printf 'Gohu.tar.xz' ;;
    hack) printf 'Hack.tar.xz' ;;
    hasklig) printf 'Hasklig.tar.xz' ;;
    heavydata) printf 'HeavyData.tar.xz' ;;
    hermit) printf 'Hermit.tar.xz' ;;
    iawriter) printf 'iA-Writer.tar.xz' ;;
    inconsolata) printf 'Inconsolata.tar.xz' ;;
    inconsolatago) printf 'InconsolataGo.tar.xz' ;;
    inconsolatalgc) printf 'InconsolataLGC.tar.xz' ;;
    intefont) printf 'IntelOneMono.tar.xz' ;;
    iosevka) printf 'Iosevka.tar.xz' ;;
    iosevkaterm) printf 'IosevkaTerm.tar.xz' ;;
    jetbrainsmono) printf 'JetBrainsMono.tar.xz' ;;
    lekton) printf 'Lekton.tar.xz' ;;
    liberationmono) printf 'LiberationMono.tar.xz' ;;
    lilex) printf 'Lilex.tar.xz' ;;
    martianmono) printf 'MartianMono.tar.xz' ;;
    meslo) printf 'Meslo.tar.xz' ;;
    monaspace) printf 'Monaspace.tar.xz' ;;
    monofur) printf 'Monofur.tar.xz' ;;
    monoid) printf 'Monoid.tar.xz' ;;
    mononoki) printf 'Mononoki.tar.xz' ;;
    mplus) printf 'MPlus.tar.xz' ;;
    nerdfontssymbolsonly) printf 'NerdFontsSymbolsOnly.tar.xz' ;;
    noto) printf 'Noto.tar.xz' ;;
    opencodemonospace) printf 'OpenCodeMonospace.tar.xz' ;;
    overpass) printf 'Overpass.tar.xz' ;;
    profont) printf 'ProFont.tar.xz' ;;
    proggyclean) printf 'ProggyClean.tar.xz' ;;
    recursive) printf 'Recursive.tar.xz' ;;
    roboto) printf 'Roboto.tar.xz' ;;
    robotomono) printf 'RobotoMono.tar.xz' ;;
    sharetechmono) printf 'ShareTechMono.tar.xz' ;;
    sourcecodepro) printf 'SourceCodePro.tar.xz' ;;
    spacemono) printf 'SpaceMono.tar.xz' ;;
    terminess) printf 'Terminus.tar.xz' ;;
    tinos) printf 'Tinos.tar.xz' ;;
    ubuntu) printf 'Ubuntu.tar.xz' ;;
    ubuntumono) printf 'UbuntuMono.tar.xz' ;;
    ubuntusans) printf 'UbuntuSans.tar.xz' ;;
    victormono) printf 'VictorMono.tar.xz' ;;
    zedmono) printf 'ZedMono.tar.xz' ;;
    *)
      local cap
      cap="$(printf '%s' "${1:0:1}" | tr '[:lower:]' '[:upper:]')${1:1}"
      printf '%s.tar.xz' "$cap"
      ;;
  esac
}

DIRECT_KNOWN_FONTS="0xproto
3270
agave
anonymouspro
arimo
aurulentsansmono
bigblueterminal
bitstreamverasansmono
cascadiacode
cascadiamono
codenewroman
comicshannsmono
cousine
daddytimemono
dejavusansmono
droidsansmono
envycoder
fantasquesansmono
firacode
firamono
geistmono
gohufont
gomono
hack
hasklig
heavydata
hermit
iawriter
inconsolata
inconsolatago
inconsolatalgc
iosevka
iosevkaterm
jetbrainsmono
lekton
liberationmono
lilex
martianmono
meslo
monaspace
monofur
monoid
mononoki
mplus
nerdfontssymbolsonly
noto
overpass
profont
proggyclean
recursive
roboto
robotomono
sharetechmono
sourcecodepro
spacemono
terminess
tinos
ubuntu
ubuntumono
ubuntusans
victormono
zedmono"

direct_list_fonts() {
  printf '%s\n' "$DIRECT_KNOWN_FONTS"
}

direct_is_font_installed() {
  local target_dir
  target_dir=$(direct_font_dir)
  [[ -d "$target_dir" ]] || return 1
  local found
  found=$(find "$target_dir" -maxdepth 2 -iname "*$1*" 2>/dev/null | head -n 1)
  [[ -n "$found" ]]
}

direct_list_installed_fonts() {
  local target_dir
  target_dir=$(direct_font_dir)
  [[ -d "$target_dir" ]] || return 0
  local id
  while IFS= read -r id; do
    [[ -z "$id" ]] && continue
    if direct_is_font_installed "$id"; then
      printf '%s\n' "$id"
    fi
  done <<<"$DIRECT_KNOWN_FONTS"
}

direct_dry_run_install() {
  local asset
  asset=$(direct_id_to_asset "$1")
  echo "[dry-run] Would download https://github.com/${GITHUB_REPO}/releases/latest/download/${asset} and extract to $(direct_font_dir)."
}

direct_dry_run_uninstall() {
  echo "[dry-run] Would remove font files matching '${1}' from $(direct_font_dir)."
}

direct_install_single() {
  local id=$1
  local target_dir=$2
  local status_dir=$3
  local asset
  asset=$(direct_id_to_asset "$id")
  local url="https://github.com/${GITHUB_REPO}/releases/latest/download/${asset}"

  echo "Installing ${id} (${asset})..."
  local tmp_archive
  tmp_archive=$(mktemp)

  local downloaded=0
  if command -v curl >/dev/null 2>&1; then
    if curl -sL -o "$tmp_archive" "$url"; then
      downloaded=1
    fi
  elif command -v wget >/dev/null 2>&1; then
    if wget -qO "$tmp_archive" "$url"; then
      downloaded=1
    fi
  fi

  local extracted=0
  if [[ "$downloaded" == 1 && -s "$tmp_archive" ]]; then
    if tar -xJf "$tmp_archive" -C "$target_dir" 2>/dev/null; then
      extracted=1
    fi
  fi

  if [[ "$extracted" == 1 ]]; then
    print_success "Successfully installed ${id}."
    touch "${status_dir}/${id}.ok"
  else
    print_warn "Failed to install ${id}."
    touch "${status_dir}/${id}.fail"
  fi
  rm -f "$tmp_archive"
}

direct_install_fonts() {
  local ids=("$@")
  local target_dir
  target_dir=$(direct_font_dir)
  mkdir -p "$target_dir"

  local max_jobs="${OPT_JOBS:-4}"
  local status_dir
  status_dir=$(mktemp -d)

  for id in "${ids[@]}"; do
    direct_install_single "$id" "$target_dir" "$status_dir" &

    while [[ $(jobs -p | wc -l) -ge $max_jobs ]]; do
      sleep 0.1
    done
  done
  wait

  for id in "${ids[@]}"; do
    if [[ -f "${status_dir}/${id}.fail" ]] || [[ ! -f "${status_dir}/${id}.ok" ]]; then
      FAILED_FONTS+=("$id")
    fi
  done
  rm -rf "$status_dir"

  if command -v fc-cache >/dev/null 2>&1; then
    fc-cache -f "$target_dir" >/dev/null 2>&1 || true
  fi
}

direct_uninstall_fonts() {
  local ids=("$@")
  local target_dir
  target_dir=$(direct_font_dir)
  [[ -d "$target_dir" ]] || return 0

  for id in "${ids[@]}"; do
    local files
    files=$(find "$target_dir" -maxdepth 2 -iname "*$id*" 2>/dev/null)
    if [[ -n "$files" ]]; then
      echo "$files" | xargs rm -f
      print_success "Successfully uninstalled ${id}."
    else
      print_warn "'${id}' is not installed."
    fi
  done

  if command -v fc-cache >/dev/null 2>&1; then
    fc-cache -f "$target_dir" >/dev/null 2>&1 || true
  fi
}

# -----------------------------------------------------------------------------
# Font Management & Dispatch Core
# -----------------------------------------------------------------------------

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
    if list_contains "$font" "$target_list"; then
      matched+="${matched:+$'\n'}${font}"
    else
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
