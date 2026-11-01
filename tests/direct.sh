#!/usr/bin/env bash
# shellcheck source=tests/helpers.sh
source "$(dirname "$0")/helpers.sh"
mkdir -p "$TEST_TMP/fixture/nested"
printf font >"$TEST_TMP/fixture/nested/Ubuntu Mono.ttf"
printf license >"$TEST_TMP/fixture/LICENSE"
tar -cJf "$TEST_TMP/font.tar.xz" -C "$TEST_TMP/fixture" .
export TEST_ARCHIVE="$TEST_TMP/font.tar.xz"
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
run_installer --backend direct --fonts ubuntu,ubuntumono
assert_status 0
root="$XDG_DATA_HOME/fonts/NerdFonts"
[[ -f "$root/ubuntu/nested/Ubuntu Mono.ttf" ]] || {
  echo 'FAIL: missing isolated installation'
  exit 1
}
[[ -f "$root/ubuntu/.nerdfonts-manifest" ]]
[[ ! -f "$root/ubuntu/LICENSE" ]]
run_installer --backend direct --installed
assert_status 0
assert_contains ubuntu
assert_contains ubuntumono
run_installer --backend direct --fonts ubuntu
assert_status 0
assert_contains 'already installed'
run_installer --backend direct --uninstall ubuntu --dry-run
assert_status 0
[[ -f "$root/ubuntu/nested/Ubuntu Mono.ttf" ]]
printf external >"$XDG_DATA_HOME/fonts/UbuntuExternal.ttf"
run_installer --backend direct --uninstall ubuntu
assert_status 0
[[ ! -e "$root/ubuntu/.nerdfonts-manifest" ]]
[[ -f "$root/ubuntumono/nested/Ubuntu Mono.ttf" ]]
[[ -f "$XDG_DATA_HOME/fonts/UbuntuExternal.ttf" ]]
# Reject tampered manifests before deleting anything.
printf 'file\t../../UbuntuExternal.ttf\n' >>"$root/ubuntumono/.nerdfonts-manifest"
run_installer --backend direct --uninstall ubuntumono
assert_status 4
[[ -f "$root/ubuntumono/nested/Ubuntu Mono.ttf" ]]
[[ -f "$XDG_DATA_HOME/fonts/UbuntuExternal.ttf" ]]
# Links in archives are rejected before extraction/publication.
ln -s /tmp "$TEST_TMP/fixture/link"
tar -cJf "$TEST_TMP/font.tar.xz" -C "$TEST_TMP/fixture" .
run_installer --backend direct --fonts hack
assert_status 4
[[ ! -e "$root/hack/.nerdfonts-manifest" ]]
printf 'PASS: direct install, inventory and safe uninstall\n'
# Restore a valid archive for further transactions.
rm "$TEST_TMP/fixture/link"
tar -cJf "$TEST_TMP/font.tar.xz" -C "$TEST_TMP/fixture" .
run_installer --backend direct --fonts firacode
assert_status 0
printf sentinel >"$root/firacode/untracked.txt"
# Missing tracked files trigger repair, but unknown files must block replacement.
rm "$root/firacode/nested/Ubuntu Mono.ttf"
run_installer --backend direct --fonts firacode
assert_status 4
[[ $(cat "$root/firacode/untracked.txt") == sentinel ]]
rm "$root/firacode/untracked.txt"
run_installer --backend direct --fonts firacode
assert_status 0
[[ -f "$root/firacode/nested/Ubuntu Mono.ttf" ]]
run_installer --backend direct --fonts sourcecodepro --jobs 1
assert_status 0
# Empty archives must not publish success.
mkdir "$TEST_TMP/empty"
tar -cJf "$TEST_TMP/font.tar.xz" -C "$TEST_TMP/empty" .
run_installer --backend direct --fonts geistmono
assert_status 4
[[ ! -e "$root/geistmono/.nerdfonts-manifest" ]]
# Unknown files survive removal of a managed family.
printf sentinel >"$root/firacode/untracked.txt"
run_installer --backend direct --uninstall firacode
assert_status 0
[[ -f "$root/firacode/untracked.txt" ]]
[[ ! -f "$root/firacode/nested/Ubuntu Mono.ttf" ]]
printf 'PASS: incomplete installations, empty archives and untracked files\n'
