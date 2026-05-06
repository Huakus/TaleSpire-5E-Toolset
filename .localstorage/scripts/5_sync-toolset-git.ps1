<#
.SYNOPSIS
  Mantiene sincronizado el repo Toolset por Git.

.DESCRIPTION
  Responsabilidad unica:
    - Preparar/verificar el repo local del Toolset.
    - Hacer una sincronizacion inicial.
    - Sincronizar periodicamente mientras no exista la senal de stop.
    - Hacer una sincronizacion final antes de salir.

  Este script NO abre TaleSpire y NO espera el cierre del juego.

.PARAMETER StopSignalFile
  Archivo usado como senal para finalizar el loop.

.PARAMETER NoPauseOnError
  Si esta activo, el script NO espera una tecla antes de salir cuando ocurre un error fatal.
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$StopSignalFile,

    [switch]$NoPauseOnError
)

# Continua aunque un comando no critico falle.
# Los comandos Git se validan con logs/exit codes cuando realmente importa.
$ErrorActionPreference = 'Continue'

# ============================================================
# Configuracion principal
# ============================================================

# Carpeta local donde TaleSpire guarda el Symbiote Toolset.
$Repo = Join-Path $env:USERPROFILE 'AppData\LocalLow\BouncyRock Entertainment\TaleSpire\Symbiotes\Toolset'

# Repositorio remoto usado para sincronizar el Toolset.
$Remote = 'https://github.com/Huakus/TaleSpire-5E-Toolset'

# Rama principal del repo.
$Branch = 'main'

# Intervalo entre sincronizaciones mientras TaleSpire esta abierto.
$Interval = 10

# Se usa para imprimir puntos de espera en una misma linea cuando no hay cambios.
$script:lastInline = $false

# ============================================================
# Deteccion de Git
# ============================================================

function Resolve-GitPath {
    <#
      Busca git.exe en ubicaciones comunes de Windows.
      Si no lo encuentra, devuelve 'git' esperando que este disponible en PATH.
    #>

    $candidates = @(
        "$env:ProgramFiles\Git\cmd\git.exe",
        "${env:ProgramFiles(x86)}\Git\cmd\git.exe",
        "$env:LOCALAPPDATA\Programs\Git\cmd\git.exe"
    )

    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path $candidate)) {
            return $candidate
        }
    }

    return 'git'
}

$Git = Resolve-GitPath

# ============================================================
# Helpers de log
# ============================================================

function Write-Log([string]$Message, [switch]$Inline) {
    <#
      Log principal.
      - Normal: imprime una linea completa.
      - Inline: imprime sin salto, usado para mostrar actividad sin llenar la consola.
    #>

    if ($Inline) {
        Write-Host -NoNewline $Message
        $script:lastInline = $true
    }
    else {
        if ($script:lastInline) {
            Write-Host ''
            $script:lastInline = $false
        }
        Write-Host $Message
    }
}

function Write-Detail([string]$Message, [string]$Color = 'White') {
    <#
      Log indentado para detalles:
      archivos locales modificados, commits remotos y resumen de diff.
    #>

    if ($script:lastInline) {
        Write-Host ''
        $script:lastInline = $false
    }

    Write-Host ('  {0}' -f $Message) -ForegroundColor $Color
}

function Get-DiffColor([string]$Message) {
    <#
      Color simple para lineas de diff:
      - Verde: inserciones/agregados
      - Rojo: eliminaciones
      - Gris: neutro
    #>

    if ($Message -match 'insertion') { return 'Green' }
    if ($Message -match 'deletion') { return 'Red' }
    if ($Message -match '\+') { return 'Green' }
    if ($Message -match '\-') { return 'Red' }

    return 'Gray'
}

function Wait-BeforeExitOnError {
    <#
      Pausa opcional para errores fatales.
      Sirve cuando el .ps1 se ejecuta directo, por fuera del .cmd.
    #>

    if (-not $NoPauseOnError) {
        Write-Host ''
        Write-Host 'Presiona una tecla para cerrar esta ventana...'
        [void][System.Console]::ReadKey($true)
    }
}

# ============================================================
# Preparacion del repositorio local
# ============================================================

function Ensure-Repo([string]$Repo, [string]$Remote, [string]$Branch) {
    <#
      Prepara la carpeta local del Toolset:
        1. Crea la carpeta si no existe.
        2. Inicializa Git si todavia no hay .git.
        3. Configura origin con el remoto correcto.
        4. Hace fetch.
        5. Se asegura de estar en la rama configurada.
    #>

    if (-not (Test-Path $Repo)) {
        [void](New-Item -ItemType Directory -Force -Path $Repo)
    }

    if (Test-Path (Join-Path $Repo '.git')) {
        Write-Log ('Verificando Toolset en rama {0}' -f $Branch)
    }
    else {
        Write-Log ('Inicializando Toolset en {0}' -f $Repo)
        & $Git -C $Repo init > $null 2>&1
    }

    $origin = (& $Git -C $Repo remote get-url origin 2>$null)

    if (-not $origin) {
        & $Git -C $Repo remote add origin $Remote > $null 2>&1
    }
    elseif ($origin -ne $Remote) {
        & $Git -C $Repo remote set-url origin $Remote > $null 2>&1
    }

    & $Git -C $Repo fetch origin > $null 2>&1

    $localBranch = (& $Git -C $Repo rev-parse --abbrev-ref HEAD 2>$null)

    if ($localBranch -ne $Branch) {
        & $Git -C $Repo checkout $Branch > $null 2>&1

        if ($LASTEXITCODE -ne 0) {
            & $Git -C $Repo checkout -b $Branch > $null 2>&1
        }
    }
}

# ============================================================
# Sincronizacion Git del Toolset
# ============================================================

function Sync-Toolset([string]$Repo, [string]$Branch) {
    <#
      Ejecuta una sincronizacion completa:
        1. Verifica que la carpeta sea repo Git.
        2. Detecta cambios remotos antes del pull.
        3. Agrega y commitea cambios locales si existen.
        4. Hace pull --rebase --autostash.
        5. Hace push al remoto.
        6. Muestra logs utiles solo cuando hubo cambios.

      Si no paso nada, imprime un punto inline para indicar que sigue vivo.
    #>

    if (-not (Test-Path (Join-Path $Repo '.git'))) {
        Write-Detail ('No es repo Git: {0}' -f $Repo) 'Red'
        return
    }

    $headBefore = (& $Git -C $Repo rev-parse HEAD 2>$null)

    # Trae informacion remota sin modificar todavia el working tree.
    & $Git -C $Repo fetch origin > $null 2>&1

    $remoteAhead = 0
    $remoteLog = @()
    $remoteDiff = @()

    try {
        $remoteAhead = [int](& $Git -C $Repo rev-list --count HEAD..origin/$Branch 2>$null)

        if ($remoteAhead -gt 0) {
            $remoteLog = & $Git -C $Repo log --oneline --max-count $remoteAhead HEAD..origin/$Branch
            $remoteDiff = (& $Git -C $Repo diff --stat HEAD..origin/$Branch) -split "`n"
        }
    }
    catch {
        # Si falla esta inspeccion, el pull posterior sigue intentando sincronizar.
    }

    # Stagea todo lo local, incluyendo altas/bajas/modificaciones.
    & $Git -C $Repo add -A > $null 2>&1

    $dirty = & $Git -C $Repo status --porcelain
    $dirtyLog = @()
    $dirtyDiff = @()

    if ($dirty) {
        $dirtyLog = $dirty -split "`n"
        $dirtyDiff = (& $Git -C $Repo diff --cached --stat) -split "`n"

        & $Git -C $Repo commit --quiet -m ('auto: ' + (Get-Date -Format o))
    }

    # Rebase para evitar merges automaticos innecesarios.
    # Autostash cubre cambios locales que aparezcan entre pasos.
    & $Git -C $Repo pull --rebase --autostash origin $Branch > $null 2>&1

    # Publica los cambios locales en origin/main.
    & $Git -C $Repo push -u origin $Branch > $null 2>&1

    $headAfter = (& $Git -C $Repo rev-parse HEAD 2>$null)
    $received = $remoteAhead -gt 0

    if ($dirty -or $received -or ($headAfter -ne $headBefore)) {
        if ($dirty) {
            Write-Log 'ENVIANDO Toolset'

            foreach ($line in $dirtyLog) {
                if ($line) { Write-Detail ('local: {0}' -f $line) 'Yellow' }
            }

            foreach ($line in $dirtyDiff) {
                if ($line) { Write-Detail ('diff: {0}' -f $line) (Get-DiffColor $line) }
            }
        }

        if ($received) {
            Write-Log 'RECIBIENDO Toolset'

            foreach ($line in $remoteLog) {
                if ($line) { Write-Detail ('remoto: {0}' -f $line) 'Cyan' }
            }

            foreach ($line in $remoteDiff) {
                if ($line) { Write-Detail ('diff: {0}' -f $line) (Get-DiffColor $line) }
            }
        }

        if ((-not $dirty) -and (-not $received)) {
            Write-Log 'Toolset actualizado'
            Write-Detail 'cambios aplicados'
        }
    }
    else {
        Write-Log '.' -Inline
    }
}

# ============================================================
# Flujo principal
# ============================================================

try {
    Write-Log 'Sincronizando Toolset...'

    Ensure-Repo -Repo $Repo -Remote $Remote -Branch $Branch

    # Sync inicial. Arranca antes o en paralelo al lanzamiento de TaleSpire.
    Sync-Toolset -Repo $Repo -Branch $Branch

    Write-Log 'Worker de sync activo. Esperando senal de stop...'

    # Loop de sync independiente. Termina cuando otro script crea StopSignalFile.
    while (-not (Test-Path $StopSignalFile)) {
        Start-Sleep -Seconds $Interval
        Sync-Toolset -Repo $Repo -Branch $Branch
    }

    # Sync final antes de salir.
    Write-Log 'Senal de stop recibida. Ejecutando sync final...'
    Sync-Toolset -Repo $Repo -Branch $Branch

    Write-Log ('OK: Sync Toolset finalizado correctamente en rama {0}.' -f $Branch)
    exit 0
}
catch {
    Write-Log ('ERROR: {0}' -f $_.Exception.Message)
    Wait-BeforeExitOnError
    exit 1
}
