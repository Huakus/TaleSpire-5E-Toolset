<#
.SYNOPSIS
Sincroniza el repo Toolset con Git.

.DESCRIPTION
Modo nuevo recomendado:
- Ejecutar desde 2_orquestrator.ps1 con -RunOnce -Quiet.
- El script no maneja el tick cuando se usa -RunOnce.

Compatibilidad:
- Si se ejecuta sin -RunOnce, mantiene el modo worker anterior con IntervalSeconds y StopSignalFile.

Mejoras:
- Evita multiples sync de Git corriendo al mismo tiempo mediante lock file.
- Hace retry automatico del push si GitHub rechaza por cambio remoto concurrente.
- Antes de cada push reintenta fetch + rebase.
#>

param(
    [string]$StopSignalFile,
    [int]$IntervalSeconds = 10,
    [switch]$RunOnce,
    [switch]$Quiet,
    [switch]$NoPauseOnError,
    [string]$Branch = 'main'
)

$ErrorActionPreference = 'Stop'

# ============================================================
# Paths base
# ============================================================

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$CommonLoggingScript = Join-Path $ScriptDir '0_common-logging.ps1'

. $CommonLoggingScript

Initialize-Logging -ScriptPath $PSCommandPath

$LocalStorageDir = Split-Path -Parent $ScriptDir

# ============================================================
# Helpers generales
# ============================================================

function Wait-BeforeExitOnError {
    if (-not $NoPauseOnError) {
        Write-Host ''
        Write-Log 'Presiona una tecla para cerrar esta ventana...'
        [void][System.Console]::ReadKey($true)
    }
}

function Test-ShouldStop {
    return ($StopSignalFile -and (Test-Path -LiteralPath $StopSignalFile))
}

function Invoke-Git {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,

        [switch]$AllowFailure
    )

    # En Windows PowerShell 5.1, stderr puede disparar NativeCommandError si
    # $ErrorActionPreference = 'Stop', incluso con ExitCode 0.
    # Para Git decidimos por ExitCode y tratamos stderr como texto capturable.
    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'

    try {
        $rawOutput = & git -C $script:RepoRoot @Arguments 2>&1
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }

    $output = @()

    foreach ($item in @($rawOutput)) {
        if ($null -ne $item) {
            $text = $item.ToString()

            if (-not [string]::IsNullOrWhiteSpace($text)) {
                $output += $text
            }
        }
    }

    $joined = ($output -join "`n").Trim()

    if ($exitCode -ne 0 -and -not $AllowFailure) {
        throw "git $($Arguments -join ' ') fallo con codigo $exitCode. $joined"
    }

    return [PSCustomObject]@{
        ExitCode = $exitCode
        Output   = @($output)
        Text     = $joined
    }
}

function Get-RepoRoot {
    $result = & git -C $LocalStorageDir rev-parse --show-toplevel 2>$null

    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($result)) {
        return [string]$result
    }

    return (Split-Path -Parent $LocalStorageDir)
}

function Get-GitStatusLines {
    $result = Invoke-Git -Arguments @('status', '--porcelain')

    return @(
        $result.Output |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )
}

function Get-CurrentHead {
    return (Invoke-Git -Arguments @('rev-parse', 'HEAD')).Text.Trim()
}

function Write-StatusSummary {
    param(
        [string[]]$StatusLines
    )

    foreach ($line in $StatusLines) {
        Write-Log (" local: {0}" -f $line)
    }

    $diff = Invoke-Git -Arguments @('diff', '--stat')

    foreach ($line in $diff.Output) {
        if (-not [string]::IsNullOrWhiteSpace($line)) {
            Write-Log (" diff: {0}" -f $line)
        }
    }
}

function Ensure-Branch {
    $currentBranch = (Invoke-Git -Arguments @('branch', '--show-current')).Text.Trim()

    if ($currentBranch -ne $Branch) {
        Write-Log ("Cambiando rama {0} -> {1}" -f $currentBranch, $Branch)
        [void](Invoke-Git -Arguments @('checkout', $Branch))
    }
}

# ============================================================
# Lock anti multiples sync
# ============================================================

function Get-RepoLockFile {
    $normalizedRepoRoot = $script:RepoRoot.ToLowerInvariant()
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($normalizedRepoRoot)

    $sha = [System.Security.Cryptography.SHA256]::Create()
    $hashBytes = $sha.ComputeHash($bytes)

    $hash = -join ($hashBytes | ForEach-Object { $_.ToString('x2') })
    $shortHash = $hash.Substring(0, 16)

    return (Join-Path $env:TEMP "talespire-toolset-git-sync-$shortHash.lock")
}

function Test-ProcessAlive {
    param(
        [int]$ProcessId
    )

    try {
        $process = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
        return ($null -ne $process)
    }
    catch {
        return $false
    }
}

function Acquire-GitSyncLock {
    $script:LockFile = Get-RepoLockFile
    $script:LockOwned = $false

    if (Test-Path -LiteralPath $script:LockFile) {
        $existingPidText = ''

        try {
            $existingPidText = (Get-Content -LiteralPath $script:LockFile -ErrorAction SilentlyContinue | Select-Object -First 1)
        }
        catch {
            $existingPidText = ''
        }

        $existingPid = 0

        if ([int]::TryParse($existingPidText, [ref]$existingPid)) {
            if (Test-ProcessAlive -ProcessId $existingPid) {
                Write-Log ("Ya hay un sync de Git corriendo para este repo. PID={0}. Saliendo." -f $existingPid)
                exit 0
            }
        }

        Write-Log 'Lock viejo de sync detectado. Se elimina.'
        Remove-Item -LiteralPath $script:LockFile -Force -ErrorAction SilentlyContinue
    }

    try {
        Set-Content -LiteralPath $script:LockFile -Value $PID -Encoding ASCII -Force
        $script:LockOwned = $true
    }
    catch {
        Write-Log 'No se pudo crear el lock de sync. Probablemente otro proceso lo creo primero. Saliendo.'
        exit 0
    }
}

function Release-GitSyncLock {
    if ($script:LockOwned -and $script:LockFile -and (Test-Path -LiteralPath $script:LockFile)) {
        Remove-Item -LiteralPath $script:LockFile -Force -ErrorAction SilentlyContinue
    }
}

# ============================================================
# Git sync
# ============================================================

function Invoke-GitPullQuietly {
    $before = Get-CurrentHead

    $pull = Invoke-Git -Arguments @('pull', '--rebase', '--autostash', 'origin', $Branch)

    $after = Get-CurrentHead

    if ($before -ne $after) {
        Write-Log 'RECIBIDO Toolset'

        foreach ($line in $pull.Output) {
            if (-not [string]::IsNullOrWhiteSpace($line)) {
                Write-Log (" git: {0}" -f $line)
            }
        }
    }
    elseif (-not $Quiet) {
        Write-Log 'Toolset actualizado. No hay cambios.'
    }
}

function Invoke-GitFetchAndRebase {
    $fetch = Invoke-Git -Arguments @('fetch', 'origin', $Branch)

    if (-not $Quiet) {
        foreach ($line in $fetch.Output) {
            if (-not [string]::IsNullOrWhiteSpace($line)) {
                Write-Log (" git: {0}" -f $line)
            }
        }
    }

    $remoteBranch = "origin/$Branch"

    $rebase = Invoke-Git -Arguments @('rebase', $remoteBranch) -AllowFailure

    if ($rebase.ExitCode -ne 0) {
        [void](Invoke-Git -Arguments @('rebase', '--abort') -AllowFailure)

        throw "git rebase $remoteBranch fallo con codigo $($rebase.ExitCode). $($rebase.Text)"
    }

    return $rebase
}

function Invoke-GitPushWithRetry {
    param(
        [int]$MaxAttempts = 6
    )

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        if ($attempt -gt 1) {
            $sleepSeconds = [Math]::Min(20, 2 * $attempt)
            Write-Log ("Reintentando push en {0}s. Intento {1}/{2}..." -f $sleepSeconds, $attempt, $MaxAttempts)
            Start-Sleep -Seconds $sleepSeconds
        }

        [void](Invoke-GitFetchAndRebase)

        $push = Invoke-Git -Arguments @('push', 'origin', $Branch) -AllowFailure

        if ($push.ExitCode -eq 0) {
            if (-not $Quiet) {
                Write-Log 'Push exitoso.'
            }

            foreach ($line in $push.Output) {
                if (-not [string]::IsNullOrWhiteSpace($line)) {
                    Write-Log (" git: {0}" -f $line)
                }
            }

            return
        }

        Write-Log ("Push rechazado en intento {0}/{1}." -f $attempt, $MaxAttempts) -Color 'Yellow'

        foreach ($line in $push.Output) {
            if (-not [string]::IsNullOrWhiteSpace($line)) {
                Write-Log (" git: {0}" -f $line) -Color 'Yellow'
            }
        }
    }

    throw "git push origin $Branch fallo luego de $MaxAttempts intentos."
}

function Invoke-SyncToolsetOnce {
    Ensure-Branch

    $statusLines = Get-GitStatusLines

    if ($statusLines.Count -eq 0) {
        Invoke-GitPullQuietly
        return
    }

    Write-Log 'ENVIANDO Toolset'
    Write-StatusSummary -StatusLines $statusLines

    [void](Invoke-Git -Arguments @('add', '-A'))

    $statusAfterAdd = Get-GitStatusLines

    if ($statusAfterAdd.Count -gt 0) {
        $message = 'Sync Toolset {0}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        [void](Invoke-Git -Arguments @('commit', '-m', $message))
    }

    Invoke-GitPushWithRetry
}

# ============================================================
# Flujo principal
# ============================================================

try {
    $script:RepoRoot = Get-RepoRoot

    Acquire-GitSyncLock

    if (-not $Quiet) {
        Write-Log 'Sincronizando Toolset...'
        Write-Log ("Verificando Toolset en rama {0}" -f $Branch)
    }

    if ($RunOnce) {
        Invoke-SyncToolsetOnce
        return
    }

    while (-not (Test-ShouldStop)) {
        Invoke-SyncToolsetOnce
        Start-Sleep -Seconds $IntervalSeconds
    }
}
catch {
    Write-Log ("ERROR: {0}" -f $_.Exception.Message) -Color 'Red'
    Wait-BeforeExitOnError
    throw
}
finally {
    Release-GitSyncLock
}
