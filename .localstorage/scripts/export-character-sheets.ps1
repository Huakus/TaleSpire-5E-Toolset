<#
.SYNOPSIS
  Exporta una hoja JSON por cada personaje definido en el JSON principal del Toolset.

.DESCRIPTION
  Lee el JSON principal del symbiote, detecta el nodo top-level "characters"
  y genera/actualiza un archivo por personaje en ECE\Hojas.

  El nombre del archivo se genera dinamicamente desde el nombre/key del personaje:
    Adler    -> hoja_adler.json
    Delerion -> hoja_delerion.json

  Si un personaje cambia de nombre, se genera el nuevo archivo y se elimina
  el archivo viejo hoja_*.json que ya no corresponde a ningun personaje actual.

  Si se pasa -StopSignalFile, el script corre en loop hasta que exista esa senal.
  Si no se pasa -StopSignalFile, hace una exportacion una sola vez y termina.
#>

param(
    [string]$SourceJsonFile = '',
    [string]$OutputDir = '',
    [string]$StopSignalFile = '',
    [int]$IntervalSeconds = 10,
    [switch]$NoDeleteOldFiles,
    [switch]$NoPauseOnError
)

$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$LocalStorageDir = Split-Path -Parent $ScriptDir

if ([string]::IsNullOrWhiteSpace($OutputDir)) {
    $OutputDir = Join-Path $LocalStorageDir 'ECE\Hojas'
}

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

function ConvertTo-SafeFileName([string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) {
        return 'sin_nombre'
    }

    $normalized = $Value.Normalize([Text.NormalizationForm]::FormD)
    $builder = New-Object System.Text.StringBuilder

    foreach ($char in $normalized.ToCharArray()) {
        $category = [Globalization.CharUnicodeInfo]::GetUnicodeCategory($char)
        if ($category -ne [Globalization.UnicodeCategory]::NonSpacingMark) {
            [void]$builder.Append($char)
        }
    }

    $safe = $builder.ToString().Normalize([Text.NormalizationForm]::FormC).ToLowerInvariant()
    $safe = $safe -replace '[^a-z0-9]+', '_'
    $safe = $safe.Trim('_')
    $safe = $safe -replace '_+', '_'

    if ([string]::IsNullOrWhiteSpace($safe)) {
        return 'sin_nombre'
    }

    return $safe
}

function Read-JsonFile([string]$Path) {
    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    return $raw | ConvertFrom-Json
}

function Find-MainJsonFile {
    if (-not [string]::IsNullOrWhiteSpace($SourceJsonFile)) {
        if (-not (Test-Path -LiteralPath $SourceJsonFile)) {
            throw "No se encontro el JSON principal indicado: $SourceJsonFile"
        }
        return (Resolve-Path -LiteralPath $SourceJsonFile).Path
    }

    $candidateFiles = Get-ChildItem -LiteralPath $ScriptDir -File |
        Where-Object {
            $_.Extension -in @('', '.json') -and
            $_.Name -notlike 'hoja_*.json' -and
            $_.Name -notlike '_*.json'
        }

    foreach ($file in $candidateFiles) {
        try {
            $json = Read-JsonFile $file.FullName
            if ($null -ne $json.characters) {
                return $file.FullName
            }
        }
        catch {
            # No era JSON valido o no era el archivo principal. Lo ignoramos.
        }
    }

    throw "No se encontro ningun JSON principal con nodo 'characters' en: $ScriptDir"
}

function Write-JsonIfChanged {
    param(
        [string]$Path,
        [object]$Data
    )

    $newContent = ($Data | ConvertTo-Json -Depth 100) + [Environment]::NewLine

    if (Test-Path -LiteralPath $Path) {
        $currentContent = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
        if ($currentContent -eq $newContent) {
            return $false
        }
    }

    $tempFile = [System.IO.Path]::GetTempFileName()
    try {
        Set-Content -LiteralPath $tempFile -Value $newContent -Encoding UTF8 -NoNewline
        Move-Item -LiteralPath $tempFile -Destination $Path -Force
    }
    finally {
        if (Test-Path -LiteralPath $tempFile) {
            Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue
        }
    }

    return $true
}

function Export-CharacterSheetsOnce {
    $mainJsonFile = Find-MainJsonFile
    $mainJson = Read-JsonFile $mainJsonFile

    if ($null -eq $mainJson.characters) {
        throw "El JSON principal no tiene nodo 'characters': $mainJsonFile"
    }

    if (-not (Test-Path -LiteralPath $OutputDir)) {
        [void](New-Item -ItemType Directory -Force -Path $OutputDir)
    }

    $expectedFiles = New-Object 'System.Collections.Generic.HashSet[string]'
    $createdOrUpdated = 0
    $unchanged = 0

    $characterProperties = $mainJson.characters.PSObject.Properties

    foreach ($property in $characterProperties) {
        $characterName = $property.Name
        $characterData = $property.Value

        $safeName = ConvertTo-SafeFileName $characterName
        $fileName = "hoja_$safeName.json"
        $outputPath = Join-Path $OutputDir $fileName

        [void]$expectedFiles.Add($fileName.ToLowerInvariant())

        $changed = Write-JsonIfChanged -Path $outputPath -Data $characterData
        if ($changed) {
            $createdOrUpdated++
            Write-Log ("HOJA actualizada: {0}" -f $fileName)
        }
        else {
            $unchanged++
        }
    }

    $deleted = 0

    if (-not $NoDeleteOldFiles) {
        Get-ChildItem -LiteralPath $OutputDir -File -Filter 'hoja_*.json' | ForEach-Object {
            if (-not $expectedFiles.Contains($_.Name.ToLowerInvariant())) {
                Remove-Item -LiteralPath $_.FullName -Force
                $deleted++
                Write-Log ("HOJA eliminada por no existir mas en JSON principal: {0}" -f $_.Name)
            }
        }
    }

    Write-Log ("OK: Hojas exportadas. Personajes={0}, actualizadas={1}, sin_cambios={2}, eliminadas={3}" -f `
        $characterProperties.Count, $createdOrUpdated, $unchanged, $deleted)
}

try {
    if ($IntervalSeconds -lt 2) {
        $IntervalSeconds = 2
    }

    Write-Log 'Iniciando exportador de hojas de personajes...'
    Write-Log ("Carpeta destino: {0}" -f $OutputDir)

    if ([string]::IsNullOrWhiteSpace($StopSignalFile)) {
        Export-CharacterSheetsOnce
        exit 0
    }

    while (-not (Test-Path -LiteralPath $StopSignalFile)) {
        Export-CharacterSheetsOnce

        for ($i = 0; $i -lt $IntervalSeconds; $i++) {
            if (Test-Path -LiteralPath $StopSignalFile) {
                break
            }
            Start-Sleep -Seconds 1
        }
    }

    Write-Log 'Senal de stop recibida. Ejecutando export final de hojas...'
    Export-CharacterSheetsOnce
    exit 0
}
catch {
    Write-Log ("ERROR: {0}" -f $_.Exception.Message)
    Wait-BeforeExitOnError
    exit 1
}
