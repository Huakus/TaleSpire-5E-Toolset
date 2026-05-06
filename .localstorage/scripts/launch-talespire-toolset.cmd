@echo off
setlocal EnableExtensions DisableDelayedExpansion

rem ============================================================
rem  launch-talespire-toolset.cmd
rem  ------------------------------------------------------------
rem  Launcher principal para TaleSpire + Toolset.
rem
rem  Este archivo queda liviano a proposito:
rem    - Ubica run-talespire-toolset.ps1 dentro de esta misma carpeta.
rem    - Ejecuta PowerShell con ExecutionPolicy Bypass solo para este run.
rem    - Mantiene la ventana abierta si algo falla.
rem
rem  Estructura esperada:
rem    scripts\launch-talespire-toolset.cmd
rem    scripts\run-talespire-toolset.ps1
rem    scripts\sync-toolset-git.ps1
rem    scripts\export-character-sheets.ps1
rem    scripts\start-talespire.ps1
rem    scripts\wait-talespire-close.ps1
rem ============================================================

set "SCRIPT_DIR=%~dp0"
set "MAIN_SCRIPT=%SCRIPT_DIR%run-talespire-toolset.ps1"

if not exist "%MAIN_SCRIPT%" (
  echo ERROR: No se encontro el script PowerShell principal:
  echo "%MAIN_SCRIPT%"
  echo.
  echo Verifica que launch-talespire-toolset.cmd y run-talespire-toolset.ps1 esten en la misma carpeta.
  echo Presiona una tecla para cerrar esta ventana...
  pause >nul
  exit /b 1
)

echo Ejecutando run-talespire-toolset.ps1...
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%MAIN_SCRIPT%" -NoPauseOnError
set "EXITCODE=%ERRORLEVEL%"

if not "%EXITCODE%"=="0" (
  echo.
  echo ERROR: run-talespire-toolset.ps1 termino con codigo %EXITCODE%.
  echo Presiona una tecla para cerrar esta ventana...
  pause >nul
)

exit /b %EXITCODE%
