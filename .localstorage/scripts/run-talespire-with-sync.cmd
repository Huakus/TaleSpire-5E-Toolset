@echo off
setlocal EnableExtensions DisableDelayedExpansion

rem === Config ===
set "REPO1=%USERPROFILE%\AppData\LocalLow\BouncyRock Entertainment\TaleSpire\Symbiotes\Toolset"
set "REMOTE1=https://github.com/Huakus/TaleSpire-5E-Toolset"
set "INTERVAL=10"
set "BRANCH=main"
set "GIT=%ProgramFiles%\Git\cmd\git.exe"
if not exist "%GIT%" set "GIT=%ProgramFiles(x86)%\Git\cmd\git.exe"
if not exist "%GIT%" set "GIT=%LOCALAPPDATA%\Programs\Git\cmd\git.exe"
if not exist "%GIT%" set "GIT=git"

set "PSFILE=%TEMP%\talespire-sync.ps1"

break > "%PSFILE%"

>>"%PSFILE%" echo $ErrorActionPreference = 'Continue'
>>"%PSFILE%" echo $Git = "%GIT%"
>>"%PSFILE%" echo $Repo1 = "%REPO1%"
>>"%PSFILE%" echo $Remote1 = "%REMOTE1%"
>>"%PSFILE%" echo $Interval = %INTERVAL%
>>"%PSFILE%" echo $Branch = 'main'
>>"%PSFILE%" echo $Proc = 'TaleSpire'
>>"%PSFILE%" echo $script:lastInline = $false
>>"%PSFILE%" echo(

>>"%PSFILE%" echo function Write-Log([string]^$Message,[switch]^$Inline){
>>"%PSFILE%" echo ^    if(^$Inline){
>>"%PSFILE%" echo ^        Write-Host -NoNewline ^$Message
>>"%PSFILE%" echo ^        ^$script:lastInline = ^$true
>>"%PSFILE%" echo ^    } else {
>>"%PSFILE%" echo ^        if(^$script:lastInline){ Write-Host '' }
>>"%PSFILE%" echo ^        Write-Host ^$Message
>>"%PSFILE%" echo ^        ^$script:lastInline = ^$false
>>"%PSFILE%" echo ^    }
>>"%PSFILE%" echo }
>>"%PSFILE%" echo
>>"%PSFILE%" echo Write-Host ('Sincronizando {0} (rama {1})' -f ^$Repo1,^$Branch)

rem === PowerShell ===
>>"%PSFILE%" echo function Ensure-Repo([string]^$Repo, [string]^$Remote, [string]^$Branch) {
>>"%PSFILE%" echo ^    if (Test-Path (Join-Path ^$Repo '.git'^)) {
>>"%PSFILE%" echo ^        Write-Host ('Verificando rama {0} en {1}' -f ^$Branch,^$Repo)
>>"%PSFILE%" echo ^        try {
>>"%PSFILE%" echo ^            ^& ^$Git -C ^$Repo checkout ^$Branch 2^>^&1 ^> ^$null
>>"%PSFILE%" echo ^        } catch {
>>"%PSFILE%" echo ^            Write-Host ('Creando rama local {0}' -f ^$Branch)
>>"%PSFILE%" echo ^            ^& ^$Git -C ^$Repo checkout -b ^$Branch
>>"%PSFILE%" echo ^        }
>>"%PSFILE%" echo ^        return
>>"%PSFILE%" echo ^    }
>>"%PSFILE%" echo ^    Write-Host ('Inicializando nuevo repo en {0}' -f ^$Repo)
>>"%PSFILE%" echo ^    if (-not (Test-Path ^$Repo^)) { New-Item -ItemType Directory -Force -Path ^$Repo ^| Out-Null }
>>"%PSFILE%" echo ^    ^& ^$Git -C ^$Repo init
>>"%PSFILE%" echo ^    try { ^& ^$Git -C ^$Repo remote remove origin } catch {}
>>"%PSFILE%" echo ^    ^& ^$Git -C ^$Repo remote add origin ^$Remote
>>"%PSFILE%" echo ^    ^& ^$Git -C ^$Repo checkout -b ^$Branch
>>"%PSFILE%" echo ^    Write-Host ('Repo {0} listo en rama {1}' -f ^$Repo,^$Branch)
>>"%PSFILE%" echo }

>>"%PSFILE%" echo(
>>"%PSFILE%" echo function Sync([string]^$Repo,[string]^$Branch){
>>"%PSFILE%" echo ^    if (-not (Test-Path (Join-Path ^$Repo '.git'^))) { Write-Host ('No es repo git: {0}' -f ^$Repo); return }
>>"%PSFILE%" echo ^    ^$headBefore = ^& ^$Git -C ^$Repo rev-parse HEAD
>>"%PSFILE%" echo ^    try { ^& ^$Git -C ^$Repo fetch origin ^> ^$null 2^>^&1 } catch {}
>>"%PSFILE%" echo ^    ^$remoteAhead = 0
>>"%PSFILE%" echo ^    try { ^$remoteAhead = [int](^& ^$Git -C ^$Repo rev-list --count HEAD..origin/^$Branch) } catch {}
>>"%PSFILE%" echo ^    ^& ^$Git -C ^$Repo add -A ^> ^$null 2^>^&1
>>"%PSFILE%" echo ^    ^$dirty = ^& ^$Git -C ^$Repo status --porcelain
>>"%PSFILE%" echo ^    if (^$dirty) { ^& ^$Git -C ^$Repo commit --quiet -m ('auto: ' + (Get-Date -Format o^)) }
>>"%PSFILE%" echo ^    try { ^& ^$Git -C ^$Repo pull --rebase --autostash origin ^$Branch ^> ^$null 2^>^&1 } catch {}
>>"%PSFILE%" echo ^    try { ^& ^$Git -C ^$Repo push -u origin ^$Branch ^> ^$null 2^>^&1 } catch {}
>>"%PSFILE%" echo ^    ^$headAfter = ^& ^$Git -C ^$Repo rev-parse HEAD
>>"%PSFILE%" echo ^    ^$received = ^$remoteAhead -gt 0
>>"%PSFILE%" echo ^    if (^$dirty -or ^$received -or (^$headAfter -ne ^$headBefore)) {
>>"%PSFILE%" echo ^        ^$parts = @()
>>"%PSFILE%" echo ^        if (^$dirty) { ^$parts += 'enviados cambios locales' }
>>"%PSFILE%" echo ^        if (^$received) { ^$parts += ('recibidos {0} commit(s) remotos' -f ^$remoteAhead) }
>>"%PSFILE%" echo ^        if (^$parts.Count -eq 0) { ^$parts += 'cambios aplicados' }
>>"%PSFILE%" echo ^        Write-Log ('Sincronizado {0} (rama {1}) - {2}' -f ^$Repo,^$Branch,(^$parts -join '; '))
>>"%PSFILE%" echo ^    } else {
>>"%PSFILE%" echo ^        Write-Log '.' -Inline
>>"%PSFILE%" echo ^    }
>>"%PSFILE%" echo }

>>"%PSFILE%" echo(
>>"%PSFILE%" echo Ensure-Repo -Repo ^$Repo1 -Remote ^$Remote1 -Branch ^$Branch

>>"%PSFILE%" echo(
 >>"%PSFILE%" echo Sync -Repo ^$Repo1 -Branch ^$Branch

>>"%PSFILE%" echo(
>>"%PSFILE%" echo Start-Process 'steam://rungameid/720620'
>>"%PSFILE%" echo ^$appeared=^$false
>>"%PSFILE%" echo for(^$i=0;^$i -lt 30;^$i++^){ if(Get-Process -Name ^$Proc -ErrorAction SilentlyContinue^){ ^$appeared=^$true; break } Start-Sleep -Seconds 1 }
>>"%PSFILE%" echo if(^$appeared^){
>>"%PSFILE%" echo ^  while (Get-Process -Name ^$Proc -ErrorAction SilentlyContinue^) {
>>"%PSFILE%" echo ^    Start-Sleep -Seconds ^$Interval
 >>"%PSFILE%" echo ^    Sync -Repo ^$Repo1 -Branch ^$Branch
>>"%PSFILE%" echo ^  }
>>"%PSFILE%" echo }
 >>"%PSFILE%" echo Sync -Repo ^$Repo1 -Branch ^$Branch

rem === Ejecutar PowerShell ===
call powershell -NoProfile -ExecutionPolicy Bypass -File "%PSFILE%"
set "EXITCODE=%ERRORLEVEL%"

rem === Mantener consola mientras TaleSpire esté abierto ===
:wait_for_talespire_exit
tasklist /FI "IMAGENAME eq TaleSpire.exe" | find /I "TaleSpire.exe" >nul
if not errorlevel 1 (
  timeout /t 5 >nul
  goto wait_for_talespire_exit
)

if not "%EXITCODE%"=="0" (
  echo ❌ Hubo un error (exit code %EXITCODE%).
) else (
  echo ✅ TaleSpire cerrado. Sincronización finalizada correctamente en rama MAIN.
)
timeout /t 2 >nul
exit
