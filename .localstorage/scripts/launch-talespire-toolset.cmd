@echo off
setlocal EnableExtensions EnableDelayedExpansion

rem ============================================================
rem  launch-talespire-toolset.cmd
rem  ------------------------------------------------------------
rem  Entry point principal desde Windows.
rem
rem  Responsabilidad:
rem    - Buscar el orquestador PowerShell en esta misma carpeta.
rem    - Ejecutarlo.
rem    - Si algo falla, dejar la ventana abierta para leer el error.
rem
rem  Estructura esperada:
rem    scripts\launch-talespire-toolset.cmd
rem    scripts\run-talespire-toolset.ps1
rem    scripts\start-talespire.ps1
rem    scripts\sync-toolset-git.ps1
rem    scripts\wait-talespire-close.ps1
rem ============================================================

rem Carpeta donde esta este .cmd.
set "SCRIPT_DIR=%~dp0"

rem Orquestador principal. No es un worker: solo coordina los scripts separados.
set "ORCHESTRATOR_SCRIPT_FILE=run-talespire-toolset.ps1"
set "ORCHESTRATOR_SCRIPT_PATH=%SCRIPT_DIR%%ORCHESTRATOR_SCRIPT_FILE%"

if not exist "%ORCHESTRATOR_SCRIPT_PATH%" (
  echo ERROR: No se encontro el orquestador PowerShell:
  echo "%ORCHESTRATOR_SCRIPT_PATH%"
  echo.
  echo Verifica que el archivo exista dentro de la misma carpeta que este .cmd.
  echo.
  echo Presiona una tecla para cerrar esta ventana...
  pause >nul
  exit /b 1
)

echo Ejecutando %ORCHESTRATOR_SCRIPT_FILE%...

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%ORCHESTRATOR_SCRIPT_PATH%" -NoPauseOnError
set "EXITCODE=%ERRORLEVEL%"

if not "%EXITCODE%"=="0" (
  echo.
  echo ERROR: %ORCHESTRATOR_SCRIPT_FILE% termino con codigo %EXITCODE%.
  echo Presiona una tecla para cerrar esta ventana...
  pause >nul
  exit /b %EXITCODE%
)

exit /b 0
