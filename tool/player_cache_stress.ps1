param([switch]$AllowRunningPlayer)

$ErrorActionPreference = 'Stop'
if (-not $AllowRunningPlayer -and (Get-Process rillight -ErrorAction SilentlyContinue)) {
  throw 'Close Rillight before running cache pressure checks, or explicitly use -AllowRunningPlayer.'
}
Push-Location (Split-Path -Parent $PSScriptRoot)
try {
  flutter test tool/player_cache_stress.dart --reporter expanded
  exit $LASTEXITCODE
} finally {
  Pop-Location
}
