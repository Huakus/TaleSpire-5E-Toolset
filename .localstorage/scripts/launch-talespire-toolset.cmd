@echo off
setlocal EnableExtensions EnableDelayedExpansion

rem ============================================================
rem  launch-talespire-toolset.cmd
rem  ------------------------------------------------------------
rem  Launcher principal para TaleSpire + Toolset.
rem
rem  Este archivo queda liviano a proposito:
rem    - Define explicitamente que scripts PowerShell debe ejecutar.
rem    - Busca esos .ps1 en la misma carpeta donde esta este .cmd.
rem    - Ejecuta PowerShell con ExecutionPolicy Bypass solo para este run.
rem    - Si algo falla, deja la ventana abierta para poder leer el error.
rem
rem  Estructura esperada:
rem    scripts\launch-talespire-toolset.cmd
rem    scripts\sync-toolset-git.ps1
rem
rem  Para agregar mas funcionalidades en el futuro:
rem    1. Crear el nuevo .ps1 dentro de scripts\
rem    2. Agregar el nombre del archivo en POWERSHELL_SCRIPT_FILES
rem
rem  Convencion recomendada:
rem    Los .ps1 llamados desde este launcher deberian aceptar:
rem      -NoPauseOnError
rem    Asi la pausa ante errores queda centralizada en este .cmd.
rem ============================================================

rem Carpeta donde esta este .cmd. Esto permite llamarlo desde cualquier
rem ubicacion o desde un acceso directo sin depender del working directory.
set "SCRIPT_DIR=%~dp0"

rem Lista explicita de scripts PowerShell a ejecutar, en orden.
rem Hoy hay uno solo, pero queda preparado para sumar mas .ps1 a futuro.
set "POWERSHELL_SCRIPT_FILES=sync-toolset-git.ps1"

rem Exit code acumulado. Si algun script falla, se corta la ejecucion.
set "EXITCODE=0"

for %%F in (%POWERSHELL_SCRIPT_FILES%) do (
  set "POWERSHELL_SCRIPT_PATH=%SCRIPT_DIR%%%~F"

  rem Validacion simple para evitar una falla silenciosa si se mueve/borra el .ps1.
  if not exist "!POWERSHELL_SCRIPT_PATH!" (
    echo ERROR: No se encontro el script PowerShell:
    echo "!POWERSHELL_SCRIPT_PATH!"
    echo.
    echo Verifica que el archivo exista dentro de la misma carpeta que este .cmd.
    echo.
    echo Presiona una tecla para cerrar esta ventana...
    pause >nul
    exit /b 1
  )

  echo Ejecutando %%~F...

  rem Ejecuta la logica real en PowerShell.
  rem -NoProfile evita cargar configuraciones personales que puedan alterar el comportamiento.
  rem -ExecutionPolicy Bypass aplica solo a esta ejecucion.
  rem -NoPauseOnError evita doble pausa: si falla, pausa este .cmd.
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "!POWERSHELL_SCRIPT_PATH!" -NoPauseOnError
  set "EXITCODE=!ERRORLEVEL!"

  rem Si PowerShell devolvio error, mantener la ventana abierta.
  rem Esto permite leer el mensaje en vez de que el acceso directo se cierre de golpe.
  if not "!EXITCODE!"=="0" (
    echo.
    echo ERROR: %%~F termino con codigo !EXITCODE!.
    echo Presiona una tecla para cerrar esta ventana...
    pause >nul
    exit /b !EXITCODE!
  )
)

exit /b %EXITCODE%
