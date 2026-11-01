#!/usr/bin/env bash
# shellcheck source=tests/helpers.sh
source "$(dirname "$0")/helpers.sh"
cat >"$TEST_TMP/bin/uname" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${TEST_OS:-Linux}"
SH
cat >"$TEST_TMP/bin/brew" <<'SH'
#!/usr/bin/env bash
case "$1" in
search) echo font-hack-nerd-font ;;
*) exit 1 ;;
esac
SH
chmod +x "$TEST_TMP/bin/"*
export NF_DEBUG_BACKEND=1
run_installer --list
assert_status 0
assert_contains 'backend=direct'
export TEST_OS=Darwin
run_installer --list
assert_status 0
assert_contains 'backend=brew'
export TEST_OS=Unknown
run_installer --list
assert_status 2
printf 'PASS: automatic platform selection\n'
unset TEST_OS
export TEST_CALLS="$TEST_TMP/calls"
cat >"$TEST_TMP/bin/brew" <<'SH'
#!/usr/bin/env bash
case "$1" in
search)
  echo search >> "$TEST_CALLS"
  [[ "${SEARCH_FAIL:-0}" == 0 ]] || exit 1
  printf '%s\n' font-sauce-code-pro-nerd-font font-zed-mono-nerd-font ;;
list) printf '%s\n' font-zed-mono-nerd-font ;;
uninstall) [[ "$3" == font-zed-mono-nerd-font ]] ;;
*) exit 1 ;;
esac
SH
run_installer --backend brew --fonts sourcecodepro,zedmono --dry-run
assert_status 0
assert_contains 'font-sauce-code-pro-nerd-font'
[[ $(wc -l <"$TEST_CALLS") == 1 ]]
export SEARCH_FAIL=1
run_installer --backend brew --uninstall zedmono
assert_status 0
printf 'PASS: cached catalog and offline uninstall\n'
# Pacman inventory must exclude unrelated packages and preserve exact names.
cat >"$TEST_TMP/bin/pacman" <<'SH'
#!/usr/bin/env bash
case "$1" in
-Qq) printf '%s\n' nerdctl ttf-fira-code-nerd ttf-hack-nerd ;;
-Sgq) printf '%s\n' ttf-fira-code-nerd ttf-hack-nerd ;;
-Qi) exit 1 ;;
*) exit 0 ;;
esac
SH
chmod +x "$TEST_TMP/bin/pacman"
run_installer --backend pacman --installed
assert_status 0
assert_absent nerdctl
assert_contains firacode
run_installer --backend pacman --fonts firacode --dry-run
assert_status 0
assert_contains ttf-fira-code-nerd
printf 'PASS: Pacman exact names and inventory filtering\n'
