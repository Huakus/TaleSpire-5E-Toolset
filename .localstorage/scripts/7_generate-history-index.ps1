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
        $ordered[$key] = $Hashtable[$key]
    }

    return ($ordered | ConvertTo-Json -Compress)
}

function Get-CurrentChapterHashes {
    param([Parameter(Mandatory = $true)] [System.IO.FileInfo[]]$ChapterFiles)

    $hashes = @{}

    foreach ($file in $ChapterFiles) {
        $relativePath = Get-RelativePath -BasePath $LoreDir -FullPath $file.FullName
        $hashes[$relativePath] = Get-FileHashSha256 -Path $file.FullName
    }

    return $hashes
}

function Get-PreviousChapterHashes {
    if (-not (Test-Path -LiteralPath $HashesPath)) { return $null }

    try {
        $json = Get-Content -LiteralPath $HashesPath -Raw | ConvertFrom-Json
        if (-not $json.files) { return $null }

        $hashes = @{}
        foreach ($property in $json.files.PSObject.Properties) {
            $hashes[$property.Name] = [string]$property.Value
        }

        return $hashes
    } catch {
        Write-Log ("WARNING: No se pudo leer el archivo de hashes. Se regenerara el indice. Detalle: {0}" -f $_.Exception.Message) -Color 'Yellow'
        return $null
    }
}

function Test-HashesChanged {
    param(
        [hashtable]$PreviousHashes,
        [hashtable]$CurrentHashes
    )

    if (-not $PreviousHashes) { return $true }
    if ($PreviousHashes.Count -ne $CurrentHashes.Count) { return $true }

    foreach ($key in $CurrentHashes.Keys) {
        if (-not $PreviousHashes.ContainsKey($key)) { return $true }
        if ($PreviousHashes[$key] -ne $CurrentHashes[$key]) { return $true }
    }

    return $false
}

function Get-MarkdownHeadings {
    param([Parameter(Mandatory = $true)] [string]$Content)

    $matches = [regex]::Matches(
        $Content,
        '(#{2,3})\s+(.+?)(?=\s+#{2,3}\s+|$)',
        [System.Text.RegularExpressions.RegexOptions]::Singleline
    )

    $result = New-Object System.Collections.Generic.List[object]

    foreach ($match in $matches) {
        $level = $match.Groups[1].Value
        $title = ($match.Groups[2].Value -replace '\s+', ' ').Trim()
        $title = $title -replace '^#+\s*', ''
        $title = $title.Trim()

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
        $orderedFiles[$key] = $Hashes[$key]
    }

    $state = [ordered]@{
        generated_at = (Get-Date -Format o)
        files = $orderedFiles
    }

    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    $json = $state | ConvertTo-Json -Depth 5
    [System.IO.File]::WriteAllText($HashesPath, $json, $utf8NoBom)
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
    $previousHashes = Get-PreviousChapterHashes

    $mustRegenerate = -not (Test-Path -LiteralPath $IndexPath)

    if (-not $mustRegenerate) {
        $mustRegenerate = Test-HashesChanged -PreviousHashes $previousHashes -CurrentHashes $currentHashes
    }

    if (-not $mustRegenerate) {
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
