#!/usr/bin/env bash
# shellcheck shell=bash

###############################################################################
# Module:        scripts/lib/backends/direct.sh
# Description:   Direct-download backend (official ryanoasis/nerd-fonts
#                GitHub releases).
###############################################################################

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
  echo "[dry-run] Would download https://github.com/${GITHUB_REPO:-ryanoasis/nerd-fonts}/releases/latest/download/${asset} and extract to $(direct_font_dir)."
}

direct_dry_run_uninstall() {
  echo "[dry-run] Would remove font files matching '${1}' from $(direct_font_dir)."
}

direct_install_fonts() {
  local ids=("$@")
  local target_dir
  target_dir=$(direct_font_dir)
  mkdir -p "$target_dir"

  for id in "${ids[@]}"; do
    local asset
    asset=$(direct_id_to_asset "$id")
    local url="https://github.com/${GITHUB_REPO:-ryanoasis/nerd-fonts}/releases/latest/download/${asset}"

    echo "Installing ${id} (${asset})..."
    local tmp_archive
    tmp_archive=$(mktemp)

    local downloaded=0
    if command -v curl >/dev/null 2>&1; then
      curl -sL -o "$tmp_archive" "$url" && downloaded=1
    elif command -v wget >/dev/null 2>&1; then
      wget -qO "$tmp_archive" "$url" && downloaded=1
    fi

    if [[ "$downloaded" == 1 && -s "$tmp_archive" ]] && tar -xJf "$tmp_archive" -C "$target_dir" 2>/dev/null; then
      print_success "Successfully installed ${id}."
    else
      print_warn "Failed to install ${id}."
      FAILED_FONTS+=("$id")
    fi
    rm -f "$tmp_archive"
  done

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
