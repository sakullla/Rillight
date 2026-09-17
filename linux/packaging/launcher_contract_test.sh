#!/usr/bin/env bash
# Runs with a POSIX shell and no Flutter/GTK installation. GUI command is fake;
# desktop_smoke.sh separately exercises real gtk-launch/Zenity on Ubuntu CI.
set -euo pipefail
source_dir="$(cd "$(dirname "$0")" && pwd)"
fixture=$(mktemp -d /tmp/rillight-launcher-contract.XXXXXX)
cleanup() {
  case "$fixture" in /tmp/rillight-launcher-contract.*) rm -rf -- "$fixture";; *) exit 2;; esac
}
trap cleanup EXIT
mkdir -p "$fixture/app/lib" "$fixture/bin"
cp "$source_dir/rillight-launch" "$fixture/app/rillight-launch"
cat > "$fixture/app/rillight" <<'APP'
#!/bin/sh
printf '%s\n' "$@" > "$RILLIGHT_LAUNCH_MARKER"
APP
cat > "$fixture/bin/ldd" <<'LDD'
#!/bin/sh
[ -z "${LD_LIBRARY_PATH:-}" ] || exit 8
case "$1" in */libmpv.so.1) echo 'libold.so.8 => not found'; exit 1;; esac
if [ "${RILLIGHT_TEST_MISSING:-0}" = 1 ]; then echo 'libmissing.so.9 => not found'; fi
exit 0
LDD
cat > "$fixture/bin/zenity" <<'DIALOG'
#!/bin/sh
printf '%s\n' "$@" > "$RILLIGHT_DIALOG_MARKER"
DIALOG
chmod +x "$fixture/app/rillight-launch" "$fixture/app/rillight" "$fixture/bin/ldd" "$fixture/bin/zenity"
export PATH="$fixture/bin:$PATH" XDG_STATE_HOME="$fixture/state"
export RILLIGHT_LAUNCH_MARKER="$fixture/launched" RILLIGHT_DIALOG_MARKER="$fixture/dialog"
touch "$fixture/app/lib/libmpv.so.2" "$fixture/app/lib/libmpv.so.1"
LD_LIBRARY_PATH=/old-lib "$fixture/app/rillight-launch" player 'path with spaces'
printf 'player\npath with spaces\n' > "$fixture/expected"
cmp "$fixture/expected" "$fixture/launched"
test ! -f "$fixture/dialog"
rm "$fixture/launched" "$fixture/app/lib/libmpv.so.2"
if "$fixture/app/rillight-launch"; then echo 'Missing core unexpectedly launched' >&2; exit 1; fi
test ! -f "$fixture/launched"
grep -q 'Rillight 启动失败' "$fixture/dialog"
grep -q '缺少 libmpv.so.2' "$fixture/state/rillight/launch.log"
touch "$fixture/app/lib/libmpv.so.2"
rm "$fixture/dialog"
if RILLIGHT_TEST_MISSING=1 "$fixture/app/rillight-launch"; then echo 'Missing transitive library unexpectedly launched' >&2; exit 1; fi
test ! -f "$fixture/launched"
grep -q 'Rillight 启动失败' "$fixture/dialog"
grep -q 'libmissing.so.9 => not found' "$fixture/state/rillight/launch.log"
echo 'Launcher argument forwarding, core/closure diagnostics, and loader isolation passed.'
