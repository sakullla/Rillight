param([switch]$SkipBuild, [switch]$LongCache, [ValidateRange(1, 20)][int]$Runs = 1)
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
Set-Location -LiteralPath $root
$sdk = $env:RILLIGHT_CORE_PREFIX_WINDOWS_X64
if (-not $sdk) {
  $candidate = Join-Path $root 'build/ffmpeg-core-windows-hw-sdk'
  if (Test-Path -LiteralPath (Join-Path $candidate 'rillight-core-dependencies.json')) {
    $sdk = (Resolve-Path -LiteralPath $candidate).Path
    $env:RILLIGHT_CORE_PREFIX_WINDOWS_X64 = $sdk
  }
}
if (-not $sdk) { throw 'Set RILLIGHT_CORE_PREFIX_WINDOWS_X64 to a pinned Windows FFmpeg core SDK' }
python packages/rillight_player/native/verify_core_dependencies.py --prefix $sdk --target windows-x64 --require-subtitles
if ($LASTEXITCODE -ne 0) { throw 'Pinned Windows core SDK verification failed' }
if ($Runs -gt 1) {
  if (-not $SkipBuild) {
    $buildArgs = @('build', 'windows', '--release', '--target', 'tool/player_smoke.dart')
    if ($LongCache) { $buildArgs += '--dart-define=RILLIGHT_VALIDATION_READ_AHEAD_MIB=8' }
    flutter @buildArgs
    if ($LASTEXITCODE -ne 0) { throw 'Smoke release build failed' }
  }
  try {
    for ($run = 1; $run -le $Runs; $run++) {
      & $PSCommandPath -SkipBuild -LongCache:$LongCache
      if ($LASTEXITCODE -ne 0) { throw "Smoke iteration $run failed" }
    }
  } finally {
    if (-not $SkipBuild) {
      flutter build windows --release
      if ($LASTEXITCODE -ne 0) { throw 'Restoring production release build failed' }
    }
  }
  return
}
$output = Join-Path $root ('build/player-validation/runs/' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
New-Item -ItemType Directory -Force -Path $output | Out-Null
$media = Join-Path $root 'build/player-validation/media'
$ffmpeg = Join-Path $root 'build/player-validation/tools/ffmpeg-9.0.2-essentials_build/bin/ffmpeg.exe'
if (-not (Test-Path -LiteralPath $ffmpeg)) {
  $ffmpeg = Join-Path $root 'build/android-validation/tools/ffmpeg-9.0.2-essentials_build/bin/ffmpeg.exe'
}
if (-not (Test-Path -LiteralPath $ffmpeg)) {
  $ffmpeg = (Get-Command ffmpeg -ErrorAction Stop).Source
}
$fixtureArgs = @('tool/player_fixtures.py', '--media', $media, '--ffmpeg', $ffmpeg)
if ($LongCache) { $fixtureArgs += '--long-cache' }
python @fixtureArgs
if ($LASTEXITCODE -ne 0) { throw 'Fixture creation failed' }
if (-not $SkipBuild) {
  $buildArgs = @('build', 'windows', '--release', '--target', 'tool/player_smoke.dart')
  if ($LongCache) { $buildArgs += '--dart-define=RILLIGHT_VALIDATION_READ_AHEAD_MIB=8' }
  flutter @buildArgs
  if ($LASTEXITCODE -ne 0) { throw 'Smoke release build failed' }
}
$originalValidation = $env:RILLIGHT_VALIDATION_DIRECTORY
$originalLongCache = $env:RILLIGHT_SMOKE_LONG_CACHE
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
  if ($LongCache) { $env:RILLIGHT_SMOKE_LONG_CACHE = '1' }
  $app = Start-Process -FilePath (Join-Path $root 'build/windows/x64/runner/Release/rillight.exe') `
    -PassThru -WindowStyle Hidden -RedirectStandardOutput (Join-Path $output 'app.stdout.log') `
    -RedirectStandardError (Join-Path $output 'app.stderr.log')
  Write-Output "Playback validation evidence: $output"
  $deadline = (Get-Date).AddMinutes(4)
  $capturedPhases = @{}
  $captureMilestones = [ordered]@{ early = 28000; middle = 55000; late = 72000 }
  while (-not $app.HasExited) {
    if ((Get-Date) -gt $deadline) { throw 'Playback validation timed out' }
    if ($LongCache -and $capturedPhases.Count -lt $captureMilestones.Count) {
      $playerLog = Join-Path $output 'player.jsonl'
      if (Test-Path -LiteralPath $playerLog) {
        $samples = @(Get-Content -LiteralPath $playerLog -Tail 8 | ForEach-Object { $_ | ConvertFrom-Json } |
          Where-Object { $_.event -eq 'cache-long-sample' })
        if ($samples.Count -gt 0) {
          $latestPosition = ($samples | Select-Object -Last 1).value.positionMs
          $childPid = (Get-Content -LiteralPath $playerLog -First 1 | ConvertFrom-Json).value.pid
          foreach ($phase in $captureMilestones.Keys) {
            if (-not $capturedPhases.ContainsKey($phase) -and $latestPosition -ge $captureMilestones[$phase]) {
              python tool/player_window_capture.py --pid $childPid --output $output --phase $phase
              if ($LASTEXITCODE -ne 0) { throw "Actual Windows player frames did not change at $phase" }
              $capturedPhases[$phase] = $true
              break
            }
          }
        }
      }
    }
    Start-Sleep -Milliseconds 250
  }
  $result = Get-Content -LiteralPath (Join-Path $output 'result.json') -Raw | ConvertFrom-Json
  if (-not $result.passed) { throw ('Playback validation failed: ' + $result.error) }
  if ($LongCache) {
    if ($capturedPhases.Count -ne $captureMilestones.Count) {
      throw 'Long cache playback lacked early, middle, or late actual window pixels'
    }
    foreach ($phase in $captureMilestones.Keys) {
      $motion = Get-Content -LiteralPath (Join-Path $output "cache-long-$phase-window-motion.json") -Raw |
        ConvertFrom-Json
      if ($motion.changedPixels -lt 100 -or $motion.peakDifference -lt 40) {
        throw "Actual Windows player frames did not change at $phase"
      }
    }
    $rows = @(Get-Content -LiteralPath (Join-Path $output 'player.jsonl') |
      ForEach-Object { $_ | ConvertFrom-Json })
    $longResult = @($rows | Where-Object { $_.event -eq 'cache-long-result' })
    $reopened = @($rows | Where-Object { $_.event -eq 'cache-long-reopened' })
    $sample = @($rows | Where-Object { $_.event -eq 'cache-long-sample' })
    if ($longResult.Count -ne 1 -or $reopened.Count -ne 1 -or
        $longResult[0].value.positionMs -lt 78000 -or
        $longResult[0].value.largestPublishedBytes -lt 3 * 8 * 1024 * 1024 -or
        -not $longResult[0].value.recovered -or
        -not $longResult[0].value.sawIdleWindow -or
        @($sample | Where-Object { $_.value.readAheadLimitBytes -eq 8 * 1024 * 1024 }).Count -eq 0) {
      throw 'Long cache window, recovery, or reopen evidence incomplete'
    }
    $requests = @(Get-Content -LiteralPath (Join-Path $output 'cache-long-requests.jsonl') |
      ForEach-Object { $_ | ConvertFrom-Json })
    $fault = @($requests | Where-Object { $_.fault -eq $true })
    if ($fault.Count -ne 1 -or
        @($requests | Where-Object {
          $_.ifRange -eq $true -and $_.start -eq $fault[0].start + 256 * 1024
        }).Count -eq 0 -or
        @($requests | Where-Object { $_.start -ge 3 * 8 * 1024 * 1024 }).Count -eq 0) {
      throw 'Long cache did not prove validated suffix recovery across windows'
    }
  } else {
    $powerEvidence = @(Get-Content -LiteralPath (Join-Path $output 'player.jsonl') |
      ForEach-Object { $_ | ConvertFrom-Json } | Where-Object { $_.event -eq 'display-power-request' })
    $requiredPowerStates = @{
      playing=$true; paused=$false; resumed=$true; eof=$false; replayed=$true;
      stopped=$false; restarted=$true; 'failed-open'=$false; 'before-dispose'=$true;
      disposed=$false; 'disposed-again'=$false
    }
    foreach ($phase in $requiredPowerStates.Keys) {
      $row = @($powerEvidence | Where-Object { $_.value.phase -eq $phase })
      if ($row.Count -ne 1 -or $row[0].value.displayRequired -ne $requiredPowerStates[$phase]) {
        throw "Missing or incorrect actual UI-thread display request evidence: $phase"
      }
    }
    $powerEvidence | ForEach-Object { $_.value } | ConvertTo-Json -Depth 5 |
      Set-Content -LiteralPath (Join-Path $output 'display-power-requests.json') -Encoding utf8
  }
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
  $env:RILLIGHT_SMOKE_LONG_CACHE = $originalLongCache
  if (-not $SkipBuild) {
    # Leave the distribution artifact on the ordinary lib/main.dart entrypoint.
    flutter build windows --release
    if ($LASTEXITCODE -ne 0) { throw 'Restoring production release build failed' }
  }
}
