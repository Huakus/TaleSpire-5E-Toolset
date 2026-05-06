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

  El JSON principal puede no tener extension .json. Por eso se buscan tambien
  archivos sin extension. La busqueda es recursiva dentro de .localstorage,
  pero se ignoran carpetas de salida y runtime.
#>

param(
    [string]$SourceJsonFile = '',
    [string]$OutputDir = '',
    [string]$StopSignalFile = '',
    [int]$IntervalSeconds = 10,
    [switch]$NoDeleteOldFiles,
    [switch]$NoPauseOnError,
    [switch]$VerboseSearch
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

function Write-Warn([string]$Message) {
    Write-Host ("WARNING: {0}" -f $Message)
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

function Read-JsonText([string]$Path) {
    return Get-Content -LiteralPath $Path -Raw -Encoding UTF8
}

function Read-JsonFile([string]$Path) {
    $raw = Read-JsonText $Path
    return $raw | ConvertFrom-Json
}

function Test-ShouldIgnoreCandidateFile([System.IO.FileInfo]$File) {
    $fullName = $File.FullName

    if ($File.Name -ieq 'desktop.ini') { return $true }
    if ($File.Name -like 'hoja_*.json') { return $true }
    if ($File.Name -like '_*.json') { return $true }
    if ($File.Extension -notin @('', '.json')) { return $true }

    # Evitamos leer las hojas exportadas, carpetas temporales y config de VSCode.
    if ($fullName -like "*$([System.IO.Path]::DirectorySeparatorChar)ECE$([System.IO.Path]::DirectorySeparatorChar)Hojas$([System.IO.Path]::DirectorySeparatorChar)*") { return $true }
    if ($fullName -like "*$([System.IO.Path]::DirectorySeparatorChar).runtime$([System.IO.Path]::DirectorySeparatorChar)*") { return $true }
    if ($fullName -like "*$([System.IO.Path]::DirectorySeparatorChar).tmp.driveupload$([System.IO.Path]::DirectorySeparatorChar)*") { return $true }
    if ($fullName -like "*$([System.IO.Path]::DirectorySeparatorChar).vscode$([System.IO.Path]::DirectorySeparatorChar)*") { return $true }

    return $false
}

function Get-CandidateMainJsonFiles {
    if (-not (Test-Path -LiteralPath $LocalStorageDir)) {
        return @()
    }

    # Busqueda recursiva porque el archivo principal puede estar en .localstorage
    # o en alguna subcarpeta. Se filtra por extension y despues por contenido.
    $files = Get-ChildItem -LiteralPath $LocalStorageDir -File -Recurse -ErrorAction SilentlyContinue |
        Where-Object { -not (Test-ShouldIgnoreCandidateFile $_) } |
        Sort-Object @{ Expression = { if ($_.DirectoryName -eq $LocalStorageDir) { 0 } elseif ($_.DirectoryName -eq $ScriptDir) { 1 } else { 2 } } }, Length

    return @($files)
}

function Find-MainJsonFile {
    if (-not [string]::IsNullOrWhiteSpace($SourceJsonFile)) {
        if (-not (Test-Path -LiteralPath $SourceJsonFile)) {
            throw "No se encontro el JSON principal indicado: $SourceJsonFile"
        }
        return (Resolve-Path -LiteralPath $SourceJsonFile).Path
    }

    $candidateFiles = Get-CandidateMainJsonFiles
    $checkedCount = 0
    $jsonLikeCount = 0
    $errors = New-Object System.Collections.Generic.List[string]

    foreach ($file in $candidateFiles) {
        $checkedCount++

        try {
            $raw = Read-JsonText $file.FullName

            # Filtro barato para no intentar parsear cualquier archivo.
            if ($raw -notmatch '"characters"\s*:') {
                if ($VerboseSearch) { Write-Log ("DEBUG: sin nodo characters: {0}" -f $file.FullName) }
                continue
            }

            $jsonLikeCount++
            $json = $raw | ConvertFrom-Json

            $charactersProperty = $json.PSObject.Properties | Where-Object { $_.Name -eq 'characters' } | Select-Object -First 1
            if ($null -ne $charactersProperty -and $null -ne $charactersProperty.Value) {
                return $file.FullName
            }
        }
        catch {
            [void]$errors.Add(("{0}: {1}" -f $file.FullName, $_.Exception.Message))
        }
    }

    $searched = $LocalStorageDir
    $message = "No se encontro ningun JSON principal con nodo 'characters'. Carpeta revisada recursivamente: $searched. Archivos candidatos revisados=$checkedCount, con texto characters=$jsonLikeCount."

    if ($errors.Count -gt 0) {
        $message += " Errores de parseo: " + (($errors | Select-Object -First 5) -join ' | ')
    }

    throw $message
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

    $charactersProperty = $mainJson.PSObject.Properties | Where-Object { $_.Name -eq 'characters' } | Select-Object -First 1
    if ($null -eq $charactersProperty -or $null -eq $charactersProperty.Value) {
        throw "El JSON principal no tiene nodo 'characters': $mainJsonFile"
    }

    if (-not (Test-Path -LiteralPath $OutputDir)) {
        [void](New-Item -ItemType Directory -Force -Path $OutputDir)
    }

    $expectedFiles = New-Object 'System.Collections.Generic.HashSet[string]'
    $createdOrUpdated = 0
    $unchanged = 0

    $characterProperties = $charactersProperty.Value.PSObject.Properties

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
        Get-ChildItem -LiteralPath $OutputDir -File -Filter 'hoja_*.json' -ErrorAction SilentlyContinue | ForEach-Object {
            if (-not $expectedFiles.Contains($_.Name.ToLowerInvariant())) {
                Remove-Item -LiteralPath $_.FullName -Force
                $deleted++
                Write-Log ("HOJA eliminada por no existir mas en JSON principal: {0}" -f $_.Name)
            }
        }
    }

    Write-Log ("OK: Hojas exportadas. Origen={0}, Personajes={1}, actualizadas={2}, sin_cambios={3}, eliminadas={4}" -f `
        (Split-Path -Leaf $mainJsonFile), $characterProperties.Count, $createdOrUpdated, $unchanged, $deleted)
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

    $missingSourceWarningShown = $false

    while (-not (Test-Path -LiteralPath $StopSignalFile)) {
        try {
            Export-CharacterSheetsOnce
            $missingSourceWarningShown = $false
        }
        catch {
            if (-not $missingSourceWarningShown) {
                Write-Warn $_.Exception.Message
                Write-Warn 'El exportador seguira corriendo y volvera a intentar en el proximo ciclo.'
                $missingSourceWarningShown = $true
            }
        }

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
