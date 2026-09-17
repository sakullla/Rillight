param([switch]$SkipBuild)
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
Set-Location -LiteralPath $root
$output = Join-Path $root ('build/player-validation/runs/' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
New-Item -ItemType Directory -Force -Path $output | Out-Null
$media = Join-Path $root 'build/player-validation/media'
$ffmpeg = Join-Path $root 'build/player-validation/tools/ffmpeg-9.0.1-essentials_build/bin/ffmpeg.exe'
if (-not (Test-Path -LiteralPath $ffmpeg)) {
  $ffmpeg = (Get-Command ffmpeg -ErrorAction Stop).Source
}
python tool/player_fixtures.py --media $media --ffmpeg $ffmpeg
if ($LASTEXITCODE -ne 0) { throw 'Fixture creation failed' }
if (-not $SkipBuild) {
  flutter build windows --release --target tool/player_smoke.dart
  if ($LASTEXITCODE -ne 0) { throw 'Smoke release build failed' }
}
$originalValidation = $env:RILLIGHT_VALIDATION_DIRECTORY
$server = $null
$app = $null
try {
  $server = Start-Process -FilePath (Get-Command python).Source -ArgumentList @(
    'tool/player_fixtures.py', '--media', ('"' + $media + '"'), '--output', ('"' + $output + '"')
  ) -PassThru -WindowStyle Hidden -RedirectStandardError (Join-Path $output 'server.stderr.log')
  $deadline = (Get-Date).AddSeconds(15)
  while (-not (Test-Path -LiteralPath (Join-Path $output 'server.json'))) {
    if ($server.HasExited -or (Get-Date) -gt $deadline) { throw 'Fixture server failed to start' }
    Start-Sleep -Milliseconds 100
  }
  $env:RILLIGHT_VALIDATION_DIRECTORY = $output
  $app = Start-Process -FilePath (Join-Path $root 'build/windows/x64/runner/Release/rillight.exe') `
    -PassThru -WindowStyle Hidden -RedirectStandardOutput (Join-Path $output 'app.stdout.log') `
    -RedirectStandardError (Join-Path $output 'app.stderr.log')
  Write-Output "Playback validation evidence: $output"
  $deadline = (Get-Date).AddMinutes(4)
  while (-not $app.HasExited) {
    if ((Get-Date) -gt $deadline) { throw 'Playback validation timed out' }
    Start-Sleep -Milliseconds 250
  }
  $result = Get-Content -LiteralPath (Join-Path $output 'result.json') -Raw | ConvertFrom-Json
  if (-not $result.passed) { throw ('Playback validation failed: ' + $result.error) }
  python tool/verify_player_dependencies.py
  if ($LASTEXITCODE -ne 0) { throw 'Dependency verification failed' }
  Write-Output 'Release-mode production main/child playback validation passed.'
} finally {
  if ($app -and -not $app.HasExited) {
    $null = $app.CloseMainWindow()
    if (-not $app.WaitForExit(5000)) { $app.Kill() }
  }
  if ($server -and -not $server.HasExited) { $server.Kill() }
  $env:RILLIGHT_VALIDATION_DIRECTORY = $originalValidation
  if (-not $SkipBuild) {
    # Leave the distribution artifact on the ordinary lib/main.dart entrypoint.
    flutter build windows --release
    if ($LASTEXITCODE -ne 0) { throw 'Restoring production release build failed' }
  }
}
