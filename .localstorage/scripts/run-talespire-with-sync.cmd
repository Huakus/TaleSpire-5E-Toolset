@echo off
setlocal
rem --- Repos (ajusta si tus carpetas no son estas) ---
set "REPO1=%USERPROFILE%\AppData\LocalLow\BouncyRock Entertainment\TaleSpire\Symbiotes\Toolset"
set "REPO2=%USERPROFILE%\AppData\LocalLow\BouncyRock Entertainment\TaleSpire\LocalContentPacks"

rem --- Remotos ---
set "REMOTE1=https://github.com/Huakus/TaleSpire-5E-Toolset"
set "REMOTE2=https://github.com/Huakus/TaleSpire_LocalContentPacks"

rem --- Detectar git.exe en rutas comunes (fallback a 'git' si ya está en PATH) ---
set "GIT=%ProgramFiles%\Git\cmd\git.exe"
if not exist "%GIT%" set "GIT=%ProgramFiles(x86)%\Git\cmd\git.exe"
if not exist "%GIT%" set "GIT=%LOCALAPPDATA%\Programs\Git\cmd\git.exe"
if not exist "%GIT%" set "GIT=git"

rem --- Intervalo de sync (segundos) ---
set "INTERVAL=10"

powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$ErrorActionPreference='SilentlyContinue';" ^
  "$Git = '%GIT%';" ^
  "$Repo1 = '%REPO1%'; $Remote1 = '%REMOTE1%';" ^
  "$Repo2 = '%REPO2%'; $Remote2 = '%REMOTE2%';" ^
  "$Interval = %INTERVAL%; $Proc='TaleSpire';" ^

  "function Get-DefaultBranch { param([string]$Remote) $b='main'; try { $refs=& $Git ls-remote --symref $Remote HEAD 2>$null; if($refs -match 'refs/heads/([^ ]+)'){ $b=$matches[1] } elseif((& $Git ls-remote --heads $Remote) -match 'refs/heads/master'){ $b='master' } } catch {} ; return $b }" ^

  "function Ensure-Repo { param([string]$Repo,[string]$Remote)" ^
  "  if (Test-Path (Join-Path $Repo '.git')) { return }" ^
  "  if (-not (Test-Path $Repo)) { New-Item -ItemType Directory -Force -Path $Repo | Out-Null }" ^
  "  $hasFiles = (Get-ChildItem -Path $Repo -Force | Where-Object { $_.Name -ne '.git' } | Measure-Object).Count -gt 0" ^
  "  $defaultBranch = Get-DefaultBranch -Remote $Remote" ^
  "  if (-not $hasFiles) {" ^
  "    & $Git clone $Remote $Repo *> $null" ^
  "  } else {" ^
  "    & $Git -C $Repo init *> $null" ^
  "    try { & $Git -C $Repo remote remove origin *> $null } catch {}" ^
  "    & $Git -C $Repo remote add origin $Remote *> $null" ^
  "    & $Git -C $Repo fetch origin *> $null" ^
  "    try { & $Git -C $Repo rev-parse --verify $defaultBranch *> $null } catch { & $Git -C $Repo checkout -b $defaultBranch *> $null }" ^
  "    & $Git -C $Repo branch --set-upstream-to=origin/$defaultBranch $defaultBranch *> $null" ^
  "    & $Git -C $Repo pull --rebase --autostash --allow-unrelated-histories origin $defaultBranch *> $null" ^
  "  }" ^
  "}" ^

  "function Get-Branch { param([string]$Repo) try { (& $Git -C $Repo rev-parse --abbrev-ref HEAD).Trim() } catch { '' } }" ^
  "function Sync { param([string]$Repo,[string]$Branch)" ^
  "  if (-not (Test-Path (Join-Path $Repo '.git'))) { return }" ^
  "  if ([string]::IsNullOrWhiteSpace($Branch)) { $Branch='main' }" ^
  "  & $Git -C $Repo add -A *> $null;" ^
  "  if ((& $Git -C $Repo status --porcelain).Length -gt 0) { & $Git -C $Repo commit -m ('auto: ' + (Get-Date -Format o)) *> $null }" ^
  "  & $Git -C $Repo fetch origin *> $null;" ^
  "  & $Git -C $Repo pull --rebase --autostash origin $Branch *> $null;" ^
  "  & $Git -C $Repo push origin $Branch *> $null" ^
  "}" ^

  "Ensure-Repo -Repo $Repo1 -Remote $Remote1;" ^
  "Ensure-Repo -Repo $Repo2 -Remote $Remote2;" ^

  "$Repos = @($Repo1,$Repo2) | Where-Object { $_ -and (Test-Path $_) };" ^
  "$Branches = @{}; foreach($r in $Repos){ $b = Get-Branch -Repo $r; if([string]::IsNullOrWhiteSpace($b)){ $b = (Get-DefaultBranch -Remote ((& $Git -C $r remote get-url origin) 2>$null)); if([string]::IsNullOrWhiteSpace($b)){ $b='main' } } $Branches[$r]=$b }" ^

  "foreach($r in $Repos){ Sync -Repo $r -Branch $Branches[$r] }" ^
  "Start-Process 'steam://rungameid/720620';" ^
  "$appeared=$false; for($i=0;$i -lt 30;$i++){ if(Get-Process -Name $Proc -ErrorAction SilentlyContinue){ $appeared=$true; break } Start-Sleep -Seconds 1 }" ^
  "if($appeared){ while (Get-Process -Name $Proc -ErrorAction SilentlyContinue) { Start-Sleep -Seconds $Interval; if (Get-Process -Name $Proc -ErrorAction SilentlyContinue) { foreach($r in $Repos){ Sync -Repo $r -Branch $Branches[$r] } } } }" ^
  "foreach($r in $Repos){ Sync -Repo $r -Branch $Branches[$r] }"

endlocal
