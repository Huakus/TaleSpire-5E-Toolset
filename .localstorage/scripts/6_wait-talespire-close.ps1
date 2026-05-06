<#
.SYNOPSIS
  Espera a que TaleSpire cierre y avisa a los demas workers.

.DESCRIPTION
  Responsabilidad unica:
    - Esperar a que aparezca el proceso TaleSpire.
    - Mantenerse vivo mientras el proceso exista.
    - Crear un archivo senal cuando TaleSpire cierre.
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$StopSignalFile,

    [string]$ProcessName = 'TaleSpire',

    [int]$StartupTimeoutSeconds = 90,

    [switch]$NoPauseOnError
)

$ErrorActionPreference = 'Stop'

function Wait-BeforeExitOnError {
    if (-not $NoPauseOnError) {
        Write-Host ''
        Write-Host 'Presiona una tecla para cerrar esta ventana...'
        [void][System.Console]::ReadKey($true)
    }
}

function Set-StopSignal {
    $dir = Split-Path -Parent $StopSignalFile

    if (-not (Test-Path $dir)) {
        [void](New-Item -ItemType Directory -Force -Path $dir)
    }

    Set-Content -Path $StopSignalFile -Value (Get-Date -Format o) -Force
}

try {
    Write-Host 'Esperando proceso TaleSpire...'

    $appeared = $false

    for ($i = 0; $i -lt $StartupTimeoutSeconds; $i++) {
        if (Get-Process -Name $ProcessName -ErrorAction SilentlyContinue) {
            $appeared = $true
            break
        }

        Start-Sleep -Seconds 1
    }

    if (-not $appeared) {
        Write-Host 'TaleSpire no aparecio dentro del tiempo esperado. Enviando senal de stop.'
        Set-StopSignal
        exit 2
    }

    Write-Host 'TaleSpire detectado. Esperando cierre...'

    while (Get-Process -Name $ProcessName -ErrorAction SilentlyContinue) {
        Start-Sleep -Seconds 2
    }

    Write-Host 'TaleSpire cerrado. Enviando senal de stop.'
    Set-StopSignal
    exit 0
}
catch {
    Write-Host ("ERROR esperando cierre de TaleSpire: {0}" -f $_.Exception.Message)
    try { Set-StopSignal } catch {}
    Wait-BeforeExitOnError
    exit 1
}
