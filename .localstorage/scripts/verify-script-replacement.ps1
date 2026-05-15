$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Files = @(
  '2_orquestrator.ps1',
  '5_sync-toolset-git.ps1',
  '8_generate-public-file-index.ps1'
)
foreach ($file in $Files) {
  $path = Join-Path $ScriptDir $file
  Write-Host "--- $file ---"
  if (-not (Test-Path -LiteralPath $path)) {
    Write-Host "NO EXISTE" -ForegroundColor Red
    continue
  }
  Select-String -Path $path -Pattern 'RunOnce|StopSignalFile|Quiet|Public File Index Generator' | ForEach-Object {
    Write-Host ("{0}: {1}" -f $_.LineNumber, $_.Line.Trim())
  }
}
Write-Host ''
Write-Host 'OK: si 2_orquestrator.ps1 muestra RunOnce, todavia tenes el orquestador viejo.' -ForegroundColor Yellow
Write-Host 'OK: si 5_sync-toolset-git.ps1 NO muestra [switch]$Quiet, el sync viejo sigue en disco.' -ForegroundColor Yellow
Write-Host 'OK: si 8_generate-public-file-index.ps1 NO muestra [switch]$RunOnce y [string]$StopSignalFile, el generador viejo sigue en disco.' -ForegroundColor Yellow
