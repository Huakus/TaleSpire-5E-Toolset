<#
.SYNOPSIS
Orquesta el lanzamiento de TaleSpire y ejecuta el mantenimiento del Toolset en un tick central.

.DESCRIPTION
Responsabilidades:
- Abrir TaleSpire mediante 3_start-talespire.ps1.
- Esperar a que el proceso TaleSpire exista.
- Mientras TaleSpire este abierto, ejecutar un unico tick ordenado:
  1. 4_export-character-sheets.ps1 -RunOnce -Quiet
  2. 7_generate-history-index.ps1 -RunOnce -Quiet
  3. 5_sync-toolset-git.ps1 -RunOnce -Quiet
- Loguear puntos durante ticks sin cambios.
- Mantener logs relevantes solamente ante cambios, warnings o errores.
#>

param(
    [int]$TickSeconds = 10,
    [string]$ProcessName = 'TaleSpire',
    [int]$StartupTimeoutSeconds = 90,
    [switch]$NoPauseOnError
)

$ErrorActionPreference = 'Stop'

# ============================================================
# Paths base
# ============================================================

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$CommonLoggingScript = Join-Path $ScriptDir '0_common-logging.ps1'
. $CommonLoggingScript
Initialize-Logging -ScriptPath $PSCommandPath

$StartTaleSpireScript = Join-Path $ScriptDir '3_start-talespire.ps1'
$SyncToolsetScript = Join-Path $ScriptDir '5_sync-toolset-git.ps1'
$ExportCharacterSheetsScript = Join-Path $ScriptDir '4_export-character-sheets.ps1'
$GenerateHistoryIndexScript = Join-Path $ScriptDir '7_generate-history-index.ps1'

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

function Assert-ScriptExists {
    param([Parameter(Mandatory = $true)] [string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "No se encontro el script requerido: $Path"
    }
}

function Quote-Argument {
    param([Parameter(Mandatory = $true)] [string]$Value)

    return '"' + ($Value -replace '"', '\"') + '"'
}

function Start-PowerShellScript {
    param(
        [Parameter(Mandatory = $true)] [string]$Title,
        [Parameter(Mandatory = $true)] [string]$ScriptPath,
        [string[]]$ExtraArgs = @()
    )

    $args = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', (Quote-Argument $ScriptPath)
    ) + $ExtraArgs

    Write-Log ("Iniciando: {0}" -f $Title)

    return Start-Process `
        -FilePath 'powershell.exe' `
        -ArgumentList $args `
        -NoNewWindow `
        -PassThru
}

function Assert-ProcessExitCodeOk {
    param(
        [System.Diagnostics.Process]$Process,
        [Parameter(Mandatory = $true)] [string]$ScriptName
    )

    if (-not $Process) { return }

    $Process.Refresh()

    if ($null -eq $Process.ExitCode) { return }

    if ($Process.ExitCode -ne 0) {
        throw "{0} termino con codigo {1}." -f $ScriptName, $Process.ExitCode
    }
}

function Invoke-MaintenanceScript {
    param(
        [Parameter(Mandatory = $true)] [string]$Name,
        [Parameter(Mandatory = $true)] [string]$ScriptPath
    )

    if (-not (Test-Path -LiteralPath $ScriptPath)) {
        throw "No se encontro el script requerido para el tick: $ScriptPath"
    }

    $global:LASTEXITCODE = 0
    & $ScriptPath -RunOnce -Quiet -NoPauseOnError

    if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) {
        throw "{0} termino con codigo {1}." -f $Name, $LASTEXITCODE
    }

    $global:LASTEXITCODE = 0
}

function Invoke-MaintenanceTick {
    Invoke-MaintenanceScript -Name 'Character Sheets Export' -ScriptPath $ExportCharacterSheetsScript
    Invoke-MaintenanceScript -Name 'History Index Generator' -ScriptPath $GenerateHistoryIndexScript
    Invoke-MaintenanceScript -Name 'Toolset Git Sync' -ScriptPath $SyncToolsetScript
}

function Wait-ForProcessStart {
    param(
        [Parameter(Mandatory = $true)] [string]$Name,
        [Parameter(Mandatory = $true)] [int]$TimeoutSeconds
    )

    Write-Log ("Esperando proceso {0}..." -f $Name)

    for ($i = 0; $i -lt $TimeoutSeconds; $i++) {
        if (Get-Process -Name $Name -ErrorAction SilentlyContinue) {
            Write-Log ("{0} detectado. Iniciando ticks de mantenimiento." -f $Name)
            return $true
        }

        Start-Sleep -Seconds 1
    }

    return $false
}

function Wait-OrBreakIfProcessClosed {
    param(
        [Parameter(Mandatory = $true)] [string]$Name,
        [Parameter(Mandatory = $true)] [int]$Seconds
    )

    for ($i = 0; $i -lt $Seconds; $i++) {
        if (-not (Get-Process -Name $Name -ErrorAction SilentlyContinue)) {
            return $false
        }

        Start-Sleep -Seconds 1
    }

    return $true
}

# ============================================================
# Flujo principal
# ============================================================

try {
    if ($TickSeconds -lt 1) {
        throw 'TickSeconds debe ser mayor o igual a 1.'
    }

    Assert-ScriptExists $StartTaleSpireScript
    Assert-ScriptExists $SyncToolsetScript
    Assert-ScriptExists $ExportCharacterSheetsScript
    Assert-ScriptExists $GenerateHistoryIndexScript

    $startProcess = Start-PowerShellScript `
        -Title 'Start TaleSpire' `
        -ScriptPath $StartTaleSpireScript `
        -ExtraArgs @('-NoPauseOnError')

    $startProcess.WaitForExit()
    Assert-ProcessExitCodeOk -Process $startProcess -ScriptName '3_start-talespire.ps1'

    if (-not (Wait-ForProcessStart -Name $ProcessName -TimeoutSeconds $StartupTimeoutSeconds)) {
        Write-Log ("{0} no aparecio dentro del tiempo esperado. Cerrando orquestador." -f $ProcessName) -Color 'Yellow'
        Start-Sleep -Seconds 2
        exit 2
    }

    while (Get-Process -Name $ProcessName -ErrorAction SilentlyContinue) {
        Invoke-MaintenanceTick
        Write-Log '.' -Inline

        if (-not (Wait-OrBreakIfProcessClosed -Name $ProcessName -Seconds $TickSeconds)) {
            break
        }
    }

    Write-Log ("{0} cerrado. Ejecutando tick final..." -f $ProcessName)
    Invoke-MaintenanceTick

    Write-Log 'OK: mantenimiento finalizado.'
    Start-Sleep -Seconds 2
    exit 0
} catch {
    Write-Log ("ERROR: {0}" -f $_.Exception.Message) -Color 'Red'
    Wait-BeforeExitOnError
    exit 1
}
