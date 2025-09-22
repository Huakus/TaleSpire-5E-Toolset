<#  
  symbiotes-git-watcher.ps1
  Ubicación: <Symbiote>\scripts\symbiotes-git-watcher.ps1

  Watcher Git:
  - add/commit (solo si hay cambios)/pull(rebase)/push automáticos
  - auto-cura de refs rotas de origin/HEAD
  - heartbeat cada 1 minuto
  - debounce 3 segundos
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

# --- Auto-curar problemas con origin/HEAD (robusto, sin salida salvo Verbose) ---
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

# --- Función de sincronización completa (sin commits vacíos) ---
function Sync-Git {
  try {
    Say "SYNC start"
    git -C $Repo add -A 2>$null | Out-Null

    if (git -C $Repo status --porcelain 2>$null) {
      Say "Commiting changes…"
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

# --- Debounce (agrupar eventos ~3s) ---
$timer = New-Object System.Timers.Timer
$timer.Interval = 3000
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
  Say ("Evento: " + $eventArgs.ChangeType + " → " + $path)
  $timer.Stop(); $timer.Start()
}

Register-ObjectEvent $fsw Created -Action $action  | Out-Null
Register-ObjectEvent $fsw Changed -Action $action  | Out-Null
Register-ObjectEvent $fsw Renamed -Action $action  | Out-Null
Register-ObjectEvent $fsw Deleted -Action $action  | Out-Null

# --- Heartbeat (por si se pierde un evento) cada 1 min ---
$hb = New-Object System.Timers.Timer
$hb.Interval = 60 * 1000
$hb.AutoReset = $true
$hb.add_Elapsed({ Say "Heartbeat → Sync"; Sync-Git })
$hb.Start()

# --- Sync inicial + loop / one-shot ---
Sync-Git
if ($Once) { Say "Once mode: done."; return }

Say "Watcher iniciado. Escuchando cambios…"
while ($true) { Start-Sleep -Seconds 5 }
