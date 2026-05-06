<#
.SYNOPSIS
  Orquesta el lanzamiento de TaleSpire y los workers del Toolset.

.DESCRIPTION
  Este script no hace sync ni abre TaleSpire directamente.
  Solo coordina scripts separados:
    - start-talespire.ps1: abre el juego.
    - sync-toolset-git.ps1: mantiene sincronizado el repo Toolset.
    - wait-talespire-close.ps1: espera a que TaleSpire cierre y crea una senal de stop.

  El sync corre en paralelo. Los otros scripts se ejecutan de forma secuencial
  desde este orquestador para poder capturar bien sus codigos de salida.
#>

param(
    [switch]$NoPauseOnError
)

$ErrorActionPreference = 'Stop'

# ============================================================
# Paths base
# ============================================================

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
# Runtime fuera del repo/scripts para no commitear archivos temporales como stop-all.signal.
# Usamos una carpeta temporal por ejecucion del launcher.
$RuntimeRoot = Join-Path $env:TEMP 'talespire-toolset-launcher'
$RuntimeDir = Join-Path $RuntimeRoot ([Guid]::NewGuid().ToString('N'))
$StopSignalFile = Join-Path $RuntimeDir 'stop-all.signal'

$StartTaleSpireScript = Join-Path $ScriptDir 'start-talespire.ps1'
$SyncToolsetScript = Join-Path $ScriptDir 'sync-toolset-git.ps1'
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
    if (-not (Test-Path $Path)) {
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

function Invoke-PowerShellScript {
    param(
        [string]$Title,
        [string]$ScriptPath,
        [string[]]$ExtraArgs = @()
    )

    Write-Log ("Ejecutando script: {0}" -f $Title)

    # Usamos Start-Process -Wait -PassThru para evitar que la salida del script hijo
    # se mezcle con el valor de retorno de esta funcion.
    # Si se invoca con &, cualquier Write-Host/stdout del hijo puede terminar capturado
    # junto con el codigo de salida cuando el caller hace: $exitCode = Invoke-PowerShellScript.
    $args = @(
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        (Quote-Argument $ScriptPath)
    ) + $ExtraArgs

    $process = Start-Process `
        -FilePath 'powershell.exe' `
        -ArgumentList $args `
        -NoNewWindow `
        -Wait `
        -PassThru

    if ($null -eq $process.ExitCode) {
        return 0
    }

    return [int]$process.ExitCode
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

function Get-WorkerExitCode {
    param(
        [System.Diagnostics.Process]$Process,
        [string]$Name
    )

    if (-not $Process) {
        throw "No se pudo obtener el proceso del worker: $Name"
    }

    # A veces Windows/Start-Process tarda un instante en hidratar ExitCode
    # aunque el proceso ya haya terminado. Esperamos/refrescamos antes de leerlo.
    if (-not $Process.HasExited) {
        $Process.WaitForExit()
    }

    Start-Sleep -Milliseconds 250
    $Process.Refresh()

    try {
        $exitCode = $Process.ExitCode
    }
    catch {
        Write-Log ("WARN: No se pudo leer el codigo de salida de {0}. Se asume 0 porque el proceso ya termino." -f $Name)
        return 0
    }

    if ($null -eq $exitCode -or ($exitCode -is [string] -and [string]::IsNullOrWhiteSpace($exitCode))) {
        Write-Log ("WARN: {0} termino pero Windows no devolvio codigo de salida. Se asume 0." -f $Name)
        return 0
    }

    return [int]$exitCode
}

# ============================================================
# Flujo principal
# ============================================================

$syncProcess = $null

try {
    Assert-ScriptExists $StartTaleSpireScript
    Assert-ScriptExists $SyncToolsetScript
    Assert-ScriptExists $WaitTaleSpireCloseScript

    if (-not (Test-Path $RuntimeDir)) {
        [void](New-Item -ItemType Directory -Force -Path $RuntimeDir)
    }

    if (Test-Path $StopSignalFile) {
        Remove-Item $StopSignalFile -Force
    }

    # 1. Arranca el sync como worker independiente.
    #    Este worker hace sync inicial, queda en loop y hace sync final al recibir stop.
    $syncProcess = Start-PowerShellWorker `
        -Title 'Toolset Git Sync' `
        -ScriptPath $SyncToolsetScript `
        -ExtraArgs @('-StopSignalFile', (Quote-Argument $StopSignalFile), '-NoPauseOnError')

    # 2. Abre TaleSpire desde su propio script.
    #    Se ejecuta secuencialmente para capturar correctamente el codigo de salida.
    $startExitCode = Invoke-PowerShellScript `
        -Title 'Start TaleSpire' `
        -ScriptPath $StartTaleSpireScript `
        -ExtraArgs @('-NoPauseOnError')

    if ($startExitCode -ne 0) {
        [void](New-Item -ItemType File -Force -Path $StopSignalFile)
        throw "start-talespire.ps1 termino con codigo $startExitCode."
    }

    # 3. Espera a que TaleSpire cierre.
    #    Este script queda vivo hasta detectar el cierre y luego crea la senal de stop.
    $watchExitCode = Invoke-PowerShellScript `
        -Title 'Wait TaleSpire Close' `
        -ScriptPath $WaitTaleSpireCloseScript `
        -ExtraArgs @('-StopSignalFile', (Quote-Argument $StopSignalFile), '-NoPauseOnError')

    if ($watchExitCode -ne 0) {
        [void](New-Item -ItemType File -Force -Path $StopSignalFile)
        throw "wait-talespire-close.ps1 termino con codigo $watchExitCode."
    }

    # 4. Espera a que el sync detecte la senal, haga sync final y salga.
    if ($syncProcess -and -not $syncProcess.HasExited) {
        Write-Log 'Esperando cierre del worker de sync...'
        $syncProcess.WaitForExit()
    }

    if ($syncProcess) {
        $syncExitCode = Get-WorkerExitCode -Process $syncProcess -Name 'sync-toolset-git.ps1'

        if ($syncExitCode -ne 0) {
            throw "sync-toolset-git.ps1 termino con codigo $syncExitCode."
        }
    }

    Write-Log 'OK: TaleSpire cerrado. Workers finalizados correctamente.'

    # Limpieza best-effort de archivos temporales del launcher.
    try {
        if (Test-Path $RuntimeDir) {
            Remove-Item $RuntimeDir -Recurse -Force
        }
    }
    catch {}

    Start-Sleep -Seconds 2
    exit 0
}
catch {
    Write-Log ("ERROR: {0}" -f $_.Exception.Message)

    if (-not (Test-Path $StopSignalFile)) {
        try { [void](New-Item -ItemType File -Force -Path $StopSignalFile) } catch {}
    }

    Stop-WorkerIfAlive -Process $syncProcess -Name 'Toolset Git Sync'

    # En error no borramos RuntimeDir antes de la pausa si hace falta diagnosticar,
    # pero intentamos removerlo despues de setear la senal y cerrar workers.
    try {
        if (Test-Path $RuntimeDir) {
            Remove-Item $RuntimeDir -Recurse -Force
        }
    }
    catch {}

    Wait-BeforeExitOnError
    exit 1
}
