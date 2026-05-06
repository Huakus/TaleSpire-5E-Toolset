<#
.SYNOPSIS
  Exporta una hoja TXT por cada personaje del JSON principal del Toolset.

.DESCRIPTION
  - Busca dentro de .localstorage un archivo que contenga el nodo "characters".
  - Parsea el JSON principal con ConvertFrom-Json.
  - Antes de parsear, reemplaza en memoria las keys vacias "": por "toolsetEmptyKey":.
  - Genera un archivo .txt por personaje en ECE\Hojas.
  - El nombre del archivo sale dinamicamente del nombre/key del personaje.
  - Borra hojas viejas que ya no correspondan a personajes actuales.
  - Corre en loop hasta recibir la senal de stop.
#>

param(
    [string]$StopSignalFile,
    [int]$IntervalSeconds = 10,
    [switch]$RunOnce,
    [switch]$NoPauseOnError
)

$ErrorActionPreference = 'Stop'

# ============================================================
# Paths base
# ============================================================

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$LocalStorageDir = Split-Path -Parent $ScriptDir
$OutputDir = Join-Path $LocalStorageDir 'ECE\Hojas'

# Carpetas que no tiene sentido revisar al buscar el JSON principal.
$IgnoredDirectoryNames = @(
    'Hojas',
    '.runtime',
    '.tmp.driveupload',
    '.vscode',
    '.git',
    'node_modules'
)

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

function Test-ShouldStop {
    return ($StopSignalFile -and (Test-Path -LiteralPath $StopSignalFile))
}

function Ensure-Directory([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) {
        [void](New-Item -ItemType Directory -Force -Path $Path)
    }
}

function Remove-Accents([string]$Text) {
    if ([string]::IsNullOrWhiteSpace($Text)) {
        return ''
    }

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

function ConvertTo-SafeFilePart([string]$Name) {
    $value = Remove-Accents $Name
    $value = $value.ToLowerInvariant()
    $value = $value -replace '[^a-z0-9]+', '_'
    $value = $value -replace '_+', '_'
    $value = $value.Trim('_')

    if ([string]::IsNullOrWhiteSpace($value)) {
        return 'sin_nombre'
    }

    return $value
}

function Get-TextFileCandidates([string]$RootPath) {
    $allFiles = Get-ChildItem -LiteralPath $RootPath -File -Recurse -ErrorAction SilentlyContinue

    foreach ($file in $allFiles) {
        $directoryNames = $file.DirectoryName.Substring($RootPath.Length).Split([IO.Path]::DirectorySeparatorChar, [StringSplitOptions]::RemoveEmptyEntries)
        $isIgnored = $false

        foreach ($dirName in $directoryNames) {
            if ($IgnoredDirectoryNames -contains $dirName) {
                $isIgnored = $true
                break
            }
        }

        if ($isIgnored) {
            continue
        }

        # El JSON principal de TaleSpire puede venir sin extension.
        if ($file.Extension -eq '.json' -or [string]::IsNullOrWhiteSpace($file.Extension)) {
            $file
        }
    }
}

function ConvertFrom-ToolsetJson([string]$JsonText) {
    # Windows PowerShell se rompe con propiedades cuyo nombre es vacio: "": 0
    # Lo renombramos solo en memoria. Opcion A: los archivos exportados quedan con toolsetEmptyKey.
    $fixedJsonText = $JsonText -replace '([\{,]\s*)""\s*:', '$1"toolsetEmptyKey":'
    return $fixedJsonText | ConvertFrom-Json
}

function Find-MainJsonFile {
    $checked = 0
    $withCharactersText = 0
    $parseErrors = @()

    $candidates = Get-TextFileCandidates $LocalStorageDir

    foreach ($file in $candidates) {
        $checked++

        try {
            $text = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8

            if ($text -notmatch '"characters"\s*:') {
                continue
            }

            $withCharactersText++
            $data = ConvertFrom-ToolsetJson $text

            if ($null -ne $data.PSObject.Properties['characters']) {
                return [PSCustomObject]@{
                    Path = $file.FullName
                    Data = $data
                    Checked = $checked
                    WithCharactersText = $withCharactersText
                    ParseErrors = $parseErrors
                }
            }
        }
        catch {
            $parseErrors += ('{0}: {1}' -f $file.FullName, $_.Exception.Message)
        }
    }

    return [PSCustomObject]@{
        Path = $null
        Data = $null
        Checked = $checked
        WithCharactersText = $withCharactersText
        ParseErrors = $parseErrors
    }
}

function Write-JsonIfChanged {
    param(
        [string]$Path,
        [string]$Content
    )

    $shouldWrite = $true

    if (Test-Path -LiteralPath $Path) {
        $existing = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
        if ($existing.TrimEnd() -eq $Content.TrimEnd()) {
            $shouldWrite = $false
        }
    }

    if ($shouldWrite) {
        $Content | Set-Content -LiteralPath $Path -Encoding UTF8
        Write-Log ('EXPORTADO {0}' -f $Path)
        return $true
    }

    return $false
}

function Export-CharacterSheetsOnce {
    Ensure-Directory $OutputDir

    $mainJson = Find-MainJsonFile

    if (-not $mainJson.Path) {
        $message = 'WARNING: No se encontro ningun JSON principal con nodo characters. Carpeta revisada recursivamente: {0}. Archivos candidatos revisados={1}, con texto characters={2}.' -f $LocalStorageDir, $mainJson.Checked, $mainJson.WithCharactersText

        if ($mainJson.ParseErrors.Count -gt 0) {
            $message += ' Errores de parseo: ' + ($mainJson.ParseErrors -join ' | ')
        }

        Write-Log $message
        return
    }

    $characters = $mainJson.Data.characters
    $expectedFiles = @{}
    $exportedCount = 0
    $updatedCount = 0

    foreach ($characterProperty in $characters.PSObject.Properties) {
        $characterName = $characterProperty.Name
        $characterData = $characterProperty.Value

        $safeName = ConvertTo-SafeFilePart $characterName
        $fileName = 'hoja_{0}.txt' -f $safeName
        $filePath = Join-Path $OutputDir $fileName

        $expectedFiles[$fileName.ToLowerInvariant()] = $true

        # Opcion A: la key vacia queda exportada como toolsetEmptyKey. El contenido sigue siendo JSON, pero el archivo es .txt.
        $characterJson = $characterData | ConvertTo-Json -Depth 100
        $characterJson = $characterJson.TrimEnd() + [Environment]::NewLine

        $exportedCount++
        if (Write-JsonIfChanged -Path $filePath -Content $characterJson) {
            $updatedCount++
        }
    }

    # Borra hojas anteriores que ya no correspondan a ningun personaje actual.
    $deletedCount = 0
    $oldFiles = Get-ChildItem -LiteralPath $OutputDir -File -Filter 'hoja_*.*' -ErrorAction SilentlyContinue

    foreach ($oldFile in $oldFiles) {
        if (-not $expectedFiles.ContainsKey($oldFile.Name.ToLowerInvariant())) {
            Remove-Item -LiteralPath $oldFile.FullName -Force
            Write-Log ('BORRADO {0}' -f $oldFile.FullName)
            $deletedCount++
        }
    }

    if ($updatedCount -gt 0 -or $deletedCount -gt 0) {
        Write-Log ('OK: Hojas procesadas={0}, actualizadas={1}, borradas={2}. Fuente: {3}' -f $exportedCount, $updatedCount, $deletedCount, $mainJson.Path)
    }
}

# ============================================================
# Flujo principal
# ============================================================

try {
    Write-Log 'Iniciando exportador de hojas de personajes...'
    Write-Log ('Carpeta destino: {0}' -f $OutputDir)

    do {
        Export-CharacterSheetsOnce

        if ($RunOnce) {
            break
        }

        if (-not (Test-ShouldStop)) {
            Start-Sleep -Seconds $IntervalSeconds
        }
    } while (-not (Test-ShouldStop))

    if (-not $RunOnce) {
        Write-Log 'Senal de stop recibida. Ejecutando exportacion final de hojas...'
        Export-CharacterSheetsOnce
    }

    Write-Log 'OK: Exportador de hojas finalizado.'
    exit 0
}
catch {
    Write-Log ('ERROR: {0}' -f $_.Exception.Message)
    Wait-BeforeExitOnError
    exit 1
}
