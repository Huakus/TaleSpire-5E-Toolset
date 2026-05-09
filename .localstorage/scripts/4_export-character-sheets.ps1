<#
.SYNOPSIS
Exporta una hoja TXT por cada personaje del JSON principal del Toolset.

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

$LocalStorageDir = Split-Path -Parent $ScriptDir
$OutputDir = Join-Path $LocalStorageDir 'ECE\Hojas'

$IgnoredDirectoryNames = @(
    'Hojas',
    'Lore',
    '.runtime',
    '.tmp.driveupload',
    '.vscode',
    '.git',
    'node_modules',
    'scripts'
)

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

function Ensure-Directory {
    param([Parameter(Mandatory = $true)] [string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        [void](New-Item -ItemType Directory -Force -Path $Path)
    }
}

function Remove-Accents {
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return '' }

    $normalized = $Text.Normalize([Text.NormalizationForm]::FormD)
    $builder = New-Object System.Text.StringBuilder

    foreach ($char in $normalized.ToCharArray()) {
        $category = [Globalization.CharUnicodeInfo]::GetUnicodeCategory($char)
        if ($category -ne [Globalization.UnicodeCategory]::NonSpacingMark) {
            [void]$builder.Append($char)
        }
    }

    return $builder.ToString().Normalize([Text.NormalizationForm]::FormC)
}

function ConvertTo-SafeFilePart {
    param([string]$Name)

    $value = Remove-Accents $Name
    $value = $value.ToLowerInvariant()
    $value = $value -replace '[^a-z0-9]+', '_'
    $value = $value -replace '_+', '_'
    $value = $value.Trim('_')

    if ([string]::IsNullOrWhiteSpace($value)) { return 'sin_nombre' }

    return $value
}

function Get-TextFileCandidates {
    param([Parameter(Mandatory = $true)] [string]$RootPath)

    $allFiles = Get-ChildItem -LiteralPath $RootPath -File -Recurse -ErrorAction SilentlyContinue

    foreach ($file in $allFiles) {
        $relativeDirectory = $file.DirectoryName.Substring($RootPath.Length)
        $directoryNames = $relativeDirectory.Split([IO.Path]::DirectorySeparatorChar, [StringSplitOptions]::RemoveEmptyEntries)

        $isIgnored = $false
        foreach ($dirName in $directoryNames) {
            if ($IgnoredDirectoryNames -contains $dirName) {
                $isIgnored = $true
                break
            }
        }

        if ($isIgnored) { continue }

        if ($file.Extension -eq '.json' -or [string]::IsNullOrWhiteSpace($file.Extension)) {
            $file
        }
    }
}

function ConvertFrom-ToolsetJson {
    param([Parameter(Mandatory = $true)] [string]$JsonText)

    # Windows PowerShell falla con propiedades cuyo nombre es vacio: "":
    $safeJson = $JsonText -replace '""\s*:', '"toolsetEmptyKey":'
    return $safeJson | ConvertFrom-Json
}

function Get-PropertyValue {
    param(
        [Parameter(Mandatory = $true)] $Object,
        [Parameter(Mandatory = $true)] [string[]]$Names
    )

    if ($null -eq $Object) { return $null }

    foreach ($name in $Names) {
        $property = $Object.PSObject.Properties | Where-Object { $_.Name -eq $name } | Select-Object -First 1
        if ($property) { return $property.Value }
    }

    return $null
}

function Find-ToolsetJsonWithCharacters {
    $candidates = Get-TextFileCandidates -RootPath $LocalStorageDir |
        Sort-Object Length -Descending

    foreach ($file in $candidates) {
        try {
            $text = Get-Content -LiteralPath $file.FullName -Raw -ErrorAction Stop

            if ($text -notmatch '"characters"') { continue }

            $json = ConvertFrom-ToolsetJson -JsonText $text
            $characters = Get-PropertyValue -Object $json -Names @('characters')

            if ($characters) {
                return [PSCustomObject]@{
                    File = $file
                    Json = $json
                    Characters = $characters
                }
            }
        } catch {
            continue
        }
    }

    return $null
}

function Convert-CharacterContainerToList {
    param([Parameter(Mandatory = $true)] $Characters)

    $result = New-Object System.Collections.Generic.List[object]

    if ($Characters -is [System.Array]) {
        foreach ($character in $Characters) {
            $name = Get-PropertyValue -Object $character -Names @('name', 'nombre', 'characterName')
            if ([string]::IsNullOrWhiteSpace($name)) { $name = 'sin_nombre' }

            $result.Add([PSCustomObject]@{
                Name = [string]$name
                Value = $character
            })
        }

        return $result
    }

    foreach ($property in $Characters.PSObject.Properties) {
        $character = $property.Value
        $name = Get-PropertyValue -Object $character -Names @('name', 'nombre', 'characterName')
        if ([string]::IsNullOrWhiteSpace($name)) { $name = $property.Name }

        $result.Add([PSCustomObject]@{
            Name = [string]$name
            Value = $character
        })
    }

    return $result
}

function Convert-CharacterToText {
    param(
        [Parameter(Mandatory = $true)] [string]$Name,
        [Parameter(Mandatory = $true)] $Character
    )

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("# $Name")
    $lines.Add('')
    $lines.Add('> Archivo generado automaticamente desde el JSON principal del Toolset.')
    $lines.Add('> No editar manualmente.')
    $lines.Add('')

    $class = Get-PropertyValue -Object $Character -Names @('class', 'clase')
    $race = Get-PropertyValue -Object $Character -Names @('race', 'raza')
    $level = Get-PropertyValue -Object $Character -Names @('level', 'nivel')

    if ($race -or $class -or $level) {
        $lines.Add('## Resumen')
        if ($race) { $lines.Add("- Raza: $race") }
        if ($class) { $lines.Add("- Clase: $class") }
        if ($level) { $lines.Add("- Nivel: $level") }
        $lines.Add('')
    }

    $lines.Add('## Datos completos')
    $lines.Add('')
    $lines.Add('```json')
    $lines.Add(($Character | ConvertTo-Json -Depth 100))
    $lines.Add('```')
    $lines.Add('')

    return ($lines -join [Environment]::NewLine)
}

function Write-TextIfChanged {
    param(
        [Parameter(Mandatory = $true)] [string]$Path,
        [Parameter(Mandatory = $true)] [string]$Content
    )

    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)

    if (Test-Path -LiteralPath $Path) {
        $previous = [System.IO.File]::ReadAllText($Path)
        if ($previous -eq $Content) { return $false }
    }

    [System.IO.File]::WriteAllText($Path, $Content, $utf8NoBom)
    return $true
}

function Invoke-ExportCharacterSheetsOnce {
    Ensure-Directory $OutputDir

    $source = Find-ToolsetJsonWithCharacters
    if (-not $source) {
        Write-Log 'WARNING: No se encontro un JSON principal con nodo characters.' -Color 'Yellow'
        return
    }

    $characters = Convert-CharacterContainerToList -Characters $source.Characters
    $expectedFiles = New-Object System.Collections.Generic.HashSet[string]
    $changedCount = 0
    $removedCount = 0

    foreach ($entry in $characters) {
        $safeName = ConvertTo-SafeFilePart $entry.Name
        $fileName = "$safeName.txt"
        $path = Join-Path $OutputDir $fileName
        [void]$expectedFiles.Add($path.ToLowerInvariant())

        $content = Convert-CharacterToText -Name $entry.Name -Character $entry.Value

        if (Write-TextIfChanged -Path $path -Content $content) {
            $changedCount++
            Write-Log ("EXPORTADO hoja: {0}" -f $fileName)
        }
    }

    $existingFiles = Get-ChildItem -LiteralPath $OutputDir -Filter '*.txt' -File -ErrorAction SilentlyContinue
    foreach ($file in $existingFiles) {
        if (-not $expectedFiles.Contains($file.FullName.ToLowerInvariant())) {
            Remove-Item -LiteralPath $file.FullName -Force
            $removedCount++
            Write-Log ("ELIMINADA hoja obsoleta: {0}" -f $file.Name)
        }
    }

    if (-not $Quiet -and $changedCount -eq 0 -and $removedCount -eq 0) {
        Write-Log 'Hojas de personaje actualizadas. No hay cambios.'
    }
}

# ============================================================
# Flujo principal
# ============================================================

try {
    if (-not $Quiet) {
        Write-Log 'Iniciando exportador de hojas de personajes...'
        Write-Log ("Carpeta destino: {0}" -f $OutputDir)
    }

    if ($RunOnce) {
        Invoke-ExportCharacterSheetsOnce
        return
    }

    while (-not (Test-ShouldStop)) {
        Invoke-ExportCharacterSheetsOnce
        Start-Sleep -Seconds $IntervalSeconds
    }
} catch {
    Write-Log ("ERROR: {0}" -f $_.Exception.Message) -Color 'Red'
    Wait-BeforeExitOnError
    throw
}
