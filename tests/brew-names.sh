#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
cat >"$test_dir/brew" <<'EOF'
#!/usr/bin/env bash
case "$1" in
search) printf '%s\n' font-zed-mono-nerd-font font-fira-code-nerd-font font-hack-nerd-font ;;
*) exit 1 ;;
esac
EOF
chmod +x "$test_dir/brew"
export PATH="$test_dir:$PATH"
output=$(bash scripts/install.sh --backend brew --fonts zedmono,firacode,hack --dry-run --no-color)
for cask in font-zed-mono-nerd-font font-fira-code-nerd-font font-hack-nerd-font; do
  if ! grep -Fxq "[dry-run] Would install $cask." <<<"$output"; then
    printf 'FAIL: missing exact cask %s\n%s\n' "$cask" "$output" >&2
    exit 1
  fi
done
printf 'PASS: Homebrew cask names retain their original hyphens.\n'
