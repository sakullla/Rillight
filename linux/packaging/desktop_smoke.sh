#!/usr/bin/env bash
# Run inside a clean Ubuntu 24.04 Xvfb + D-Bus session after installing the deb.
set -euo pipefail
unset LD_LIBRARY_PATH LD_PRELOAD LD_AUDIT
export LIBGL_ALWAYS_SOFTWARE=1
export XDG_STATE_HOME="${RILLIGHT_SMOKE_STATE:-/tmp/rillight-desktop-smoke}"
mkdir -p "$XDG_STATE_HOME"
media=/opt/rillight/lib/librillight_core.so
main_pid=''
openbox > "$XDG_STATE_HOME/openbox.log" 2>&1 &
wm_pid=$!
cleanup() {
  if [ -f "$media.disabled" ]; then mv "$media.disabled" "$media"; fi
  if [ -n "$main_pid" ]; then kill "$main_pid" 2>/dev/null || true; fi
  kill "$wm_pid" 2>/dev/null || true
}
trap cleanup EXIT
close_window() {
  # A native close can destroy the X11 window before xdotool finishes its
  # follow-up attribute query. Treat that stale-window race as harmless; the
  # process-liveness check below still verifies that the app actually exited.
  xdotool windowclose "$1" >/dev/null 2>&1 || true
}
gtk-launch rillight
read -r window main_pid < <(python3 "$(dirname "$0")/wait_for_window.py" \
  --match class --pattern '.*rillight.*' --executable /opt/rillight/rillight)
test "$(readlink "/proc/$main_pid/exe")" = /opt/rillight/rillight
kill -0 "$main_pid"
close_window "$window"
for i in $(seq 1 100); do
  if [ ! -e "/proc/$main_pid/exe" ]; then break; fi
  sleep 0.1
done
if [ -e "/proc/$main_pid/exe" ]; then echo 'Main window failed to close' >&2; exit 1; fi
main_pid=''

# A system media library may still exist. Missing the owned core must produce
# a visible diagnostic, rather than silently using another player.
mv "$media" "$media.disabled"
gtk-launch rillight
read -r dialog dialog_pid < <(python3 "$(dirname "$0")/wait_for_window.py" \
  --match name --pattern '^Rillight 启动失败$' --executable /usr/bin/zenity --timeout 15)
test -n "$dialog"
test "$(readlink "/proc/$dialog_pid/exe")" = /usr/bin/zenity
python3 "$(dirname "$0")/assert_diagnostic.py" "$dialog_pid" "$XDG_STATE_HOME/diagnostic-accessibility.json"
grep -q '缺少 librillight_core.so' "$XDG_STATE_HOME/rillight/launch.log"
xdotool windowactivate --sync "$dialog" key Return >/dev/null 2>&1 || true
mv "$media.disabled" "$media"
echo 'Installed gtk-launch, graceful exit and visible missing-library diagnostic passed.'
