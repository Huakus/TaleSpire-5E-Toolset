@echo off
setlocal EnableExtensions DisableDelayedExpansion

rem ============================================================
rem  1_toolset-launcher.cmd
rem  ------------------------------------------------------------
rem  Launcher principal para TaleSpire + Toolset.
rem
rem  Este archivo queda liviano a proposito:
rem    - Ubica 2_orquestrator.ps1 dentro de esta misma carpeta.
rem    - Ejecuta PowerShell con ExecutionPolicy Bypass solo para este run.
rem    - Mantiene la ventana abierta si algo falla.
rem
rem  Estructura esperada:
rem    scripts\1_toolset-launcher.cmd
rem    scripts\2_orquestrator.ps1
rem    scripts\5_sync-toolset-git.ps1
rem    scripts\4_export-character-sheets.ps1
rem    scripts\3_start-talespire.ps1
rem    scripts\6_wait-talespire-close.ps1
rem ============================================================

set "SCRIPT_DIR=%~dp0"
set "MAIN_SCRIPT=%SCRIPT_DIR%2_orquestrator.ps1"

if not exist "%MAIN_SCRIPT%" (
  echo ERROR: No se encontro el script PowerShell principal:
  echo "%MAIN_SCRIPT%"
  echo.
  echo Verifica que 1_toolset-launcher.cmd y 2_orquestrator.ps1 esten en la misma carpeta.
  echo Presiona una tecla para cerrar esta ventana...
  pause >nul
  exit /b 1
)

echo Ejecutando 2_orquestrator.ps1...
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%MAIN_SCRIPT%" -NoPauseOnError
set "EXITCODE=%ERRORLEVEL%"

if not "%EXITCODE%"=="0" (
  echo.
  echo ERROR: 2_orquestrator.ps1 termino con codigo %EXITCODE%.
  echo Presiona una tecla para cerrar esta ventana...
  pause >nul
)

exit /b %EXITCODE%
