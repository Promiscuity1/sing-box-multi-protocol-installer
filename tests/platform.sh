#!/bin/sh
set -eu

REPO_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
VERSION=manager-test

. "$REPO_DIR/lib/output.sh"
. "$REPO_DIR/lib/platform.sh"

detect_platform
[ "$VERSION" = manager-test ] || {
  printf 'platform detection overwrote manager VERSION: %s\n' "$VERSION" >&2
  exit 1
}
case "$SB_PLATFORM" in
  alpine|systemd) ;;
  *) printf 'unexpected platform: %s\n' "$SB_PLATFORM" >&2; exit 1 ;;
esac

printf 'Platform detection test passed.\n'