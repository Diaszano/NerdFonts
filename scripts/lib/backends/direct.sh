#!/usr/bin/env bash
# shellcheck shell=bash

###############################################################################
# Module:        scripts/lib/backends/direct.sh
# Description:   Direct-download backend (official ryanoasis/nerd-fonts
#                GitHub releases).
#
# Contract (see scripts/lib/platform.sh and fonts.sh dispatchers):
#   - direct_is_available            -> 0 when (curl or wget) and tar exist.
#   - direct_list_fonts              -> canonical ids on stdout.
#   - direct_is_font_installed <id>  -> 0/1.
#   - direct_install_fonts <id>...   -> batched parallel downloads; failures
#                                       are appended to FAILED_FONTS; ret 0.
#   - direct_uninstall_fonts <id>... -> idem.
#   - direct_list_installed_fonts    -> ids tracked by install markers.
#
# Manifest handling:
#   - Source: GET https://api.github.com/repos/ryanoasis/nerd-fonts/releases/
#     latest (jq parsing preferred, grep/sed fallback).
#   - An "Authorization: token ..." header is sent when GITHUB_TOKEN is set
#     (raises the GitHub API rate limit).
#   - The raw JSON is cached in ${XDG_CACHE_HOME:-$HOME/.cache}/
#     nerdfonts-installer/manifest.cache with a 24h TTL (override through
#     DIRECT_CACHE_TTL_HOURS; bypass with DIRECT_NO_CACHE=1). A stale cache
#     is reused (with a warning) when a refresh fails.
#
# Canonical ids:
#   Asset basename without the .tar.xz extension, lowercased
#   (JetBrainsMono.tar.xz -> jetbrainsmono).
#
# Installation:
#   - Archives are downloaded in parallel (xargs -P ${DIRECT_JOBS:-4}) into a
#     temporary directory, extracted with tar -xJf, and *.ttf/*.otf files are
#     copied to ~/.local/share/fonts (Linux) or ~/Library/Fonts (macOS).
#   - fc-cache -f runs once after installs/uninstalls when available (Linux).
#   - A success marker is written to $CACHE_DIR/installed/<id>; detection also
#     accepts pre-existing "<id>*NerdFont*" font files in the target dir.
###############################################################################

# -----------------------------------------------------------------------------
# Availability
# -----------------------------------------------------------------------------

direct_is_available() {
  if ! { command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1; }; then
    return 1
  fi
  command -v tar >/dev/null 2>&1
}

# -----------------------------------------------------------------------------
# HTTP helper
# -----------------------------------------------------------------------------

# __nf_http_get downloads $1 into $2 using curl (preferred) or wget, sending
# an Authorization header when GITHUB_TOKEN is set.
#
# Arguments:
#   $1 - URL.
#   $2 - Destination file.
#
# Returns:
#   The underlying tool exit status.
__nf_http_get() {
  local url=$1
  local dest=$2

  if command -v curl >/dev/null 2>&1; then
    if [[ -n "${GITHUB_TOKEN:-}" ]]; then
      curl -fsSL -H "Authorization: token ${GITHUB_TOKEN}" -o "$dest" "$url"
    else
      curl -fsSL -o "$dest" "$url"
    fi
  elif command -v wget >/dev/null 2>&1; then
    if [[ -n "${GITHUB_TOKEN:-}" ]]; then
      wget -q --header="Authorization: token ${GITHUB_TOKEN}" -O "$dest" "$url"
    else
      wget -q -O "$dest" "$url"
    fi
  else
    return 127
  fi
}

# -----------------------------------------------------------------------------
# Manifest
# -----------------------------------------------------------------------------

# direct_manifest_cache_file prints the manifest cache path.
direct_manifest_cache_file() {
  printf '%s' "${CACHE_DIR}/manifest.cache"
}

# direct_refresh_manifest fetches the latest release JSON and rewrites the
# cache atomically. No die here: callers decide how to handle failures.
#
# Output (globals):
#   DIRECT_TAG - Release tag name (e.g., v3.2.1).
#
# Returns:
#   0 on success, 1 on any network/parsing failure.
direct_refresh_manifest() {
  local cache
  cache=$(direct_manifest_cache_file)
  local tmp_json
  tmp_json=$(mktemp 2>/dev/null) || return 1
  local tag=""
  local urls=""
  local tmp_cache

  if ! __nf_http_get "${GITHUB_RELEASE_API}" "$tmp_json"; then
    rm -f "$tmp_json"
    return 1
  fi

  if command -v jq >/dev/null 2>&1; then
    tag=$(jq -r '.tag_name // empty' "$tmp_json" 2>/dev/null)
    urls=$(jq -r '.assets[].browser_download_url' "$tmp_json" 2>/dev/null |
      grep '\.tar\.xz$') || urls=""
  else
    tag=$(grep -m1 '"tag_name"' "$tmp_json" 2>/dev/null |
      sed 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/') || tag=""
    urls=$(grep -o '"browser_download_url":[[:space:]]*"[^"]*\.tar\.xz"' "$tmp_json" 2>/dev/null |
      sed 's/.*"\(https[^"]*\)".*/\1/') || urls=""
  fi

  if [[ -z "$tag" || -z "$urls" ]]; then
    rm -f "$tmp_json"
    return 1
  fi

  DIRECT_TAG="$tag"

  mkdir -p "${CACHE_DIR}" || {
    rm -f "$tmp_json"
    return 1
  }
  tmp_cache=$(mktemp "${CACHE_DIR}/manifest.XXXXXX" 2>/dev/null) || {
    rm -f "$tmp_json"
    return 1
  }

  {
    printf '#META|%s|%s\n' "$(date +%s)" "$tag"
    printf '%s\n' "$urls"
  } >"$tmp_cache" && mv -f "$tmp_cache" "$cache"

  rm -f "$tmp_json"
  return 0
}

# direct_load_manifest loads DIRECT_TAG plus the DIRECT_FONT_MAP
# (id -> asset file name), refreshing the cache when missing or expired. A
# failing refresh falls back to a stale cache (warning); without any usable
# manifest it dies with exit code 2 suggesting GITHUB_TOKEN.
direct_load_manifest() {
  local cache
  cache=$(direct_manifest_cache_file)

  DIRECT_FONT_MAP=""

  local meta=""
  local ts=0
  local now
  local no_cache="${DIRECT_NO_CACHE:-0}"
  local ttl_seconds=$((DIRECT_CACHE_TTL_HOURS * 3600))

  if [[ "$no_cache" != "1" && -f "$cache" ]]; then
    meta=$(head -n 1 "$cache")
    ts=${meta#*|}
    ts=${ts%%|*}
    case $ts in
    '' | *[!0-9]*) ts=0 ;;
    esac
    now=$(date +%s)
    # ">=" so that DIRECT_CACHE_TTL_HOURS=0 means "always expired".
    if ((now - ts >= ttl_seconds)); then
      meta=""
    fi
  fi

  if [[ -z "$meta" ]]; then
    if ! direct_refresh_manifest; then
      if [[ "$no_cache" != "1" && -f "$cache" ]]; then
        # >&2 is required here: list functions run under stdout redirection
        # (their stdout IS the returned catalog) and must keep it pure.
        print_warn "Could not refresh the Nerd Fonts release manifest. Using the stale cached copy." >&2
      else
        die 2 "Failed to download the Nerd Fonts release manifest from GitHub.
If this persists you may be rate-limited (HTTP 403). Set a GITHUB_TOKEN environment variable and retry."
      fi
    fi
  fi

  # Rebuild state from the (fresh or stale) cache.
  local body
  body=$(tail -n +2 "$cache" 2>/dev/null) || body=""

  DIRECT_TAG=$(head -n 1 "$cache" | awk -F'|' '{ print $3 }')
  DIRECT_FONT_MAP=""

  local url
  local asset
  local base
  local id
  while IFS= read -r url; do
    [[ -z "$url" ]] && continue
    asset=${url##*/}
    base=${asset%.tar.xz}
    id=$(to_lowercase "$base")
    [[ -z "$id" ]] && continue
    map_set DIRECT_FONT_MAP "$id" "$asset"
  done <<<"$body"
}

# -----------------------------------------------------------------------------
# Id <-> native resource mapping / catalog
# -----------------------------------------------------------------------------

# direct_id_to_asset maps a canonical id to its release asset file name.
#
# Arguments:
#   $1 - Canonical font id.
#
# Output:
#   The asset file name (e.g., Hack.tar.xz).
direct_id_to_asset() {
  local id=$1
  local asset=""
  asset=$(map_get DIRECT_FONT_MAP "$id") || asset="${id}.tar.xz"
  printf '%s' "$asset"
}

# direct_asset_download_url prints the browser download URL for an asset.
#
# Arguments:
#   $1 - Asset file name.
direct_asset_download_url() {
  printf '%s' "https://github.com/${GITHUB_REPO}/releases/download/${DIRECT_TAG}/$1"
}

# direct_list_fonts prints every font available in the latest release as
# canonical ids (one per line, sorted), filling DIRECT_FONT_MAP/DIRECT_TAG.
direct_list_fonts() {
  direct_load_manifest

  local entry
  local id
  local id_list=""
  while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue
    id=${entry%%|*}
    id_list+="${id_list:+$'\n'}${id}"
  done <<<"$DIRECT_FONT_MAP"

  [[ -z "$id_list" ]] && return 0
  printf '%s\n' "$id_list" | sort
}

# direct_list_installed_fonts prints the canonical ids recorded by the
# install markers (one per line). Always succeeds.
direct_list_installed_fonts() {
  local marker_dir="${CACHE_DIR}/installed"
  [[ -d "$marker_dir" ]] || return 0

  local marker
  for marker in "$marker_dir"/*; do
    [[ -e "$marker" ]] || continue
    printf '%s\n' "${marker##*/}"
  done
}

# -----------------------------------------------------------------------------
# Installation state / batch operations
# -----------------------------------------------------------------------------

# direct_font_dir prints the user font installation directory.
direct_font_dir() {
  if [[ "$DETECTED_OS" == "macos" ]]; then
    printf '%s' "${HOME}/Library/Fonts"
  else
    printf '%s' "${HOME}/.local/share/fonts"
  fi
}

# direct_font_files iterates over the user font directory, yielding every
# file whose lowercased name matches "<id>*nerdfont*" (case-insensitive to
# cope with the mixed-case release asset names).
#
# Arguments:
#   $1 - Canonical font id.
#
# Output:
#   Matching file paths (possibly none).
direct_font_files() {
  local id=$1
  local dir
  dir=$(direct_font_dir)
  [[ -d "$dir" ]] || return 0

  local f
  local base
  for f in "$dir"/*; do
    [[ -e "$f" ]] || continue
    base=$(to_lowercase "${f##*/}")
    case $base in
    ${id}*nerdfont*) printf '%s\n' "$f" ;;
    esac
  done
}

# direct_has_font_files checks whether "<id>*nerdfont*" files (case
# insensitive) exist in the user font directory; covers fonts managed
# outside this installer.
#
# Arguments:
#   $1 - Canonical font id.
direct_has_font_files() {
  local match
  match=$(direct_font_files "$1")
  [[ -n "$match" ]]
}

direct_is_font_installed() {
  [[ -f "${CACHE_DIR}/installed/$1" ]] && return 0
  direct_has_font_files "$1"
}

# direct_dry_run_install dry-run line with the full download URL. Loads the
# manifest itself because the dispatcher invokes it without prior setup.
direct_dry_run_install() {
  direct_load_manifest
  echo "[dry-run] Would download $(direct_asset_download_url "$(direct_id_to_asset "$1")")."
}

# direct_fetch_pair downloads one "url|destination" pair (xargs worker).
#
# Arguments:
#   $1 - "url|destination-file" pair.
direct_fetch_pair() {
  local pair=$1
  __nf_http_get "${pair%%|*}" "${pair#*|}"
}

# direct_extract_archive extracts $1 (.tar.xz) into $2 and copies *.ttf /
# *.otf files to the user font directory.
#
# Returns:
#   0 on success, 1 on tar/copy failure.
direct_extract_archive() {
  local archive=$1
  local extract_dir=$2
  local font_dir
  font_dir=$(direct_font_dir)
  local f
  local copied=0

  mkdir -p "$extract_dir" "$font_dir" || return 1
  tar -xJf "$archive" -C "$extract_dir" || return 1

  for f in "$extract_dir"/*.ttf "$extract_dir"/*.otf; do
    [[ -e "$f" ]] || continue
    cp -f "$f" "$font_dir/" || return 1
    copied=1
  done

  [[ "$copied" == 1 ]]
}

# direct_refresh_font_cache runs fc-cache once, when available (Linux only).
direct_refresh_font_cache() {
  if [[ "$DETECTED_OS" == "linux" ]] && command -v fc-cache >/dev/null 2>&1; then
    fc-cache -f >/dev/null 2>&1
  fi
}

# direct_install_fonts installs every given id from the official releases:
# parallel downloads (xargs -P), sequential extraction, single fc-cache.
#
# Arguments:
#   $@ - Canonical font ids.
direct_install_fonts() {
  local ids=("$@")
  local jobs=${DIRECT_JOBS:-4}
  case $jobs in
  '' | *[!0-9]*) jobs=4 ;;
  esac
  ((jobs < 1)) && jobs=1

  direct_load_manifest

  if [[ "$OPT_DRY_RUN" == 1 ]]; then
    local id
    for id in "${ids[@]}"; do
      direct_dry_run_install "$id"
    done
    return 0
  fi

  local pending_ids=()
  local pending_assets=()
  local id
  local asset
  for id in "${ids[@]}"; do
    asset=$(direct_id_to_asset "$id")
    pending_ids+=("$id")
    pending_assets+=("$asset")
  done
  [[ ${#pending_ids[@]} -eq 0 ]] && return 0

  local tmpdir
  tmpdir=$(mktemp -d) || {
    FAILED_FONTS+=("${pending_ids[@]}")
    return 0
  }

  # Parallel downloads: each xargs job receives one "url|output" pair.
  local pairs=()
  local i
  for i in ${!pending_assets[*]}; do
    pairs+=("$(direct_asset_download_url "${pending_assets[$i]}")|${tmpdir}/${pending_assets[$i]}")
  done
  export -f direct_fetch_pair __nf_http_get
  printf '%s\n' "${pairs[@]}" |
    xargs -P "$jobs" -I{} bash -c 'direct_fetch_pair "$@"' _ {}

  local succeeded_ids=()
  for i in ${!pending_ids[*]}; do
    id=${pending_ids[$i]}
    asset=${pending_assets[$i]}
    if [[ -f "${tmpdir}/${asset}" ]] &&
      direct_extract_archive "${tmpdir}/${asset}" "${tmpdir}/extract-${id}"; then
      mkdir -p "${CACHE_DIR}/installed"
      touch "${CACHE_DIR}/installed/${id}"
      print_success "Successfully installed ${id}."
      succeeded_ids+=("$id")
    else
      print_warn "Failed to install ${id}."
      FAILED_FONTS+=("$id")
    fi
  done

  rm -rf "$tmpdir"

  if [[ ${#succeeded_ids[@]} -gt 0 ]]; then
    direct_refresh_font_cache
  fi
}

# direct_uninstall_fonts removes every given id's font files, markers and
# refreshes the font cache once at the end.
#
# Arguments:
#   $@ - Canonical font ids.
direct_uninstall_fonts() {
  local ids=("$@")
  local id
  local f
  local removed_any=0
  local removed=0

  for id in "${ids[@]}"; do
    removed=0
    while IFS= read -r f; do
      [[ -n "$f" ]] || continue
      rm -f "$f" && removed=1
    done <<<"$(direct_font_files "$id")"
    if [[ -f "${CACHE_DIR}/installed/${id}" ]]; then
      rm -f "${CACHE_DIR}/installed/${id}"
      removed=1
    fi
    if [[ "$removed" == 1 ]]; then
      print_success "Successfully uninstalled ${id}."
      removed_any=1
    fi
  done

  if [[ "$removed_any" == 1 ]]; then
    direct_refresh_font_cache
  fi
}
