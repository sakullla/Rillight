#!/usr/bin/env bash
# Run inside a clean Ubuntu 24.04 Xvfb + D-Bus session after installing the deb.
set -euo pipefail
unset LD_LIBRARY_PATH LD_PRELOAD LD_AUDIT
export LIBGL_ALWAYS_SOFTWARE=1
export XDG_STATE_HOME="${RILLIGHT_SMOKE_STATE:-/tmp/rillight-desktop-smoke}"
mkdir -p "$XDG_STATE_HOME"
media=/opt/rillight/lib/libmpv.so.2
main_pid=''
openbox > "$XDG_STATE_HOME/openbox.log" 2>&1 &
wm_pid=$!
cleanup() {
  if [ -f "$media.disabled" ]; then mv "$media.disabled" "$media"; fi
  if [ -n "$main_pid" ]; then kill "$main_pid" 2>/dev/null || true; fi
  kill "$wm_pid" 2>/dev/null || true
}
trap cleanup EXIT
gtk-launch rillight
window=$(timeout 30s xdotool search --sync --onlyvisible --class '.*rillight.*' | head -1)
main_pid=$(xdotool getwindowpid "$window")
test "$(readlink "/proc/$main_pid/exe")" = /opt/rillight/rillight
kill -0 "$main_pid"
xdotool windowclose "$window"
for i in $(seq 1 100); do
  if [ ! -e "/proc/$main_pid/exe" ]; then break; fi
  sleep 0.1
done
if [ -e "/proc/$main_pid/exe" ]; then echo 'Main window failed to close' >&2; exit 1; fi
main_pid=''

# A system libmpv.so.2 may still exist. Missing the bundled version must produce
# a visible diagnostic, not silently use the old system core or fail unseen.
mv "$media" "$media.disabled"
gtk-launch rillight
dialog=$(timeout 15s xdotool search --sync --onlyvisible --name '^Rillight 启动失败$' | head -1)
test -n "$dialog"
dialog_pid=$(xdotool getwindowpid "$dialog")
test "$(readlink "/proc/$dialog_pid/exe")" = /usr/bin/zenity
python3 "$(dirname "$0")/assert_diagnostic.py" "$dialog_pid" "$XDG_STATE_HOME/diagnostic-accessibility.json"
grep -q '缺少 libmpv.so.2' "$XDG_STATE_HOME/rillight/launch.log"
xdotool windowactivate --sync "$dialog" key Return
mv "$media.disabled" "$media"
echo 'Installed gtk-launch, graceful exit and visible missing-library diagnostic passed.'
