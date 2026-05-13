<#
.SYNOPSIS
Helpers comunes de logging para los scripts del Toolset.

.DESCRIPTION
- Calcula un prefijo dinamico desde el nombre del script que lo inicializa.
- Si el nombre empieza con numero, usa ese numero: [5].
- Si no encuentra numero, usa [?].
- Permite logs normales y logs inline para puntos de espera.
- Permite mostrar una alarma visible/sonora cuando ocurre un error.
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

function Show-ErrorAlert {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,

        [string]$Title = 'TaleSpire Toolset - Error'
    )

    try {
        [console]::beep(1000, 700)
        [console]::beep(800, 700)
    }
    catch {
        Write-Log ('No se pudo reproducir alarma sonora: {0}' -f $_.Exception.Message) -Color 'Yellow'
    }

    try {
        Add-Type -AssemblyName PresentationFramework

        [System.Windows.MessageBox]::Show(
            $Message,
            $Title,
            'OK',
            'Error'
        ) | Out-Null
    }
    catch {
        Write-Log ('No se pudo mostrar alerta visual: {0}' -f $_.Exception.Message) -Color 'Yellow'
    }
}
