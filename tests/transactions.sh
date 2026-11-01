#!/usr/bin/env bash
# shellcheck source=tests/helpers.sh
source "$(dirname "$0")/helpers.sh"
mkdir -p "$TEST_TMP/fixture"
printf original >"$TEST_TMP/fixture/Regular.ttf"
printf bold >"$TEST_TMP/fixture/Bold.ttf"
tar -cJf "$TEST_TMP/archive" -C "$TEST_TMP/fixture" .
export TEST_ARCHIVE="$TEST_TMP/archive"
cat >"$TEST_TMP/bin/curl" <<'SH'
#!/usr/bin/env bash
while [[ $# -gt 0 ]]; do
  case "$1" in -o) dest=$2; shift 2 ;; *) shift ;; esac
done
cp "$TEST_ARCHIVE" "$dest"
SH
cat >"$TEST_TMP/bin/fc-cache" <<'SH'
#!/usr/bin/env bash
exit 0
SH
cat >"$TEST_TMP/bin/uname" <<'SH'
#!/usr/bin/env bash
echo Linux
SH
chmod +x "$TEST_TMP/bin/"*
run_installer --backend direct --fonts hack
assert_status 0
root="$XDG_DATA_HOME/fonts/NerdFonts"
rm "$root/hack/Bold.ttf"
export TEST_REAL_MV
TEST_REAL_MV=$(command -v mv)
cat >"$TEST_TMP/bin/mv" <<'SH'
#!/usr/bin/env bash
case "$1" in */.hack.stage.*/new) exit 1 ;; esac
exec "$TEST_REAL_MV" "$@"
SH
chmod +x "$TEST_TMP/bin/mv"
run_installer --backend direct --fonts hack
assert_status 4
[[ $(cat "$root/hack/Regular.ttf") == original ]]
[[ -f "$root/hack/.nerdfonts-manifest" ]]
[[ ! -d "$root/.hack.lock" ]]
rm "$TEST_TMP/bin/mv"
mkdir "$root/.hack.lock"
run_installer --backend direct --fonts hack
assert_status 4
[[ $(cat "$root/hack/Regular.ttf") == original ]]
rmdir "$root/.hack.lock"
# Failure to remove one tracked file preserves the ownership manifest.
cat >"$TEST_TMP/bin/rm" <<'SH'
#!/usr/bin/env bash
for arg in "$@"; do
  case "$arg" in */hack/Regular.ttf) exit 1 ;; esac
done
exec "$TEST_RM" "$@"
SH
export TEST_RM
chmod +x "$TEST_TMP/bin/rm"
run_installer --backend direct --uninstall hack
assert_status 4
[[ -f "$root/hack/.nerdfonts-manifest" ]]
[[ -f "$root/hack/Regular.ttf" ]]
printf 'PASS: rollback, family locking and removal failures\n'
