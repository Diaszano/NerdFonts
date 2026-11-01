#!/usr/bin/env bash
# shellcheck source=tests/helpers.sh
source "$(dirname "$0")/helpers.sh"
mkdir "$TEST_TMP/project" "$TEST_TMP/tools"
cp "$TEST_ROOT/Makefile" "$TEST_TMP/project/Makefile"
# A minimal PATH avoids accidentally invoking the host's actual Homebrew.
for tool in bash mktemp rm uname cat; do
  ln -s "$(command -v "$tool")" "$TEST_TMP/tools/$tool"
done
cat >"$TEST_TMP/tools/curl" <<'SH'
#!/usr/bin/env bash
exit 7
SH
chmod +x "$TEST_TMP/tools/curl"
STATUS=0
OUTPUT=$(PATH="$TEST_TMP/tools" /usr/bin/make -C "$TEST_TMP/project" brew-install 2>&1) || STATUS=$?
[[ "$STATUS" != 0 ]] || {
  echo 'FAIL: bootstrap masked curl failure'
  exit 1
}
assert_absent 'script executed'
cat >"$TEST_TMP/tools/curl" <<'SH'
#!/usr/bin/env bash
while [[ $# -gt 0 ]]; do
  case "$1" in -o) dest=$2; shift 2 ;; *) shift ;; esac
done
printf 'exit 17\n' > "$dest"
SH
STATUS=0
OUTPUT=$(PATH="$TEST_TMP/tools" /usr/bin/make -C "$TEST_TMP/project" brew-install 2>&1) || STATUS=$?
[[ "$STATUS" != 0 ]]
assert_absent 'successfully'
printf 'PASS: Makefile propagates bootstrap errors\n'
