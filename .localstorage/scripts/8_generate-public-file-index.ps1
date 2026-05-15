<#
.SYNOPSIS
 Genera el indice publico de archivos del repo Toolset.

.DESCRIPTION
 Responsabilidad unica:
 - Recorrer el repo local del Toolset.
 - Generar PUBLIC_FILE_INDEX.md con la ruta relativa y la URL publica de cada archivo publicado.

 Este script NO sincroniza Git y NO publica en WordPress.

.PARAMETER Repo
 Carpeta local del repo Toolset.

.PARAMETER BaseUrl
 URL publica base donde se publica el repo completo.

.PARAMETER OutputRelativePath
 Ruta relativa del indice generado dentro del repo.
#>
param(
 [Parameter(Mandatory = $true)]
 [string]$Repo,

 [string]$BaseUrl = 'https://elcirculoeterno.macreative.site/campaign_files/toolset',

 [string]$OutputRelativePath = 'PUBLIC_FILE_INDEX.md'
)

$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$CommonLoggingScript = Join-Path $ScriptDir '0_common-logging.ps1'

if (Test-Path $CommonLoggingScript) {
 . $CommonLoggingScript
}

function Write-IndexLog([string]$Message, [string]$Color = 'White') {
 if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
  Write-Log $Message -Color $Color
 }
 else {
  Write-Host $Message
 }
}

function ConvertTo-RelativePath([string]$Root, [string]$FullName) {
 $rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
 $fileFull = [System.IO.Path]::GetFullPath($FullName)
 $relative = $fileFull.Substring($rootFull.Length + 1)
 return ($relative -replace '\\', '/')
}

function ConvertTo-PublicUrl([string]$BaseUrl, [string]$RelativePath) {
 $base = $BaseUrl.TrimEnd('/')
 $segments = $RelativePath -split '/'
 $encodedSegments = foreach ($segment in $segments) {
  [System.Uri]::EscapeDataString($segment)
 }
 return ($base + '/' + ($encodedSegments -join '/'))
}

function Test-IsExcludedPath([string]$RelativePath) {
 $path = $RelativePath -replace '\\', '/'

 $excludedPrefixes = @(
  '.git/',
  '.github/'
 )

 foreach ($prefix in $excludedPrefixes) {
  if ($path.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
   return $true
  }
 }

 $excludedFragments = @(
  '/.git/',
  '/.github/'
 )

 foreach ($fragment in $excludedFragments) {
  if ($path.IndexOf($fragment, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
   return $true
  }
 }

 return $false
}

if (-not (Test-Path $Repo)) {
 throw ('No existe el repo Toolset: {0}' -f $Repo)
}

$Repo = [System.IO.Path]::GetFullPath($Repo)
$OutputRelativePath = $OutputRelativePath -replace '\\', '/'
$OutputFile = Join-Path $Repo ($OutputRelativePath -replace '/', [System.IO.Path]::DirectorySeparatorChar)
$OutputDir = Split-Path -Parent $OutputFile

if (-not (Test-Path $OutputDir)) {
 [void](New-Item -ItemType Directory -Force -Path $OutputDir)
}

$files = Get-ChildItem -Path $Repo -File -Recurse -Force |
 ForEach-Object {
  $relativePath = ConvertTo-RelativePath -Root $Repo -FullName $_.FullName

  if (-not (Test-IsExcludedPath -RelativePath $relativePath)) {
   [PSCustomObject]@{
    RelativePath = $relativePath
    Url = ConvertTo-PublicUrl -BaseUrl $BaseUrl -RelativePath $relativePath
    SizeBytes = $_.Length
   }
  }
 } |
 Sort-Object RelativePath

# El indice tambien se publica, pero durante el escaneo puede no existir todavia.
$indexExistsInList = $false
foreach ($file in $files) {
 if ($file.RelativePath -eq $OutputRelativePath) {
  $indexExistsInList = $true
  break
 }
}

if (-not $indexExistsInList) {
 $files = @(
  [PSCustomObject]@{
   RelativePath = $OutputRelativePath
   Url = ConvertTo-PublicUrl -BaseUrl $BaseUrl -RelativePath $OutputRelativePath
   SizeBytes = 0
  }
 ) + $files
}

$generatedAt = Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz'

$content = New-Object System.Collections.Generic.List[string]
$content.Add('# Indice publico de archivos')
$content.Add('')
$content.Add('Generado automaticamente por `.localstorage/scripts/8_generate-public-file-index.ps1`.')
$content.Add('')
$content.Add(('Generado: {0}' -f $generatedAt))
$content.Add('')
$content.Add(('Base URL: {0}/' -f $BaseUrl.TrimEnd('/')))
$content.Add('')
$content.Add(('Total de archivos indexados: {0}' -f $files.Count))
$content.Add('')
$content.Add('## Uso recomendado')
$content.Add('')
$content.Add('Usar este archivo como mapa principal para encontrar la URL publica directa de cualquier archivo del proyecto.')
$content.Add('')
$content.Add('## Archivos')
$content.Add('')
$content.Add('| Archivo | URL |')
$content.Add('|---|---|')

foreach ($file in $files) {
 $safePath = $file.RelativePath.Replace('|', '\|')
 $safeUrl = $file.Url.Replace('|', '%7C')
 $content.Add(('| `{0}` | {1} |' -f $safePath, $safeUrl))
}

$newContent = ($content -join "`r`n") + "`r`n"

$currentContent = $null
if (Test-Path $OutputFile) {
 $currentContent = Get-Content -Path $OutputFile -Raw -Encoding UTF8
}

if ($currentContent -ne $newContent) {
 Set-Content -Path $OutputFile -Value $newContent -Encoding UTF8
 Write-IndexLog ('REGENERADO {0}' -f $OutputFile) 'Green'
 Write-IndexLog ('Archivos indexados: {0}' -f $files.Count) 'Gray'
}
else {
 Write-IndexLog ('SIN CAMBIOS {0}' -f $OutputFile) 'Gray'
}
