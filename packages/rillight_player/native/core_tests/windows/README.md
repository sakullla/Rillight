# Windows core output checks

The native CTest suite checks RGBA geometry, D3D11 shared-resource capability,
and WASAPI buffer consumption. The production Flutter surface uses a pixel
buffer: Flutter 3.47.4 with Impeller did not import the independently created
D3D11 shared texture in an actual window. Hardware video decoding remains a
separate FFmpeg capability and is reported per video track.

`flutter_core_smoke.dart` and `flutter_smoke_source.cpp` exercise the complete
core → Flutter texture path with generated `tracks.mkv` media. Run from the
repository root in PowerShell on Windows with Flutter 3.47.4, the pinned
Windows core SDK, and MSYS2 MinGW64 installed:

```powershell
$env:RILLIGHT_CORE_PREFIX_WINDOWS_X64 = (Resolve-Path build/ffmpeg-core-windows-sdk).Path
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
