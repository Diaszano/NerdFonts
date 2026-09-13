#!/usr/bin/env bash
# shellcheck shell=bash

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
