<#  
  symbiotes-git-watcher.ps1  (sin logs)
  Ubicación: <Symbiote>\scripts\symbiotes-git-watcher.ps1
  Watcher Git: add/commit (solo si hay cambios)/pull(rebase)/push automáticos
  + auto-cura de refs rotas de origin/HEAD
#>

# --- Descubrir rutas y rama automáticamente ---
$ScriptsDir = $PSScriptRoot
$Repo = (Resolve-Path (Join-Path $ScriptsDir "..")).Path

# Detectar rama actual; si falla, usar "main"
try {
  $Branch = (git -C $Repo rev-parse --abbrev-ref HEAD) -replace '\s+$',''
  if (-not $Branch) { $Branch = "main" }
} catch { $Branch = "main" }

$ErrorActionPreference = "SilentlyContinue"

# --- Auto-curar problemas con origin/HEAD (robusto, sin salida) ---
try { git -C $Repo update-ref -d refs/remotes/origin/HEAD 2>$null | Out-Null } catch { }
try {
  $headRefFile = Join-Path $Repo ".git\refs\remotes\origin\HEAD"
  if (Test-Path $headRefFile) { Remove-Item $headRefFile -Force -ErrorAction SilentlyContinue }
} catch { }
try {
  git -C $Repo fetch --all --prune 2>$null | Out-Null
  git -C $Repo remote set-head origin $Branch 2>$null | Out-Null
  git -C $Repo branch -u origin/$Branch $Branch 2>$null | Out-Null
  git -C $Repo symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/$Branch 2>$null | Out-Null
} catch { }

# --- Ajustes útiles de Git ---
git -C $Repo config pull.rebase true       2>$null | Out-Null
git -C $Repo config rebase.autoStash true  2>$null | Out-Null

# --- Función de sincronización completa (sin commits vacíos) ---
function Sync-Git {
  try {
    git -C $Repo add -A 2>$null | Out-Null

    # Commit solo si hay cambios reales
    if (git -C $Repo status --porcelain 2>$null) {
      git -C $Repo commit -m "auto: $(Get-Date -Format o)" 2>$null | Out-Null
    }

    git -C $Repo fetch origin                              2>$null | Out-Null
    git -C $Repo pull --rebase --autostash origin $Branch  2>$null | Out-Null
    git -C $Repo push origin $Branch                       2>$null | Out-Null
  } catch { }
}

# --- Debounce (agrupar eventos ~2s) ---
$timer = New-Object System.Timers.Timer
$timer.Interval = 2000
$timer.AutoReset = $false
$timer.add_Elapsed({ Sync-Git })

# --- Watcher de archivos (ignora .git, tmp, locks y sync-conflict) ---
$fsw = New-Object System.IO.FileSystemWatcher
$fsw.Path  = $Repo
$fsw.IncludeSubdirectories = $true
$fsw.Filter = "*.*"
$fsw.EnableRaisingEvents = $true

$ignoreRegexes = @("\.git(\\|/)", "\.tmp$", "\.lock$", "sync-conflict-")

$action = {
  param($source, $eventArgs)
  $path = $eventArgs.FullPath
  foreach($r in $ignoreRegexes){ if ($path -match $r) { return } }
  $timer.Stop(); $timer.Start()
}

Register-ObjectEvent $fsw Created -Action $action  | Out-Null
Register-ObjectEvent $fsw Changed -Action $action  | Out-Null
Register-ObjectEvent $fsw Renamed -Action $action  | Out-Null
Register-ObjectEvent $fsw Deleted -Action $action  | Out-Null

# --- Heartbeat (por si se pierde un evento) cada 5 min ---
$hb = New-Object System.Timers.Timer
$hb.Interval = 5 * 60 * 1000
$hb.AutoReset = $true
$hb.add_Elapsed({ Sync-Git })
$hb.Start()

# --- Sync inicial + loop ---
Sync-Git
while ($true) { Start-Sleep -Seconds 5 }
