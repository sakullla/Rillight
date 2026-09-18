#!/usr/bin/env bash
# Requires a bundle built with --target tool/player_smoke.dart, existing
# synthetic fixtures, Xvfb/D-Bus, PulseAudio, xdotool, xwd and Python Pillow.
# Invoke inside: xvfb-run -a dbus-run-session -- bash this-script BUNDLE MEDIA OUTPUT
set -euo pipefail
bundle=$(cd "${1:?Validation bundle required}" && pwd)
media=$(cd "${2:?Synthetic fixture directory required}" && pwd)
mkdir -p "${3:?New evidence directory required}"
output=$(cd "$3" && pwd)
if [ -e "$output/result.json" ] || [ -e "$output/server.json" ]; then
  echo 'Use a fresh evidence directory; stale results are not accepted' >&2; exit 2
fi
source_root=$(cd "$(dirname "$0")/../.." && pwd)
export LANG=C.UTF-8 LC_ALL=C.UTF-8 LIBGL_ALWAYS_SOFTWARE=1
unset LD_LIBRARY_PATH LD_PRELOAD LD_AUDIT
export RILLIGHT_VALIDATION_DIRECTORY="$output"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp/rillight-player-runtime-$$}"
mkdir -p "$XDG_RUNTIME_DIR"
chmod 700 "$XDG_RUNTIME_DIR"
# GitHub ubuntu:24.04 container jobs set HOME=/github/home, which PulseAudio
# cannot use (missing or not a real home). Daemon startup then fails and the
# smoke exits before launching the app.
pulse_home="$output/pulse-home"
mkdir -p "$pulse_home"
chmod 700 "$pulse_home"
export HOME="$pulse_home"

start_pulse() {
  if pactl info >/dev/null 2>&1; then
    return 0
  fi
  pulseaudio --start --exit-idle-time=-1 --log-target="file:$output/pulseaudio.log"
  local i
  for i in $(seq 1 50); do
    if pactl info >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.1
  done
  echo 'PulseAudio did not become ready' >&2
  cat "$output/pulseaudio.log" >&2 || true
  return 1
}

dump_evidence() {
  echo "---- playback evidence ----" >&2
  for name in pulseaudio.log capture.log app.stderr.log app.stdout.log server.log result.json window-evidence.json; do
    [ -e "$output/$name" ] || continue
    echo "==== $name ====" >&2
    tail -n 80 "$output/$name" >&2 || true
  done
}

start_pulse
previous_sink=$(pactl get-default-sink 2>/dev/null || true)
sink="rillight_validation_$$"
module=$(pactl load-module module-null-sink sink_name="$sink" rate=48000 channels=2)
pactl set-default-sink "$sink"
pactl info > "$output/audio-environment.txt"
openbox > "$output/openbox.log" 2>&1 &
wm_pid=$!
python3 "$source_root/tool/player_fixtures.py" --media "$media" --output "$output" > "$output/server.log" 2>&1 &
server_pid=$!
app_pid=''; capture_pid=''
cleanup() {
  [ -z "$app_pid" ] || kill "$app_pid" 2>/dev/null || true
  [ -z "$capture_pid" ] || kill "$capture_pid" 2>/dev/null || true
  # The control host heartbeat makes orphaned validation children close too.
  kill "$server_pid" "$wm_pid" 2>/dev/null || true
  if [ -n "${previous_sink:-}" ]; then
    pactl set-default-sink "$previous_sink" 2>/dev/null || true
  fi
  pactl unload-module "$module" 2>/dev/null || true
}
trap cleanup EXIT
for i in $(seq 1 100); do
  [ ! -f "$output/server.json" ] || break
  sleep 0.1
done
test -f "$output/server.json"
python3 "$source_root/linux/packaging/capture_playback.py" --executable "$bundle/rillight" --output "$output" > "$output/capture.log" 2>&1 &
capture_pid=$!
timeout 240s "$bundle/rillight" > "$output/app.stdout.log" 2> "$output/app.stderr.log" &
app_pid=$!
set +e
wait "$app_pid"
app_status=$?
app_pid=''
wait "$capture_pid"
capture_status=$?
capture_pid=''
set -e
if [ "$app_status" -ne 0 ] || [ "$capture_status" -ne 0 ]; then
  echo "playback smoke failed: app=$app_status capture=$capture_status" >&2
  dump_evidence
  exit 1
fi
if ! python3 - "$output" <<'PY'
import json,sys
from pathlib import Path
root=Path(sys.argv[1])
result=root/'result.json'
evidence=root/'window-evidence.json'
assert result.is_file(), 'missing result.json'
assert evidence.is_file(), 'missing window-evidence.json'
assert json.loads(result.read_text())['passed'] is True
assert len(json.loads(evidence.read_text())) == 4
print('Production main/child playback, real window video, subtitles, switching, and virtual audio passed')
PY
then
  dump_evidence
  exit 1
fi

