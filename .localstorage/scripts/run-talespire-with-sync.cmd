@echo off
setlocal EnableExtensions DisableDelayedExpansion

rem === Config ===
set "REPO1=%USERPROFILE%\AppData\LocalLow\BouncyRock Entertainment\TaleSpire\Symbiotes\Toolset"
set "REPO2=%USERPROFILE%\AppData\LocalLow\BouncyRock Entertainment\TaleSpire\LocalContentPacks"
set "REMOTE1=https://github.com/Huakus/TaleSpire-5E-Toolset"
set "REMOTE2=https://github.com/Huakus/TaleSpire_LocalContentPacks"
set "INTERVAL=10"
set "GIT=%ProgramFiles%\Git\cmd\git.exe"
if not exist "%GIT%" set "GIT=%ProgramFiles(x86)%\Git\cmd\git.exe"
if not exist "%GIT%" set "GIT=%LOCALAPPDATA%\Programs\Git\cmd\git.exe"
if not exist "%GIT%" set "GIT=git"

set "PSFILE=%TEMP%\talespire-sync.ps1"

rem === Crear/limpiar el PS1 y escribirlo línea por línea (sin bloque) ===
break > "%PSFILE%"

>>"%PSFILE%" echo $ErrorActionPreference = 'Continue'
>>"%PSFILE%" echo $Git = "%GIT%"
>>"%PSFILE%" echo $Repo1 = "%REPO1%"
>>"%PSFILE%" echo $Repo2 = "%REPO2%"
>>"%PSFILE%" echo $Remote1 = "%REMOTE1%"
>>"%PSFILE%" echo $Remote2 = "%REMOTE2%"
>>"%PSFILE%" echo $Interval = %INTERVAL%
>>"%PSFILE%" echo $Proc = 'TaleSpire'
>>"%PSFILE%" echo

>>"%PSFILE%" echo function Get-DefaultBranch([string]^$Remote) {
>>"%PSFILE%" echo ^    ^$b = 'main'
>>"%PSFILE%" echo ^    try {
>>"%PSFILE%" echo ^        ^$head = ^& ^$Git ls-remote --symref ^$Remote HEAD 2^>^&1
>>"%PSFILE%" echo ^        if(^$head -match 'refs/heads/([^ ]+)'^) { return ^$matches[1] }
>>"%PSFILE%" echo ^        ^$heads = ^& ^$Git ls-remote --heads ^$Remote 2^>^&1
>>"%PSFILE%" echo ^        if(^$heads -match 'refs/heads/master'^) { ^$b='master' }
>>"%PSFILE%" echo ^    } catch {}
>>"%PSFILE%" echo ^    return ^$b
>>"%PSFILE%" echo }

>>"%PSFILE%" echo
>>"%PSFILE%" echo function Ensure-Repo([string]^$Repo, [string]^$Remote) {
>>"%PSFILE%" echo ^    if (Test-Path (Join-Path ^$Repo '.git'^)) { return }
>>"%PSFILE%" echo ^    if (-not (Test-Path ^$Repo^)) { New-Item -ItemType Directory -Force -Path ^$Repo ^| Out-Null }
>>"%PSFILE%" echo ^    ^$hasFiles = (Get-ChildItem -Path ^$Repo -Force ^| Where-Object { ^$_.Name -ne '.git' } ^| Measure-Object).Count -gt 0
>>"%PSFILE%" echo ^    ^$defaultBranch = Get-DefaultBranch ^$Remote
>>"%PSFILE%" echo ^    if (-not ^$hasFiles) {
>>"%PSFILE%" echo ^        Write-Host "Clonando ^$Remote en ^$Repo"
>>"%PSFILE%" echo ^        ^& ^$Git clone ^$Remote ^$Repo
>>"%PSFILE%" echo ^    } else {
>>"%PSFILE%" echo ^        Write-Host "Inicializando repo en carpeta con archivos: ^$Repo"
>>"%PSFILE%" echo ^        ^& ^$Git -C ^$Repo init
>>"%PSFILE%" echo ^        try { ^& ^$Git -C ^$Repo remote remove origin } catch {}
>>"%PSFILE%" echo ^        ^& ^$Git -C ^$Repo remote add origin ^$Remote
>>"%PSFILE%" echo ^        ^& ^$Git -C ^$Repo fetch origin
>>"%PSFILE%" echo ^        try { ^& ^$Git -C ^$Repo rev-parse --verify ^$defaultBranch } catch { ^& ^$Git -C ^$Repo checkout -b ^$defaultBranch }
>>"%PSFILE%" echo ^        ^& ^$Git -C ^$Repo branch --set-upstream-to=origin/^$defaultBranch ^$defaultBranch
>>"%PSFILE%" echo ^        ^& ^$Git -C ^$Repo pull --rebase --autostash --allow-unrelated-histories origin ^$defaultBranch
>>"%PSFILE%" echo ^    }
>>"%PSFILE%" echo }

>>"%PSFILE%" echo
>>"%PSFILE%" echo function Get-Branch([string]^$Repo){
>>"%PSFILE%" echo ^    try { (^& ^$Git -C ^$Repo rev-parse --abbrev-ref HEAD).Trim() } catch { '' }
>>"%PSFILE%" echo }

>>"%PSFILE%" echo
>>"%PSFILE%" echo function Sync([string]^$Repo,[string]^$Branch){
>>"%PSFILE%" echo ^    if (-not (Test-Path (Join-Path ^$Repo '.git'^))) { Write-Host "No es repo git: ^$Repo"; return }
>>"%PSFILE%" echo ^    if ([string]::IsNullOrWhiteSpace(^$Branch^)) { ^$Branch='main' }
>>"%PSFILE%" echo ^    ^& ^$Git -C ^$Repo add -A
>>"%PSFILE%" echo ^    ^$dirty = ^& ^$Git -C ^$Repo status --porcelain
>>"%PSFILE%" echo ^    if (^$dirty) { ^& ^$Git -C ^$Repo commit -m ("auto: " + (Get-Date -Format o^)) }
>>"%PSFILE%" echo ^    ^& ^$Git -C ^$Repo fetch origin
>>"%PSFILE%" echo ^    ^& ^$Git -C ^$Repo pull --rebase --autostash origin ^$Branch
>>"%PSFILE%" echo ^    ^& ^$Git -C ^$Repo push origin ^$Branch
>>"%PSFILE%" echo }

>>"%PSFILE%" echo
>>"%PSFILE%" echo Ensure-Repo -Repo ^$Repo1 -Remote ^$Remote1
>>"%PSFILE%" echo Ensure-Repo -Repo ^$Repo2 -Remote ^$Remote2

>>"%PSFILE%" echo
>>"%PSFILE%" echo ^$Repos = @(^$Repo1,^$Repo2^) ^| Where-Object { ^$_ -and (Test-Path ^$_^) }
>>"%PSFILE%" echo ^$Branches = @{}
>>"%PSFILE%" echo foreach(^$r in ^$Repos){
>>"%PSFILE%" echo ^  ^$b = Get-Branch -Repo ^$r
>>"%PSFILE%" echo ^  if([string]::IsNullOrWhiteSpace(^$b^)){
>>"%PSFILE%" echo ^    try{ ^$url = (^& ^$Git -C ^$r remote get-url origin) } catch { ^$url = ^$null }
>>"%PSFILE%" echo ^    ^$b = if(^$url){ Get-DefaultBranch ^$url } else { 'main' }
>>"%PSFILE%" echo ^  }
>>"%PSFILE%" echo ^  ^$Branches[^$r] = ^$b
>>"%PSFILE%" echo }

>>"%PSFILE%" echo
>>"%PSFILE%" echo foreach(^$r in ^$Repos){ Sync -Repo ^$r -Branch ^$Branches[^$r] }

>>"%PSFILE%" echo
>>"%PSFILE%" echo Start-Process 'steam://rungameid/720620'
>>"%PSFILE%" echo ^$appeared=^$false
>>"%PSFILE%" echo for(^$i=0;^$i -lt 30;^$i++^){ if(Get-Process -Name ^$Proc -ErrorAction SilentlyContinue^){ ^$appeared=^$true; break } Start-Sleep -Seconds 1 }
>>"%PSFILE%" echo if(^$appeared^){
>>"%PSFILE%" echo ^  while (Get-Process -Name ^$Proc -ErrorAction SilentlyContinue^) {
>>"%PSFILE%" echo ^    Start-Sleep -Seconds ^$Interval
>>"%PSFILE%" echo ^    if (Get-Process -Name ^$Proc -ErrorAction SilentlyContinue^) {
>>"%PSFILE%" echo ^      foreach(^$r in ^$Repos){ Sync -Repo ^$r -Branch ^$Branches[^$r] }
>>"%PSFILE%" echo ^    }
>>"%PSFILE%" echo ^  }
>>"%PSFILE%" echo }
>>"%PSFILE%" echo foreach(^$r in ^$Repos){ Sync -Repo ^$r -Branch ^$Branches[^$r] }

rem === Ejecutar PowerShell en ESTA ventana y pausar siempre ===
call powershell -NoProfile -ExecutionPolicy Bypass -File "%PSFILE%"
set "EXITCODE=%ERRORLEVEL%"

echo(
if not "%EXITCODE%"=="0" (
  echo ❌ Hubo un error (exit code %EXITCODE%).
) else (
  echo ✅ Listo.
)
echo (Presiona una tecla para cerrar)
pause >nul
