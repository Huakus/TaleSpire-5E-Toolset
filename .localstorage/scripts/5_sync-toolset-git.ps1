<#
.SYNOPSIS
Sincroniza el repo Toolset con Git.

.DESCRIPTION
Modo nuevo recomendado:
- Ejecutar desde 2_orquestrator.ps1 con -RunOnce -Quiet.
- El script no maneja el tick cuando se usa -RunOnce.

Compatibilidad:
- Si se ejecuta sin -RunOnce, mantiene el modo worker anterior con IntervalSeconds y StopSignalFile.
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
# Helpers
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
        [Parameter(Mandatory = $true)] [string[]]$Arguments,
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
    } finally {
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
        Output = @($output)
        Text = $joined
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
    return @($result.Output | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

function Get-CurrentHead {
    return (Invoke-Git -Arguments @('rev-parse', 'HEAD')).Text.Trim()
}

function Write-StatusSummary {
    param([string[]]$StatusLines)

    foreach ($line in $StatusLines) {
        Write-Log ("  local: {0}" -f $line)
    }

    $diff = Invoke-Git -Arguments @('diff', '--stat')
    foreach ($line in $diff.Output) {
        if (-not [string]::IsNullOrWhiteSpace($line)) {
            Write-Log ("  diff:  {0}" -f $line)
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

function Invoke-GitPullQuietly {
    $before = Get-CurrentHead
    $pull = Invoke-Git -Arguments @('pull', '--rebase', '--autostash', 'origin', $Branch)
    $after = Get-CurrentHead

    if ($before -ne $after) {
        Write-Log 'RECIBIDO Toolset'
        foreach ($line in $pull.Output) {
            if (-not [string]::IsNullOrWhiteSpace($line)) {
                Write-Log ("  git: {0}" -f $line)
            }
        }
    } elseif (-not $Quiet) {
        Write-Log 'Toolset actualizado. No hay cambios.'
    }
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

    [void](Invoke-Git -Arguments @('pull', '--rebase', '--autostash', 'origin', $Branch))
    [void](Invoke-Git -Arguments @('push', 'origin', $Branch))
}

# ============================================================
# Flujo principal
# ============================================================

try {
    $script:RepoRoot = Get-RepoRoot

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
} catch {
    Write-Log ("ERROR: {0}" -f $_.Exception.Message) -Color 'Red'
    Wait-BeforeExitOnError
    throw
}
