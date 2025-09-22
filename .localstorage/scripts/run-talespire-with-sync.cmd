@echo off
setlocal
rem --- Repo del Symbiote (ajusta si tu carpeta no es esta) ---
set "REPO=%USERPROFILE%\AppData\LocalLow\BouncyRock Entertainment\TaleSpire\Symbiotes\Toolset"

rem --- Detectar git.exe en rutas comunes (fallback a 'git' si ya está en PATH) ---
set "GIT=%ProgramFiles%\Git\cmd\git.exe"
if not exist "%GIT%" set "GIT=%ProgramFiles(x86)%\Git\cmd\git.exe"
if not exist "%GIT%" set "GIT=%LOCALAPPDATA%\Programs\Git\cmd\git.exe"
if not exist "%GIT%" set "GIT=git"

rem --- Intervalo de sync (segundos): 180 = 3 minutos (dejé 10 para probar) ---
set "INTERVAL=180"

powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$ErrorActionPreference='SilentlyContinue';" ^
  "$Git = '%GIT%'; $Repo = '%REPO%'; $Interval = %INTERVAL%; $Proc='TaleSpire';" ^
  "try { $Branch = (& $Git -C $Repo rev-parse --abbrev-ref HEAD).Trim() } catch { $Branch = 'main' };" ^
  "if (-not $Branch) { $Branch = 'main' };" ^
  "function Sync { param($Repo,$Git,$Branch) & $Git -C $Repo add -A *> $null; if ((& $Git -C $Repo status --porcelain).Length -gt 0) { & $Git -C $Repo commit -m ('auto: ' + (Get-Date -Format o)) *> $null }; & $Git -C $Repo fetch origin *> $null; & $Git -C $Repo pull --rebase --autostash origin $Branch *> $null; & $Git -C $Repo push origin $Branch *> $null };" ^
  "Sync $Repo $Git $Branch;" ^
  "Start-Process 'steam://rungameid/720620';" ^
  "$appeared=$false; for($i=0;$i -lt 30;$i++){ if(Get-Process -Name $Proc -ErrorAction SilentlyContinue){ $appeared=$true; break } Start-Sleep -Seconds 1 }" ^
  "if($appeared){ while (Get-Process -Name $Proc -ErrorAction SilentlyContinue) { Start-Sleep -Seconds $Interval; if (Get-Process -Name $Proc -ErrorAction SilentlyContinue) { Sync $Repo $Git $Branch } } }" ^
  "Sync $Repo $Git $Branch"

endlocal
