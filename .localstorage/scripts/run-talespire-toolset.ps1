<#
.SYNOPSIS
  Orquesta el lanzamiento de TaleSpire y los workers del Toolset.

.DESCRIPTION
  Este script no hace sync, no exporta hojas y no abre TaleSpire directamente.
  Solo coordina scripts separados:
    - sync-toolset-git.ps1: mantiene sincronizado el repo Toolset.
    - export-character-sheets.ps1: exporta una hoja JSON por personaje.
    - start-talespire.ps1: abre el juego.
    - wait-talespire-close.ps1: espera a que TaleSpire cierre y crea una senal de stop.

  Los workers corren como procesos separados, compartiendo la misma consola.
#>

param(
    [switch]$NoPauseOnError
)

$ErrorActionPreference = 'Stop'

# ============================================================
# Paths base
# ============================================================

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# Runtime fuera del repo. No debe vivir dentro de .localstorage porque Git sincroniza esa carpeta.
$RuntimeDir = Join-Path $env:TEMP 'talespire-toolset-runtime'
$StopSignalFile = Join-Path $RuntimeDir 'stop-all.signal'

$StartTaleSpireScript = Join-Path $ScriptDir 'start-talespire.ps1'
$SyncToolsetScript = Join-Path $ScriptDir 'sync-toolset-git.ps1'
$ExportCharacterSheetsScript = Join-Path $ScriptDir 'export-character-sheets.ps1'
$WaitTaleSpireCloseScript = Join-Path $ScriptDir 'wait-talespire-close.ps1'

# ============================================================
# Helpers
# ============================================================

function Write-Log([string]$Message) {
    Write-Host $Message
}

function Wait-BeforeExitOnError {
    if (-not $NoPauseOnError) {
        Write-Host ''
        Write-Host 'Presiona una tecla para cerrar esta ventana...'
        [void][System.Console]::ReadKey($true)
    }
}

function Assert-ScriptExists([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "No se encontro el script requerido: $Path"
    }
}

function Quote-Argument([string]$Value) {
    return '"' + ($Value -replace '"', '\"') + '"'
}

function Start-PowerShellWorker {
    param(
        [string]$Title,
        [string]$ScriptPath,
        [string[]]$ExtraArgs = @()
    )

    $args = @(
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        (Quote-Argument $ScriptPath)
    ) + $ExtraArgs

    Write-Log ("Iniciando worker: {0}" -f $Title)

    return Start-Process `
        -FilePath 'powershell.exe' `
        -ArgumentList $args `
        -NoNewWindow `
        -PassThru
}

function Stop-WorkerIfAlive {
    param(
        [System.Diagnostics.Process]$Process,
        [string]$Name
    )

    if ($Process -and -not $Process.HasExited) {
        Write-Log ("Deteniendo worker: {0}" -f $Name)
        $Process.Kill()
        $Process.WaitForExit()
    }
}

function Assert-ProcessExitCodeOk {
    param(
        [System.Diagnostics.Process]$Process,
        [string]$ScriptName
    )

    if (-not $Process) {
        return
    }

    $Process.Refresh()

    if ($null -eq $Process.ExitCode) {
        Write-Log ("WARNING: {0} termino, pero Windows no devolvio codigo de salida. Se asume OK." -f $ScriptName)
        return
    }

    if ($Process.ExitCode -ne 0) {
        throw "{0} termino con codigo {1}." -f $ScriptName, $Process.ExitCode
    }
}

# ============================================================
# Flujo principal
# ============================================================

$syncProcess = $null
$exportProcess = $null

try {
    Assert-ScriptExists $StartTaleSpireScript
    Assert-ScriptExists $SyncToolsetScript
    Assert-ScriptExists $ExportCharacterSheetsScript
    Assert-ScriptExists $WaitTaleSpireCloseScript

    if (-not (Test-Path -LiteralPath $RuntimeDir)) {
        [void](New-Item -ItemType Directory -Force -Path $RuntimeDir)
    }

    if (Test-Path -LiteralPath $StopSignalFile) {
        Remove-Item -LiteralPath $StopSignalFile -Force
    }

    # 1. Arranca el sync como worker independiente.
    $syncProcess = Start-PowerShellWorker `
        -Title 'Toolset Git Sync' `
        -ScriptPath $SyncToolsetScript `
        -ExtraArgs @('-StopSignalFile', (Quote-Argument $StopSignalFile), '-NoPauseOnError')

    # 2. Arranca el exportador de hojas como worker independiente.
    $exportProcess = Start-PowerShellWorker `
        -Title 'Character Sheets Export' `
        -ScriptPath $ExportCharacterSheetsScript `
        -ExtraArgs @('-StopSignalFile', (Quote-Argument $StopSignalFile), '-NoPauseOnError')

    # 3. Abre TaleSpire como script separado.
    $startProcess = Start-PowerShellWorker `
        -Title 'Start TaleSpire' `
        -ScriptPath $StartTaleSpireScript `
        -ExtraArgs @('-NoPauseOnError')

    $startProcess.WaitForExit()
    Assert-ProcessExitCodeOk -Process $startProcess -ScriptName 'start-talespire.ps1'

    # 4. Espera a que TaleSpire cierre.
    #    Al cerrar, este worker crea la senal de stop.
    $watchProcess = Start-PowerShellWorker `
        -Title 'Wait TaleSpire Close' `
        -ScriptPath $WaitTaleSpireCloseScript `
        -ExtraArgs @('-StopSignalFile', (Quote-Argument $StopSignalFile), '-NoPauseOnError')

    $watchProcess.WaitForExit()
    Assert-ProcessExitCodeOk -Process $watchProcess -ScriptName 'wait-talespire-close.ps1'

    # 5. Espera a que los workers detecten la senal, hagan su cierre final y salgan.
    if ($exportProcess -and -not $exportProcess.HasExited) {
        Write-Log 'Esperando cierre del worker de hojas...'
        $exportProcess.WaitForExit()
    }

    if ($syncProcess -and -not $syncProcess.HasExited) {
        Write-Log 'Esperando cierre del worker de sync...'
        $syncProcess.WaitForExit()
    }

    Assert-ProcessExitCodeOk -Process $exportProcess -ScriptName 'export-character-sheets.ps1'
    Assert-ProcessExitCodeOk -Process $syncProcess -ScriptName 'sync-toolset-git.ps1'

    Write-Log 'OK: TaleSpire cerrado. Workers finalizados correctamente.'
    Start-Sleep -Seconds 2
    exit 0
}
catch {
    Write-Log ("ERROR: {0}" -f $_.Exception.Message)

    if (-not (Test-Path -LiteralPath $StopSignalFile)) {
        try { [void](New-Item -ItemType File -Force -Path $StopSignalFile) } catch {}
    }

    Stop-WorkerIfAlive -Process $exportProcess -Name 'Character Sheets Export'
    Stop-WorkerIfAlive -Process $syncProcess -Name 'Toolset Git Sync'

    Wait-BeforeExitOnError
    exit 1
}
finally {
    try {
        if (Test-Path -LiteralPath $StopSignalFile) {
            Remove-Item -LiteralPath $StopSignalFile -Force -ErrorAction SilentlyContinue
        }
    }
    catch {}
}
