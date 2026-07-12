#!/bin/sh

set -eu

REPO_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TEST_ROOT=$(mktemp -d /tmp/sb-lock-test.XXXXXX)
trap 'rm -rf "$TEST_ROOT"' EXIT HUP INT TERM

cat >"$TEST_ROOT/rc-service" <<'EOF'
#!/bin/sh
[ ! -e /proc/$$/fd/9 ] || {
  printf 'service command inherited lock fd 9\n' >&2
  exit 1
}
EOF
chmod +x "$TEST_ROOT/rc-service"

PATH="$TEST_ROOT:$PATH"
SB_HOME=$TEST_ROOT/home
SB_LOCK_FILE=$TEST_ROOT/sb-manager.lock
export PATH SB_HOME SB_LOCK_FILE

# shellcheck source=lib/common.sh
. "$REPO_DIR/lib/common.sh"
# shellcheck source=lib/platform.sh
. "$REPO_DIR/lib/platform.sh"

SB_PLATFORM=alpine
acquire_lock
service_restart

printf 'Lock descriptor inheritance test passed.\n'