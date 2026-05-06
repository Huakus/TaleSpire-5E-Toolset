<#
.SYNOPSIS
  Exporta una hoja JSON por cada personaje definido en el JSON principal del Toolset.

.DESCRIPTION
  Lee el JSON principal del symbiote, detecta el nodo top-level "characters"
  y genera/actualiza un archivo por personaje en ECE\Hojas.

  Importante: no usa ConvertFrom-Json para parsear el JSON principal, porque
  las hojas pueden traer propiedades con nombre vacio (""), y Windows PowerShell
  falla al convertir eso a PSCustomObject.

  En su lugar, extrae los objetos de characters leyendo el JSON como texto y
  respetando llaves, corchetes y strings. Asi preserva el contenido del personaje
  tal como viene en el archivo principal.
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

function Skip-JsonWhitespace {
    param(
        [string]$Text,
        [ref]$Index
    )

    while ($Index.Value -lt $Text.Length) {
        $c = $Text[$Index.Value]
        if ($c -ne ' ' -and $c -ne "`t" -and $c -ne "`r" -and $c -ne "`n") {
            break
        }
        $Index.Value++
    }
}

function ConvertFrom-JsonStringLiteralContent {
    param([string]$Value)

    $result = New-Object System.Text.StringBuilder
    $i = 0

    while ($i -lt $Value.Length) {
        $c = $Value[$i]

        if ($c -ne '\') {
            [void]$result.Append($c)
            $i++
            continue
        }

        $i++
        if ($i -ge $Value.Length) {
            [void]$result.Append('\')
            break
        }

        $esc = $Value[$i]
        switch ($esc) {
            '"' { [void]$result.Append('"') }
            '\' { [void]$result.Append('\') }
            '/'  { [void]$result.Append('/') }
            'b'  { [void]$result.Append([char]8) }
            'f'  { [void]$result.Append([char]12) }
            'n'  { [void]$result.Append("`n") }
            'r'  { [void]$result.Append("`r") }
            't'  { [void]$result.Append("`t") }
            'u'  {
                if ($i + 4 -lt $Value.Length) {
                    $hex = $Value.Substring($i + 1, 4)
                    try {
                        $code = [Convert]::ToInt32($hex, 16)
                        [void]$result.Append([char]$code)
                        $i += 4
                    }
                    catch {
                        [void]$result.Append('\u')
                    }
                }
                else {
                    [void]$result.Append('\u')
                }
            }
            default { [void]$result.Append($esc) }
        }

        $i++
    }

    return $result.ToString()
}

function Read-JsonStringLiteral {
    param(
        [string]$Text,
        [ref]$Index
    )

    if ($Index.Value -ge $Text.Length -or $Text[$Index.Value] -ne '"') {
        throw "Se esperaba string JSON en posicion $($Index.Value)."
    }

    $Index.Value++
    $start = $Index.Value
    $escaped = $false

    while ($Index.Value -lt $Text.Length) {
        $c = $Text[$Index.Value]

        if ($escaped) {
            $escaped = $false
            $Index.Value++
            continue
        }

        if ($c -eq '\') {
            $escaped = $true
            $Index.Value++
            continue
        }

        if ($c -eq '"') {
            $rawContent = $Text.Substring($start, $Index.Value - $start)
            $Index.Value++
            return ConvertFrom-JsonStringLiteralContent $rawContent
        }

        $Index.Value++
    }

    throw 'String JSON sin cierre.'
}

function Get-JsonValueEndIndex {
    param(
        [string]$Text,
        [int]$StartIndex
    )

    $i = $StartIndex
    if ($i -ge $Text.Length) {
        throw 'Valor JSON vacio.'
    }

    $first = $Text[$i]

    if ($first -eq '"') {
        $refIndex = [ref]$i
        [void](Read-JsonStringLiteral -Text $Text -Index $refIndex)
        return $refIndex.Value
    }

    if ($first -eq '{' -or $first -eq '[') {
        $stack = New-Object System.Collections.Generic.Stack[char]
        [void]$stack.Push($first)
        $i++
        $inString = $false
        $escaped = $false

        while ($i -lt $Text.Length) {
            $c = $Text[$i]

            if ($inString) {
                if ($escaped) {
                    $escaped = $false
                }
                elseif ($c -eq '\') {
                    $escaped = $true
                }
                elseif ($c -eq '"') {
                    $inString = $false
                }

                $i++
                continue
            }

            if ($c -eq '"') {
                $inString = $true
                $i++
                continue
            }

            if ($c -eq '{' -or $c -eq '[') {
                [void]$stack.Push($c)
                $i++
                continue
            }

            if ($c -eq '}' -or $c -eq ']') {
                if ($stack.Count -eq 0) {
                    throw "Cierre JSON inesperado en posicion $i."
                }

                $open = $stack.Pop()
                if (($open -eq '{' -and $c -ne '}') -or ($open -eq '[' -and $c -ne ']')) {
                    throw "Cierre JSON invalido en posicion $i."
                }

                $i++
                if ($stack.Count -eq 0) {
                    return $i
                }

                continue
            }

            $i++
        }

        throw 'Objeto/array JSON sin cierre.'
    }

    # Primitivos: true, false, null, numeros.
    while ($i -lt $Text.Length) {
        $c = $Text[$i]
        if ($c -eq ',' -or $c -eq '}' -or $c -eq ']' -or $c -eq ' ' -or $c -eq "`t" -or $c -eq "`r" -or $c -eq "`n") {
            break
        }
        $i++
    }

    return $i
}

function Get-CharactersFromMainJsonText {
    param([string]$Raw)

    $match = [regex]::Match($Raw, '"characters"\s*:')
    if (-not $match.Success) {
        return @()
    }

    $i = $match.Index + $match.Length
    $refIndex = [ref]$i
    Skip-JsonWhitespace -Text $Raw -Index $refIndex
    $i = $refIndex.Value

    if ($i -ge $Raw.Length -or $Raw[$i] -ne '{') {
        throw "El nodo characters existe, pero no parece ser un objeto JSON."
    }

    $i++
    $characters = New-Object System.Collections.Generic.List[object]

    while ($i -lt $Raw.Length) {
        $refIndex = [ref]$i
        Skip-JsonWhitespace -Text $Raw -Index $refIndex
        $i = $refIndex.Value

        if ($i -lt $Raw.Length -and $Raw[$i] -eq '}') {
            break
        }

        if ($i -lt $Raw.Length -and $Raw[$i] -eq ',') {
            $i++
            continue
        }

        $refIndex = [ref]$i
        $name = Read-JsonStringLiteral -Text $Raw -Index $refIndex
        $i = $refIndex.Value

        $refIndex = [ref]$i
        Skip-JsonWhitespace -Text $Raw -Index $refIndex
        $i = $refIndex.Value

        if ($i -ge $Raw.Length -or $Raw[$i] -ne ':') {
            throw "Se esperaba ':' despues del nombre de personaje '$name'."
        }

        $i++
        $refIndex = [ref]$i
        Skip-JsonWhitespace -Text $Raw -Index $refIndex
        $i = $refIndex.Value

        $valueStart = $i
        $valueEnd = Get-JsonValueEndIndex -Text $Raw -StartIndex $valueStart
        $valueRaw = $Raw.Substring($valueStart, $valueEnd - $valueStart).Trim()

        $characters.Add([pscustomobject]@{
            Name = $name
            RawJson = $valueRaw
        }) | Out-Null

        $i = $valueEnd
    }

    return @($characters)
}

function Test-ShouldIgnoreCandidateFile([System.IO.FileInfo]$File) {
    $fullName = $File.FullName

    if ($File.Name -ieq 'desktop.ini') { return $true }
    if ($File.Name -like 'hoja_*.json') { return $true }
    if ($File.Name -like '_*.json') { return $true }
    if ($File.Extension -notin @('', '.json')) { return $true }

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

            if ($raw -notmatch '"characters"\s*:') {
                if ($VerboseSearch) { Write-Log ("DEBUG: sin nodo characters: {0}" -f $file.FullName) }
                continue
            }

            $jsonLikeCount++
            $characters = Get-CharactersFromMainJsonText -Raw $raw

            if ($characters.Count -gt 0) {
                return $file.FullName
            }
        }
        catch {
            [void]$errors.Add(("{0}: {1}" -f $file.FullName, $_.Exception.Message))
        }
    }

    $message = "No se encontro ningun JSON principal con nodo 'characters'. Carpeta revisada recursivamente: $LocalStorageDir. Archivos candidatos revisados=$checkedCount, con texto characters=$jsonLikeCount."

    if ($errors.Count -gt 0) {
        $message += " Errores de parseo: " + (($errors | Select-Object -First 5) -join ' | ')
    }

    throw $message
}

function Write-TextIfChanged {
    param(
        [string]$Path,
        [string]$Content
    )

    $newContent = $Content.Trim() + [Environment]::NewLine

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
    $raw = Read-JsonText $mainJsonFile
    $characters = Get-CharactersFromMainJsonText -Raw $raw

    if ($characters.Count -eq 0) {
        throw "El JSON principal tiene nodo characters, pero no se detectaron personajes: $mainJsonFile"
    }

    if (-not (Test-Path -LiteralPath $OutputDir)) {
        [void](New-Item -ItemType Directory -Force -Path $OutputDir)
    }

    $expectedFiles = New-Object 'System.Collections.Generic.HashSet[string]'
    $createdOrUpdated = 0
    $unchanged = 0

    foreach ($character in $characters) {
        $safeName = ConvertTo-SafeFileName $character.Name
        $fileName = "hoja_$safeName.json"
        $outputPath = Join-Path $OutputDir $fileName

        [void]$expectedFiles.Add($fileName.ToLowerInvariant())

        $changed = Write-TextIfChanged -Path $outputPath -Content $character.RawJson
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
        (Split-Path -Leaf $mainJsonFile), $characters.Count, $createdOrUpdated, $unchanged, $deleted)
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

    try {
        Export-CharacterSheetsOnce
    }
    catch {
        Write-Warn ("No se pudo ejecutar el export final: {0}" -f $_.Exception.Message)
    }

    exit 0
}
catch {
    Write-Log ("ERROR: {0}" -f $_.Exception.Message)
    Wait-BeforeExitOnError
    exit 1
}
