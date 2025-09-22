<#  
  symbiotes-git-watcher.ps1
  Watcher Git: add/commit (solo si hay cambios) + pull(rebase) + push
  - auto-cura origin/HEAD
  - heartbeat 1 minuto
  - debounce 3s con Register-ObjectEvent (confiable)
  - sin logs a disco
  - flags: -Once (una corrida) y -VerboseMode (salida a consola)
#>

param(
  [switch]$Once,
  [switch]$VerboseMode
)

function Say($m){ if($VerboseMode){ Write-Host ("[{0}] {1}" -f (Get-Date -Format HH:mm:ss), $m) } }

# --- Descubrir rutas y rama automáticamente ---
$ScriptsDir = $PSScriptRoot
$Repo = (Resolve-Path (Join-Path $ScriptsDir "..")).Path

try {
  $Branch = (git -C $Repo rev-parse --abbrev-ref HEAD) -replace '\s+$',''
  if (-not $Branch) { $Branch = "main" }
} catch { $Branch = "main" }

$ErrorActionPreference = "SilentlyContinue"
Say "Repo: $Repo | Branch: $Branch"

# --- Auto-curar problemas con origin/HEAD ---
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
  Say "Auto-cura origin/HEAD aplicada."
} catch { Say ("Auto-cura origin/HEAD: " + $_.Exception.Message) }

# --- Ajustes útiles de Git ---
git -C $Repo config pull.rebase true       2>$null | Out-Null
git -C $Repo config rebase.autoStash true  2>$null | Out-Null

# --- Función de sincronización (sin commits vacíos) ---
function Sync-Git {
  try {
    Say "SYNC start"
    git -C $Repo add -A 2>$null | Out-Null

    if (git -C $Repo status --porcelain 2>$null) {
      Say "Committing changes…"
      git -C $Repo commit -m "auto: $(Get-Date -Format o)" 2>$null | Out-Null
    } else {
      Say "No local changes to commit."
    }

    Say "Fetching…"
    git -C $Repo fetch origin 2>$null | Out-Null
    Say "Pulling (rebase)…"
    git -C $Repo pull --rebase --autostash origin $Branch 2>$null | Out-Null
    Say "Pushing…"
    git -C $Repo push origin $Branch 2>$null | Out-Null
    Say "SYNC ok"
  } catch {
    Say ("SYNC error: " + $_.Exception.Message)
  }
}

# --- Debounce confiable (3s) con Register-ObjectEvent ---
$timer = New-Object System.Timers.Timer
$timer.Interval = 3000
$timer.AutoReset = $false
# Suscripción explícita para que el handler viva
$timerSub = Register-ObjectEvent -InputObject $timer -EventName Elapsed -Action {
  # Este bloque corre en otro runspace; llamamos a Sync-Git por nombre (está en el global scope del host)
  Sync-Git
  Write-Host ([string]::Format("[{0}] Debounce → Sync", (Get-Date).ToString("HH:mm:ss"))) | Out-Null
}
$timer.Start() | Out-Null
$timer.Stop()  | Out-Null  # arranca parado; lo rearmamos en cada evento

# --- Watcher de archivos ---
$fsw = New-Object System.IO.FileSystemWatcher
$fsw.Path  = $Repo
$fsw.IncludeSubdirectories = $true
$fsw.Filter = "*.*"
# Opcional: más señales
$fsw.NotifyFilter = [IO.NotifyFilters]'FileName, DirectoryName, LastWrite, LastAccess, Size, Attributes, Security, CreationTime'
$fsw.EnableRaisingEvents = $true

# Ignorar por path (más fuerte que regex)
$gitDir     = (Join-Path $Repo ".git")
$scriptsDir = (Join-Path $Repo "scripts")

$ignoreRegexes = @("\.tmp$", "\.lock$", "sync-conflict-")

$action = {
  param($source, $eventArgs)
  $path = $eventArgs.FullPath

  # Ignorar todo lo bajo .git\ y scripts\ (incluye este mismo archivo)
  if ($path.StartsWith($gitDir, [System.StringComparison]::OrdinalIgnoreCase)) { return }
  if ($path.StartsWith($scriptsDir, [System.StringComparison]::OrdinalIgnoreCase)) { return }

  foreach($r in $ignoreRegexes){ if ($path -match $r) { return } }

  Write-Host ("[{0}] Evento: {1} → {2}" -f (Get-Date).ToString("HH:mm:ss"), $eventArgs.ChangeType, $path) | Out-Null

  # Rearmar debounce
  $timer.Stop() | Out-Null
  $timer.Start() | Out-Null
}

$eh1 = Register-ObjectEvent $fsw Created -Action $action
$eh2 = Register-ObjectEvent $fsw Changed -Action $action
$eh3 = Register-ObjectEvent $fsw Renamed -Action $action
$eh4 = Register-ObjectEvent $fsw Deleted -Action $action

# --- Heartbeat (cada 1 min) ---
$hb = New-Object System.Timers.Timer
$hb.Interval = 60 * 1000
$hb.AutoReset = $true
$hbSub = Register-ObjectEvent -InputObject $hb -EventName Elapsed -Action { Sync-Git; Write-Host ("[{0}] Heartbeat → Sync" -f (Get-Date).ToString("HH:mm:ss")) | Out-Null }
$hb.Start()

# --- Sync inicial + loop / one-shot ---
Sync-Git
if ($Once) { Say "Once mode: done."; return }

Say "Watcher iniciado. Escuchando cambios…"
while ($true) { Start-Sleep -Seconds 5 }
