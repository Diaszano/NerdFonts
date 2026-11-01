#!/usr/bin/env bash
# Optional network test. Never points the installer at the user's real fonts.
set -euo pipefail
repo_root=$(cd "$(dirname "$0")/.." && pwd)
test_home=$(mktemp -d)
trap 'rm -rf "$test_home"' EXIT
export HOME="$test_home"
export XDG_DATA_HOME="$test_home/data"
export NO_COLOR=1
case "$(uname -s)" in
  Darwin) font_root="$HOME/Library/Fonts" ;;
  Linux) font_root="$XDG_DATA_HOME/fonts" ;;
  *)
    echo 'Unsupported integration host' >&2
    exit 2
    ;;
esac
mkdir -p "$font_root"
printf sentinel >"$font_root/external.ttf"
bash "$repo_root/scripts/install.sh" --backend direct --fonts heavydata
[[ -f "$font_root/NerdFonts/heavydata/.nerdfonts-manifest" ]]
bash "$repo_root/scripts/install.sh" --backend direct --installed | grep -Fx heavydata
bash "$repo_root/scripts/install.sh" --backend direct --fonts heavydata
bash "$repo_root/scripts/install.sh" --backend direct --uninstall heavydata
[[ ! -e "$font_root/NerdFonts/heavydata/.nerdfonts-manifest" ]]
[[ $(cat "$font_root/external.ttf") == sentinel ]]
echo 'PASS: real direct installation, inventory, repeat install and removal'
