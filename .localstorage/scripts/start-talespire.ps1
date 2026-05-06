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

function Wait-BeforeExitOnError {
    if (-not $NoPauseOnError) {
        Write-Host ''
        Write-Host 'Presiona una tecla para cerrar esta ventana...'
        [void][System.Console]::ReadKey($true)
    }
}

try {
    Write-Host 'Abriendo TaleSpire...'
    Start-Process 'steam://rungameid/720620'
    exit 0
}
catch {
    Write-Host ("ERROR abriendo TaleSpire: {0}" -f $_.Exception.Message)
    Wait-BeforeExitOnError
    exit 1
}
