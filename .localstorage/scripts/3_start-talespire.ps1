<#
.SYNOPSIS
  Abre TaleSpire desde Steam.

.DESCRIPTION
  Responsabilidad unica:
    - Lanzar TaleSpire usando el URI de Steam.
#>

param(
    [switch]$NoPauseOnError
)

$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$CommonLoggingScript = Join-Path $ScriptDir '0_common-logging.ps1'
. $CommonLoggingScript
Initialize-Logging -ScriptPath $PSCommandPath

function Wait-BeforeExitOnError {
    if (-not $NoPauseOnError) {
        Write-Host ''
        Write-Log 'Presiona una tecla para cerrar esta ventana...'
        [void][System.Console]::ReadKey($true)
    }
}

try {
    Write-Log 'Abriendo TaleSpire...'
    Start-Process 'steam://rungameid/720620'
    exit 0
}
catch {
    Write-Log ("ERROR abriendo TaleSpire: {0}" -f $_.Exception.Message)
    Wait-BeforeExitOnError
    exit 1
}
