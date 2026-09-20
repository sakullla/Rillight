param(
  [Parameter(Mandatory = $true)][string]$Container
)
$ErrorActionPreference = 'Stop'
python "$PSScriptRoot/linux_playback_validation.py" --container $Container
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
