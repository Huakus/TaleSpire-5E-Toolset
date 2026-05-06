<#
.SYNOPSIS
  Helpers comunes de logging para los scripts del Toolset.

.DESCRIPTION
  - Calcula un prefijo dinamico desde el nombre del script que lo inicializa.
  - Si el nombre empieza con numero, usa ese numero: [5].
  - Si no encuentra numero, usa [?].
  - Permite logs normales y logs inline para puntos de espera.
#>

$script:LogPrefix = '[?]'
$script:lastInline = $false

function Initialize-Logging {
    param(
        [string]$ScriptPath
    )

    $scriptName = if (-not [string]::IsNullOrWhiteSpace($ScriptPath)) {
        Split-Path -Leaf $ScriptPath
    }
    else {
        ''
    }

    if ($scriptName -match '^(\d+)[_-]') {
        $script:LogPrefix = ('[{0}]' -f $Matches[1])
    }
    else {
        $script:LogPrefix = '[?]'
    }

    $script:lastInline = $false
}

function Write-Log {
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$Message,

        [switch]$Inline,

        [string]$Color
    )

    if ($Inline) {
        if (-not $script:lastInline) {
            Write-Host -NoNewline ('{0} ' -f $script:LogPrefix)
        }

        Write-Host -NoNewline $Message
        $script:lastInline = $true
        return
    }

    if ($script:lastInline) {
        Write-Host ''
        $script:lastInline = $false
    }

    $line = ('{0} {1}' -f $script:LogPrefix, $Message)

    if ([string]::IsNullOrWhiteSpace($Color)) {
        Write-Host $line
    }
    else {
        Write-Host $line -ForegroundColor $Color
    }
}
