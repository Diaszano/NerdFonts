#!/usr/bin/env bash
# shellcheck shell=bash

###############################################################################
# Script:        scripts/build.sh
# Description:   Builds the self-contained installer bundle (dist/install.sh)
#                by concatenating the scripts/lib/*.sh modules in a fixed order.
#
# Usage:
#   ./scripts/build.sh
#
# Output:
#   dist/install.sh - executable single-file installer bundle embedding:
#     constants.sh -> util.sh -> log.sh -> cli.sh -> platform.sh ->
#     deps.sh -> fonts.sh -> backends/{brew,pacman,direct}.sh -> main.sh
#
# Notes:
#   - Requires only bash, git and coreutils.
#   - The bundle version comes from `git describe --tags --always`.
#   - The build is idempotent: dist/ is recreated from scratch on each run.
###############################################################################

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

BUNDLE_DIR="$SCRIPT_DIR/../dist"
BUNDLE_FILE="$BUNDLE_DIR/install.sh"

VERSION=$(git -C "$SCRIPT_DIR" describe --tags --always 2>/dev/null || echo dev)

rm -rf "$BUNDLE_DIR"
mkdir -p "$BUNDLE_DIR"

{
  cat <<EOF
#!/usr/bin/env bash
# shellcheck shell=bash

###############################################################################
# Generated file - DO NOT EDIT DIRECTLY.
# Source:        scripts/build.sh
# Description:   Self-contained Nerd Fonts installer bundle.
#
# Rebuild with:
#   make build  (or: scripts/build.sh)
#
# Version:       $VERSION
###############################################################################

# Marker read by scripts/install.sh to detect the bundled mode.
# shellcheck disable=SC2034
NERDFONTS_BUNDLED=1
# Installer version injected from git (informational, consumed downstream).
# shellcheck disable=SC2034
INSTALLER_VERSION="$VERSION"

set -euo pipefail
IFS=\$'\n\t'

EOF
} >"$BUNDLE_FILE"

# Sourcing order must match scripts/install.sh.
for module in \
  lib/constants.sh \
  lib/util.sh \
  lib/log.sh \
  lib/cli.sh \
  lib/platform.sh \
  lib/deps.sh \
  lib/fonts.sh \
  lib/backends/brew.sh \
  lib/backends/pacman.sh \
  lib/backends/direct.sh \
  lib/main.sh; do
  cat "$SCRIPT_DIR/$module" >>"$BUNDLE_FILE"
  printf '\n' >>"$BUNDLE_FILE"
done

printf 'main "$@"\n' >>"$BUNDLE_FILE"

chmod +x "$BUNDLE_FILE"

echo "[build] Bundle created: $(basename "$BUNDLE_FILE") (version: $VERSION)"
