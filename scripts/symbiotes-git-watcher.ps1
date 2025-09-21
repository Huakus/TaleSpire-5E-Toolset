<#  
  symbiotes-git-watcher.ps1
  Ubicación esperada: <Symbiote>\scripts\symbiotes-git-watcher.ps1
  Vigila el repo del Symbiote (carpeta padre de /scripts) y hace add/commit/pull(rebase)/push automáticos.
#>

# --- Descubrir rutas y rama automáticamente ---
$ScriptsDir = $PSScriptRoot
$Repo = (Resolve-Path (Join-Path $ScriptsDir "..")).Path

# Detectar rama actual; si falla, usar "main"
try {
  $Branch = (git -C $Repo rev-parse --abbrev-ref HEAD).Trim()
  if (-not $Branch) { $Branch = "main" }
} catch { $Branch = "main" }

# --- Auto-curar problemas con origin/HEAD ---
try {
  git -C $Repo fetch --all --prune | Out-Null
  git -C $Repo remote set-head origin -a | Out-Null
  git -C $Repo branch -u origin/$Branch $Branch | Out-Null
} catch { }

# --- Logging dentro del repo ---
$LogDir = Join-Path $Repo "scripts\logs"
$Log    = Join-Path $LogDir "git-watcher.log"
New-Item -Force -ItemType Directory -Path $LogDir | Out-Null
function Log($msg){
  $ts = Get-Date -Format o
  "$ts  $msg" | Out-File -FilePath $Log -Append -Encoding utf8
}

$ErrorActionPreference = "Continue"

# --- Ajustes útiles de Git ---
git -C $Repo config pull.rebase true       | Out-Null
git -C $Repo config rebase.autoStash true  | Out-Null

# --- Función de sincronización completa ---
function Sync-Git {
  try {
    Log "SYNC start"

    git -C $Repo add -A | Out-Null

    # Solo hace commit si realmente hay cambios
    if (git -C $Repo status --porcelain) {
      git -C $Repo commit -m "auto: $(Get-Date -Format o)" | Out-Null
    }

    git -C $Repo fetch origin       | Out-Null
    git -C $Repo pull --rebase --autostash origin $Branch | Out-Null
    git -C $Repo push origin $Branch | Out-Null

    Log "SYNC ok"
  }
  catch {
    Log "SYNC error: $($_.Exception.Message)"
  }
}

# --- Debounce (agrupar eventos) ---
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
  $timer.Stop()
  $timer.Start()
}

Register-ObjectEvent $fsw Created -Action $action  | Out-Null
Register-ObjectEvent $fsw Changed -Action $action  | Out-Null
Register-ObjectEvent $fsw Renamed -Action $action  | Out-Null
Register-ObjectEvent $fsw Deleted -Action $action  | Out-Null

# --- Heartbeat (seguro cada 5 minutos) ---
$hb = New-Object System.Timers.Timer
$hb.Interval = 5 * 60 * 1000
$hb.AutoReset = $true
$hb.add_Elapsed({ Sync-Git })
$hb.Start()

# --- Sync inicial + loop ---
Sync-Git
Log "Watcher iniciado. Repo: $Repo | Rama: $Branch"
while ($true) { Start-Sleep -Seconds 5 }
