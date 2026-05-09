<#
.SYNOPSIS
Genera un indice Markdown de la historia oficial.

.DESCRIPTION
- Lee los capitulos Markdown desde ECE\Lore\Capitulos.
- Extrae el titulo del capitulo desde encabezados ##.
- Extrae los subtitulos desde encabezados ###.
- Genera ECE\Lore\Indice_Historia.md.
- Guarda hashes SHA-256 en ECE\Lore\Indice_Historia.hashes.json.
- Solo regenera el indice si cambio algun capitulo, si cambio la lista de archivos,
  o si el indice no existe.
- Puede correr una sola vez con -RunOnce o en loop hasta recibir StopSignalFile.
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

function Ensure-Directory([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) {
        [void](New-Item -ItemType Directory -Force -Path $Path)
    }
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

function Get-FileHashSha256([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function ConvertTo-ComparableJson($Value) {
    return ($Value | ConvertTo-Json -Depth 20 -Compress)
}

function Read-PreviousHashState {
    if (-not (Test-Path -LiteralPath $HashesPath)) {
        return $null
    }

    try {
        return Get-Content -LiteralPath $HashesPath -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        Write-Log ('WARNING: No se pudo leer el archivo de hashes. Se regenerara el indice. Detalle: {0}' -f $_.Exception.Message) -Color 'Yellow'
        return $null
    }
}

function Get-ChapterFiles {
    if (-not (Test-Path -LiteralPath $ChaptersDir)) {
        throw "No se encontro la carpeta de capitulos: $ChaptersDir"
    }

    return Get-ChildItem -LiteralPath $ChaptersDir -Filter '*.md' -File | Sort-Object Name
}

function Get-CurrentHashState($ChapterFiles) {
    $files = [ordered]@{}

    foreach ($file in $ChapterFiles) {
        $relativePath = Get-RelativePath -BasePath $LoreDir -FullPath $file.FullName
        $files[$relativePath] = Get-FileHashSha256 $file.FullName
    }

    return [ordered]@{
        version = 1
        source = 'Lore/Capitulos'
        output = 'Lore/Indice_Historia.md'
        files = $files
    }
}

function Test-IndexRegenerationNeeded {
    param(
        [Parameter(Mandatory = $true)] $CurrentHashState,
        $PreviousHashState
    )

    if (-not (Test-Path -LiteralPath $IndexPath)) {
        return $true
    }

    if (-not $PreviousHashState) {
        return $true
    }

    $previousFiles = [ordered]@{}
    if ($PreviousHashState.PSObject.Properties['files']) {
        foreach ($property in $PreviousHashState.files.PSObject.Properties) {
            $previousFiles[$property.Name] = [string]$property.Value
        }
    }

    $previousJson = ConvertTo-ComparableJson $previousFiles
    $currentJson = ConvertTo-ComparableJson $CurrentHashState.files

    return ($previousJson -ne $currentJson)
}

function Normalize-HeadingText([string]$Text) {
    if ([string]::IsNullOrWhiteSpace($Text)) {
        return ''
    }

    return ($Text -replace '\s+', ' ').Trim()
}

function Get-ChapterIndexData($File) {
    $content = Get-Content -LiteralPath $File.FullName -Raw -Encoding UTF8

    # Detecta headings aunque esten pegados en la misma linea:
    # ## Capitulo ... ### Escena ... ### Otra escena ...
    $matches = [regex]::Matches(
        $content,
        '(#{2,3})\s+(.+?)(?=\s+#{2,3}\s+|$)',
        [System.Text.RegularExpressions.RegexOptions]::Singleline
    )

    $chapterTitle = $null
    $subtitles = New-Object System.Collections.Generic.List[string]

    foreach ($match in $matches) {
        $level = $match.Groups[1].Value
        $title = Normalize-HeadingText $match.Groups[2].Value

        if ([string]::IsNullOrWhiteSpace($title)) {
            continue
        }

        if ($level -eq '##' -and -not $chapterTitle) {
            $chapterTitle = $title
        } elseif ($level -eq '###') {
            $subtitles.Add($title)
        }
    }

    if ([string]::IsNullOrWhiteSpace($chapterTitle)) {
        $chapterTitle = [System.IO.Path]::GetFileNameWithoutExtension($File.Name)
    }

    return [PSCustomObject]@{
        Title = $chapterTitle
        Subtitles = $subtitles
    }
}

function Write-TextFileIfChanged {
    param(
        [Parameter(Mandatory = $true)] [string]$Path,
        [Parameter(Mandatory = $true)] [string]$Content
    )

    $shouldWrite = $true

    if (Test-Path -LiteralPath $Path) {
        $existing = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
        if ($existing.TrimEnd() -eq $Content.TrimEnd()) {
            $shouldWrite = $false
        }
    }

    if ($shouldWrite) {
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($Path, $Content, $utf8NoBom)
        return $true
    }

    return $false
}

function Write-HashState {
    param(
        [Parameter(Mandatory = $true)] $CurrentHashState
    )

    $state = [ordered]@{
        version = $CurrentHashState.version
        generated_at = (Get-Date -Format o)
        source = $CurrentHashState.source
        output = $CurrentHashState.output
        files = $CurrentHashState.files
    }

    $json = ($state | ConvertTo-Json -Depth 20).TrimEnd() + [Environment]::NewLine
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($HashesPath, $json, $utf8NoBom)
}

function Generate-HistoryIndexOnce {
    Ensure-Directory $LoreDir

    $chapterFiles = @(Get-ChapterFiles)
    $currentHashState = Get-CurrentHashState $chapterFiles
    $previousHashState = Read-PreviousHashState

    $mustRegenerate = Test-IndexRegenerationNeeded -CurrentHashState $currentHashState -PreviousHashState $previousHashState

    if (-not $mustRegenerate) {
        return
    }

    $lines = New-Object System.Collections.Generic.List[string]

    $lines.Add('# Indice de historia - Ecos del Circulo Eterno')
    $lines.Add('')
    $lines.Add('> Indice generado automaticamente desde `Lore/Capitulos`.')
    $lines.Add('> No editar manualmente.')
    $lines.Add('')

    foreach ($file in $chapterFiles) {
        $indexData = Get-ChapterIndexData $file
        $relativePath = Get-RelativePath -BasePath $LoreDir -FullPath $file.FullName

        $lines.Add(('## {0}' -f $indexData.Title))
        $lines.Add(('Archivo: `Lore/{0}`' -f $relativePath))
        $lines.Add('')

        foreach ($subtitle in $indexData.Subtitles) {
            $lines.Add(('- {0}' -f $subtitle))
        }

        $lines.Add('')
    }

    $content = ($lines -join [Environment]::NewLine).TrimEnd() + [Environment]::NewLine
    $indexWritten = Write-TextFileIfChanged -Path $IndexPath -Content $content

    Write-HashState -CurrentHashState $currentHashState

    if ($indexWritten) {
        Write-Log ('REGENERADO {0}' -f $IndexPath)
    } else {
        Write-Log ('Hashes actualizados. El contenido del indice no cambio: {0}' -f $IndexPath)
    }
}

# ============================================================
# Flujo principal
# ============================================================

try {
    do {
        Generate-HistoryIndexOnce

        if ($RunOnce) {
            break
        }

        if (-not (Test-ShouldStop)) {
            Start-Sleep -Seconds $IntervalSeconds
        }
    } while (-not (Test-ShouldStop))

    if (-not $RunOnce) {
        Generate-HistoryIndexOnce
    }
    exit 0
} catch {
    Write-Log ('ERROR: {0}' -f $_.Exception.Message) -Color 'Red'
    Wait-BeforeExitOnError
    exit 1
}
