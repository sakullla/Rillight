param([string]$Serial, [switch]$AllTargets, [string]$Ffmpeg = 'ffmpeg', [string]$Ffprobe = 'ffprobe')
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
Set-Location -LiteralPath $root
$arguments = @('tool/android_release_checks.py', '--ffmpeg', $Ffmpeg, '--ffprobe', $Ffprobe)
if ($Serial) { $arguments += @('--serial', $Serial) }
if ($AllTargets -or -not $Serial) { $arguments += '--all-targets' }
python @arguments
exit $LASTEXITCODE
