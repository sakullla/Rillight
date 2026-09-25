# Windows core output checks

The native CTest suite checks RGBA geometry, D3D11 shared-resource capability,
and WASAPI buffer consumption. The production Flutter surface uses a pixel
buffer: Flutter 3.47.4 with Impeller did not import the independently created
D3D11 shared texture in an actual window. Hardware video decoding remains a
separate FFmpeg capability and is reported per video track. The suite also
checks audio startup offset and the handoff to a monotonic clock after a short
audio track ends.

`flutter_core_smoke.dart` and `flutter_smoke_source.cpp` exercise the complete
core → Flutter texture path with generated `tracks.mkv` media. Run from the
repository root in PowerShell on Windows with Flutter 3.47.4, the pinned
Windows core SDK, and MSYS2 MinGW64 installed:

```powershell
$env:RILLIGHT_CORE_PREFIX_WINDOWS_X64 = (Resolve-Path build/ffmpeg-core-windows-hw-sdk).Path
$sdk = $env:RILLIGHT_CORE_PREFIX_WINDOWS_X64
$env:PATH = "C:\msys64\mingw64\bin;$env:PATH"
python packages/rillight_player/native/verify_core_dependencies.py --prefix $sdk --target windows-x64 --require-subtitles
python tool/player_fixtures.py --media build/player-validation/media --ffmpeg C:\path\to\ffmpeg.exe
& C:\msys64\mingw64\bin\g++.exe -std=c++17 -shared -O2 packages/rillight_player/native/core_tests/windows/flutter_smoke_source.cpp "-L$sdk/lib" -lrillight_core -o build/t4_smoke_helper.dll
flutter build windows --debug -t packages/rillight_player/native/core_tests/windows/flutter_core_smoke.dart
Copy-Item build/t4_smoke_helper.dll build/windows/x64/runner/Debug/t4_smoke_helper.dll -Force
$app = (Resolve-Path build/windows/x64/runner/Debug/rillight.exe).Path
$run = Start-Process -FilePath $app -WorkingDirectory (Get-Location).Path -WindowStyle Hidden -RedirectStandardOutput build/windows_core_smoke_stdout.log -RedirectStandardError build/windows_core_smoke_stderr.log -Wait -PassThru
Get-Content build/windows_core_smoke_stdout.log
Get-Content build/windows_core_smoke_stderr.log
$run.ExitCode
```

Exit code 0 requires decoded video frames, advancing media time, a decoded
audio frame, no plugin error, and two different Flutter window captures in
`build/windows_core_frame_a.png` and `build/windows_core_frame_b.png`.
Inspect the captures to establish actual colored picture output. This check
does not establish physical audio output or GPU decoding; inspect the
`actualHardware` value separately. Run `flutter build windows --debug` again
afterwards to restore the ordinary application entrypoint.

Two Debug-only fault checks cover native lifecycle failures without changing
the machine's audio configuration:

```powershell
$env:RILLIGHT_TEST_NO_AUDIO = '1'
flutter build windows --debug -t packages/rillight_player/native/core_tests/windows/flutter_core_smoke.dart --dart-define=RILLIGHT_SMOKE_NO_AUDIO=true
# Copy t4_smoke_helper.dll beside the executable, then launch as above.
# The result must have queuedAudio=0, moving colored frames, and exit 0.
Remove-Item Env:RILLIGHT_TEST_NO_AUDIO

$env:RILLIGHT_TEST_SURFACE_DELAY_MS = '750'
flutter build windows --debug -t packages/rillight_player/native/core_tests/windows/flutter_lifecycle_smoke.dart
# Copy t4_smoke_helper.dll beside the executable, then launch as above.
# It closes its own Win32 window during native surface creation; exit 0 and
# no unresponded platform-message warning are required.
Remove-Item Env:RILLIGHT_TEST_SURFACE_DELAY_MS

$env:RILLIGHT_TEST_AUDIO_INIT_DELAY_MS = '500'
flutter build windows --debug -t packages/rillight_player/native/core_tests/windows/flutter_core_smoke.dart
# Copy the helper DLL and launch as above. The media position and texture must
# advance without an audio warning after the delayed WASAPI initialization.
Remove-Item Env:RILLIGHT_TEST_AUDIO_INIT_DELAY_MS

& C:\path\to\ffmpeg.exe -y -f lavfi -i 'color=c=red:s=640x360:r=30:d=4' -f lavfi -i 'color=c=blue:s=640x360:r=30:d=4' -f lavfi -i 'sine=frequency=440:sample_rate=48000:duration=8' -filter_complex '[0:v][1:v]concat=n=2:v=1:a=0[v]' -map '[v]' -map 2:a -c:v mpeg4 -q:v 4 -c:a pcm_s16le build/player-validation/media/seek-colors.mkv
flutter build windows --debug -t packages/rillight_player/native/core_tests/windows/flutter_core_smoke.dart --dart-define=RILLIGHT_SMOKE_SEEK=true --dart-define=RILLIGHT_SMOKE_MEDIA=build/player-validation/media/seek-colors.mkv
# Copy the helper DLL and launch as above. Pass requires the actual Flutter
# texture center to change from red to blue after the seek's timeline advances.

# A generated 3 s video with just 0.2 s of PCM audio exercises clock handoff.
& C:\path\to\ffmpeg.exe -y -f lavfi -i 'testsrc2=size=640x360:rate=30:duration=3' -f lavfi -i 'sine=frequency=440:sample_rate=48000:duration=0.2' -map 0:v -map 1:a -c:v mpeg4 -q:v 4 -c:a pcm_s16le build/player-validation/media/short-audio-long-video.mkv
flutter build windows --debug -t packages/rillight_player/native/core_tests/windows/flutter_core_smoke.dart --dart-define=RILLIGHT_SMOKE_MEDIA=build/player-validation/media/short-audio-long-video.mkv --dart-define=RILLIGHT_SMOKE_MIN_POSITION_US=1500000
# Copy the helper DLL and launch as above. maxPosition must exceed 1.5 s.

# Two 0.2 s PCM spans separated by a 1.8 s packet-PTS gap must not hold video.
& C:\path\to\ffmpeg.exe -y -f lavfi -i 'testsrc2=size=640x360:rate=30:duration=3' -f lavfi -i 'sine=frequency=440:sample_rate=48000:duration=2.5' -filter_complex "[1:a]aselect='between(t,0,0.2)+between(t,2,2.2)'[a]" -map 0:v -map '[a]' -c:v mpeg4 -q:v 4 -c:a pcm_s16le build/player-validation/media/gapped-audio-video.mkv
flutter build windows --debug -t packages/rillight_player/native/core_tests/windows/flutter_core_smoke.dart --dart-define=RILLIGHT_SMOKE_MEDIA=build/player-validation/media/gapped-audio-video.mkv --dart-define=RILLIGHT_SMOKE_MIN_POSITION_US=2800000 --dart-define=RILLIGHT_SMOKE_MAX_STALL_MS=300
# Copy the helper DLL and launch as above. maxStallMs must stay <= 300 ms.
```
