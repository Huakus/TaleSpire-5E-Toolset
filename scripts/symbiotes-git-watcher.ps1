<# 
  symbiotes-git-heartbeat.ps1
  Cada 3 minutos: pull desde origin y, si hay cambios locales, commit + push.
  Sin watcher, sin logs, sin commits vacíos. Auto-cura origin/HEAD.
#>

param(
  [switch]$Once,
  [switch]$VerboseMode
)

function Say($m){ if($VerboseMode){ Write-Host ("[{0}] {1}" -f (Get-Date -Format HH:mm:ss), $m) } }

# --- Asegurar GIT en PATH para el contexto del Programador de Tareas ---
$gitCandidates = @(
  "$env:ProgramFiles\Git\cmd",
  "$env:ProgramFiles\Git\bin",
  "$env:ProgramFiles(x86)\Git\cmd",
  "$env:ProgramFiles(x86)\Git\bin",
  "$env:LOCALAPPDATA\Programs\Git\cmd",
  "$env:LOCALAPPDATA\Programs\Git\bin"
) | Where-Object { Test-Path $_ }

foreach ($dir in $gitCandidates) {
  if ($env:Path -notlike "*$dir*") { $env:Path = "$dir;$env:Path" }
}

if (-not (Get-Command git.exe -ErrorAction SilentlyContinue)) {
  Say "ERROR: git.exe no encontrado en PATH"
  exit 1
}

# --- Repo y rama (relativo a /scripts) ---
$ScriptsDir = $PSScriptRoot
$Repo = (Resolve-Path (Join-Path $ScriptsDir "..")).Path
try {
  $Branch = (git -C $Repo rev-parse --abbrev-ref HEAD) -replace '\s+$',''
  if (-not $Branch) { $Branch = "main" }
} catch { $Branch = "main" }
$ErrorActionPreference = "SilentlyContinue"
Say "Repo: $Repo | Branch: $Branch"

# --- Auto-cura origin/HEAD y ajustes útiles ---
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

git -C $Repo config pull.rebase true       2>$null | Out-Null
git -C $Repo config rebase.autoStash true  2>$null | Out-Null

function Sync-Git {
  try {
    Say "Sync → fetch/pull; commit+push si hay cambios"

    # 1) Preparar cambios locales
    git -C $Repo add -A 2>$null | Out-Null
    if (git -C $Repo status --porcelain 2>$null) {
      Say "Hay cambios locales → commit"
      git -C $Repo commit -m "auto: $(Get-Date -Format o)" 2>$null | Out-Null
    } else {
      Say "Sin cambios locales"
    }

    # 2) Pull remoto
    Say "Fetching…"
    git -C $Repo fetch origin 2>$null | Out-Null
    Say "Pull (rebase)…"
    git -C $Repo pull --rebase --autostash origin $Branch 2>$null | Out-Null

    # 3) Push remoto
    Say "Push…"
    git -C $Repo push origin $Branch 2>$null | Out-Null

    Say "OK"
  } catch {
    Say ("Error: " + $_.Exception.Message)
  }
}

# --- Un ciclo o loop cada 3 minutos ---
Sync-Git
if ($Once) { Say "Once: done"; exit 0 }

while ($true) {
  Start-Sleep -Seconds 180   # 3 minutos
  Sync-Git
}
