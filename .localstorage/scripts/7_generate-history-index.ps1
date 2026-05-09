<#
.SYNOPSIS
Genera Lore\Indice_Historia.md desde Lore\Capitulos.

.DESCRIPTION
- Lee todos los .md de ECE\Lore\Capitulos.
- Extrae headings ## y ###.
- Genera ECE\Lore\Indice_Historia.md.
- Guarda ECE\Lore\Indice_Historia.hashes.json para evitar regenerar si no hubo cambios.

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
$LoreDir = Join-Path $LocalStorageDir 'ECE\Lore'
$ChaptersDir = Join-Path $LoreDir 'Capitulos'
$IndexPath = Join-Path $LoreDir 'Indice_Historia.md'
$HashesPath = Join-Path $LoreDir 'Indice_Historia.hashes.json'
$IndexGeneratorVersion = 2

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

function Get-FileHashSha256 {
    param([Parameter(Mandatory = $true)] [string]$Path)

    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-RelativePath {
    param(
        [Parameter(Mandatory = $true)] [string]$BasePath,
        [Parameter(Mandatory = $true)] [string]$FullPath
    )

    $baseFullPath = [System.IO.Path]::GetFullPath($BasePath)
    $targetFullPath = [System.IO.Path]::GetFullPath($FullPath)

    if (-not $baseFullPath.EndsWith([System.IO.Path]::DirectorySeparatorChar)) {
        $baseFullPath += [System.IO.Path]::DirectorySeparatorChar
    }

    $baseUri = New-Object System.Uri($baseFullPath)
    $targetUri = New-Object System.Uri($targetFullPath)
    $relativeUri = $baseUri.MakeRelativeUri($targetUri)

    return [System.Uri]::UnescapeDataString($relativeUri.ToString()) -replace '\\', '/'
}

function Convert-HashtableToStableJson {
    param([Parameter(Mandatory = $true)] [hashtable]$Hashtable)

    $ordered = [ordered]@{}
    foreach ($key in ($Hashtable.Keys | Sort-Object)) {
        $ordered[[string]$key] = [string]$Hashtable[$key]
    }

    return ($ordered | ConvertTo-Json -Compress)
}

function Convert-FilesObjectToStableJson {
    param([Parameter(Mandatory = $true)] $FilesObject)

    $hashes = @{}

    foreach ($property in $FilesObject.PSObject.Properties) {
        $hashes[[string]$property.Name] = [string]$property.Value
    }

    return [string](Convert-HashtableToStableJson -Hashtable $hashes)
}

function Get-CurrentChapterHashes {
    param([Parameter(Mandatory = $true)] [System.IO.FileInfo[]]$ChapterFiles)

    $hashes = @{}

    foreach ($file in $ChapterFiles) {
        $relativePath = Get-RelativePath -BasePath $LoreDir -FullPath $file.FullName
        $hashes[[string]$relativePath] = Get-FileHashSha256 -Path $file.FullName
    }

    # Evita que PowerShell enumere el hashtable al retornarlo.
    return ,$hashes
}

function Get-PreviousHashState {
    if (-not (Test-Path -LiteralPath $HashesPath)) { return $null }

    try {
        $json = Get-Content -LiteralPath $HashesPath -Raw | ConvertFrom-Json
        $filesProperty = $json.PSObject.Properties | Where-Object { $_.Name -eq 'files' } | Select-Object -First 1

        if ($null -eq $filesProperty) { return $null }
        if ($null -eq $filesProperty.Value) { return $null }

        $versionProperty = $json.PSObject.Properties | Where-Object { $_.Name -eq 'index_generator_version' } | Select-Object -First 1
        $version = 0
        if ($null -ne $versionProperty -and $null -ne $versionProperty.Value) {
            $version = [int]$versionProperty.Value
        }

        return [PSCustomObject]@{
            FilesStableJson = [string](Convert-FilesObjectToStableJson -FilesObject $filesProperty.Value)
            Version = $version
            HasVolatileMetadata = [bool]($json.PSObject.Properties.Name -contains 'generated_at')
        }
    } catch {
        Write-Log ("WARNING: No se pudo leer el archivo de hashes. Se regenerara el indice. Detalle: {0}" -f $_.Exception.Message) -Color 'Yellow'
        return $null
    }
}

function Test-HashesChanged {
    param(
        [string]$PreviousHashesStableJson,
        [string]$CurrentHashesStableJson
    )

    if ([string]::IsNullOrWhiteSpace($PreviousHashesStableJson)) { return $true }
    return ($PreviousHashesStableJson -ne $CurrentHashesStableJson)
}

function Remove-InlineHeadingBody {
    param(
        [Parameter(Mandatory = $true)] [string]$Text,
        [Parameter(Mandatory = $true)] [string]$Level
    )

    $title = ($Text -replace '\s+', ' ').Trim()
    $title = $title -replace '^#+\s*', ''
    $title = $title.Trim()

    if ([string]::IsNullOrWhiteSpace($title)) { return $title }

    # Los capitulos pueden tener el heading y el cuerpo en la misma linea:
    # "### Subtitulo Texto narrativo...".
    # Como no hay un separador formal entre titulo y cuerpo, cortamos de forma
    # conservadora ante comienzos habituales de parrafos narrativos, pero solo
    # despues de una longitud minima para no cortar nombres dentro del subtitulo.
    $minimumTitleLength = 35
    if ($Level -eq '##') { $minimumTitleLength = 18 }

    $bodyStartPatterns = @(
        'Adler', 'Delerion', 'Varka', 'Borgar', 'Mercion', 'Juanpi', 'Skitrixx', 'Ernesto',
        'Los aventureros', 'Las aventureras', 'El grupo', 'La partida', 'Los heroes', 'Nuestros heroes',
        'Ahí', 'Alli', 'Al llegar', 'Antes de', 'Despues de', 'Durante', 'Mientras', 'Entonces',
        'Cuando', 'Tras', 'Luego', 'Finalmente', 'Parece', 'Se trata', 'Todavia', 'Usando',
        'Dentro de', 'Toma', 'Avanzan', 'Intentan', 'Cuentan', 'Llegan', 'Llega', 'Al cabo de'
    )

    foreach ($pattern in $bodyStartPatterns) {
        $escaped = [regex]::Escape($pattern)
        $matches = [regex]::Matches($title, ('\s+{0}\b' -f $escaped))

        foreach ($match in $matches) {
            if ($match.Index -ge $minimumTitleLength) {
                return $title.Substring(0, $match.Index).Trim()
            }
        }
    }

    # Ultima defensa: si aun parece excesivamente largo, cortar en puntuacion.
    $maxReasonableTitleLength = 150
    if ($title.Length -gt $maxReasonableTitleLength) {
        $punctuationMatch = [regex]::Match($title.Substring(0, [Math]::Min($title.Length, 220)), '[\.!?;:]\s+')
        if ($punctuationMatch.Success -and $punctuationMatch.Index -ge $minimumTitleLength) {
            return $title.Substring(0, $punctuationMatch.Index).Trim()
        }
    }

    return $title
}

function Get-MarkdownHeadings {
    param([Parameter(Mandatory = $true)] [string]$Content)

    $matches = [regex]::Matches(
        $Content,
        '(?m)(#{2,3})\s+(.+?)(?=\s+#{2,3}\s+|\r?\n|$)',
        [System.Text.RegularExpressions.RegexOptions]::None
    )

    $result = New-Object System.Collections.Generic.List[object]

    foreach ($match in $matches) {
        $level = $match.Groups[1].Value
        $rawTitle = $match.Groups[2].Value
        $title = Remove-InlineHeadingBody -Text $rawTitle -Level $level

        if (-not [string]::IsNullOrWhiteSpace($title)) {
            $result.Add([PSCustomObject]@{
                Level = $level
                Title = $title
            })
        }
    }

    return $result
}

function Write-IndexFile {
    param([Parameter(Mandatory = $true)] [System.IO.FileInfo[]]$ChapterFiles)

    $lines = New-Object System.Collections.Generic.List[string]

    $lines.Add('# Indice de historia - Ecos del Circulo Eterno')
    $lines.Add('')
    $lines.Add('> Indice generado automaticamente desde `Lore/Capitulos`.')
    $lines.Add('> No editar manualmente.')
    $lines.Add('')

    foreach ($file in $ChapterFiles) {
        $content = Get-Content -LiteralPath $file.FullName -Raw
        $relativePath = Get-RelativePath -BasePath $LoreDir -FullPath $file.FullName
        $headings = Get-MarkdownHeadings -Content $content

        $chapterTitle = $null
        $subtitles = New-Object System.Collections.Generic.List[string]

        foreach ($heading in $headings) {
            if ($heading.Level -eq '##' -and -not $chapterTitle) {
                $chapterTitle = $heading.Title
            } elseif ($heading.Level -eq '###') {
                $subtitles.Add($heading.Title)
            }
        }

        if (-not $chapterTitle) {
            $chapterTitle = [System.IO.Path]::GetFileNameWithoutExtension($file.Name)
        }

        $lines.Add("## $chapterTitle")
        $lines.Add(('Archivo: `Lore/{0}`' -f $relativePath))
        $lines.Add('')

        foreach ($subtitle in $subtitles) {
            $lines.Add("- $subtitle")
        }

        $lines.Add('')
    }

    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllLines($IndexPath, $lines, $utf8NoBom)
}

function Write-HashesFile {
    param([Parameter(Mandatory = $true)] [hashtable]$Hashes)

    $orderedFiles = [ordered]@{}
    foreach ($key in ($Hashes.Keys | Sort-Object)) {
        $orderedFiles[$key] = [string]$Hashes[$key]
    }

    # Importante: no guardar timestamps ni metadata volatil.
    # Este archivo debe cambiar solo cuando cambian los capitulos.
    $state = [ordered]@{
        index_generator_version = $IndexGeneratorVersion
        files = $orderedFiles
    }

    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    $json = $state | ConvertTo-Json -Depth 5

    $existingJson = $null
    if (Test-Path -LiteralPath $HashesPath) {
        $existingJson = Get-Content -LiteralPath $HashesPath -Raw
    }

    if ($existingJson -ne $json) {
        [System.IO.File]::WriteAllText($HashesPath, $json, $utf8NoBom)
    }
}

function Invoke-GenerateHistoryIndexOnce {
    Ensure-Directory $LoreDir

    if (-not (Test-Path -LiteralPath $ChaptersDir)) {
        Write-Log ("WARNING: No existe la carpeta de capitulos: {0}" -f $ChaptersDir) -Color 'Yellow'
        return
    }

    $chapterFiles = @(Get-ChildItem -LiteralPath $ChaptersDir -Filter '*.md' -File | Sort-Object Name)

    if ($chapterFiles.Count -eq 0) {
        Write-Log ("WARNING: No hay capitulos .md en: {0}" -f $ChaptersDir) -Color 'Yellow'
        return
    }

    $currentHashes = Get-CurrentChapterHashes -ChapterFiles $chapterFiles
    $currentHashesStableJson = [string](Convert-HashtableToStableJson -Hashtable $currentHashes)
    $previousState = Get-PreviousHashState
    $previousHashesStableJson = $null
    $previousVersion = 0
    $hasVolatileMetadata = $false

    if ($null -ne $previousState) {
        $previousHashesStableJson = [string]$previousState.FilesStableJson
        $previousVersion = [int]$previousState.Version
        $hasVolatileMetadata = [bool]$previousState.HasVolatileMetadata
    }

    $mustRegenerate = -not (Test-Path -LiteralPath $IndexPath)

    if (-not $mustRegenerate) {
        $mustRegenerate = Test-HashesChanged `
            -PreviousHashesStableJson $previousHashesStableJson `
            -CurrentHashesStableJson $currentHashesStableJson
    }

    if (-not $mustRegenerate -and $previousVersion -ne $IndexGeneratorVersion) {
        # Fuerza regeneracion cuando cambia la logica que extrae titulos/subtitulos.
        $mustRegenerate = $true
    }

    if (-not $mustRegenerate) {
        # Migra una sola vez el archivo viejo si todavia tenia generated_at.
        # No toca Indice_Historia.md y no loguea ruido.
        if ($hasVolatileMetadata) {
            Write-HashesFile -Hashes $currentHashes
        }

        if (-not $Quiet) {
            Write-Log 'Indice_Historia.md actualizado. No hay cambios en capitulos.'
        }
        return
    }

    Write-IndexFile -ChapterFiles $chapterFiles
    Write-HashesFile -Hashes $currentHashes

    Write-Log ("REGENERADO {0}" -f $IndexPath)
}

# ============================================================
# Flujo principal
# ============================================================

try {
    if (-not $Quiet) {
        Write-Log 'Iniciando generador de indice de historia...'
        Write-Log ("Carpeta origen: {0}" -f $ChaptersDir)
        Write-Log ("Archivo destino: {0}" -f $IndexPath)
    }

    if ($RunOnce) {
        Invoke-GenerateHistoryIndexOnce
        return
    }

    while (-not (Test-ShouldStop)) {
        Invoke-GenerateHistoryIndexOnce
        Start-Sleep -Seconds $IntervalSeconds
    }
} catch {
    Write-Log ("ERROR: {0}" -f $_.Exception.Message) -Color 'Red'
    Wait-BeforeExitOnError
    throw
}
