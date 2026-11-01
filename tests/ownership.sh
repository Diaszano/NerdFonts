#!/usr/bin/env bash
# shellcheck source=tests/helpers.sh
source "$(dirname "$0")/helpers.sh"
mkdir -p "$TEST_TMP/fixture"
printf font >"$TEST_TMP/fixture/Hack.ttf"
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
root="$XDG_DATA_HOME/fonts/NerdFonts"
for kind in link fifo; do
  run_installer --backend direct --fonts hack
  assert_status 0
  if [[ "$kind" == link ]]; then ln -s "$TEST_TMP/outside" "$root/hack/unknown"; else mkfifo "$root/hack/unknown"; fi
  rm "$root/hack/Hack.ttf"
  run_installer --backend direct --fonts hack
  assert_status 4
  [[ -L "$root/hack/unknown" || -p "$root/hack/unknown" ]]
  rm "$root/hack/unknown"
  run_installer --backend direct --uninstall hack
  assert_status 0
done
printf 'PASS: repair preserves untracked links and special files\n'
# Absolute paths must be rejected before tar extracts any content.
tar -cJf "$TEST_TMP/archive" -P "$TEST_TMP/fixture/Hack.ttf"
run_installer --backend direct --fonts firacode
assert_status 4
[[ ! -e "$root/firacode/.nerdfonts-manifest" ]]
# A hard link in the archive is also disallowed.
ln "$TEST_TMP/fixture/Hack.ttf" "$TEST_TMP/fixture/Hard.ttf"
tar -cJf "$TEST_TMP/archive" -C "$TEST_TMP/fixture" .
run_installer --backend direct --fonts firacode
assert_status 4
[[ ! -e "$root/firacode/.nerdfonts-manifest" ]]
rm "$TEST_TMP/fixture/Hard.ttf"
printf malformed >"$TEST_TMP/fixture/"$'Tab\tName.ttf'
tar -cJf "$TEST_TMP/archive" -C "$TEST_TMP/fixture" .
run_installer --backend direct --fonts firacode
assert_status 4
[[ ! -e "$root/firacode/.nerdfonts-manifest" ]]
printf 'PASS: absolute paths, hard links and malformed names rejected\n'
