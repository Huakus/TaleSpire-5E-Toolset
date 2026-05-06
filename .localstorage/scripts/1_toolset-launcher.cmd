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
rem ============================================================

set "SCRIPT_DIR=%~dp0"
set "MAIN_SCRIPT=%SCRIPT_DIR%2_orquestrator.ps1"
set "SCRIPT_NUMBER=%~n0"

for /f "tokens=1 delims=_-" %%A in ("%SCRIPT_NUMBER%") do set "SCRIPT_NUMBER=%%A"
echo %SCRIPT_NUMBER%| findstr /r "^[0-9][0-9]*$" >nul
if errorlevel 1 set "SCRIPT_NUMBER=?"
set "LOG_PREFIX=[%SCRIPT_NUMBER%]"

if not exist "%MAIN_SCRIPT%" (
  echo %LOG_PREFIX% ERROR: No se encontro el script PowerShell principal:
  echo %LOG_PREFIX% "%MAIN_SCRIPT%"
  echo.
  echo %LOG_PREFIX% Verifica que 1_toolset-launcher.cmd y 2_orquestrator.ps1 esten en la misma carpeta.
  echo %LOG_PREFIX% Presiona una tecla para cerrar esta ventana...
  pause >nul
  exit /b 1
)

echo %LOG_PREFIX% Ejecutando 2_orquestrator.ps1...
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%MAIN_SCRIPT%" -NoPauseOnError
set "EXITCODE=%ERRORLEVEL%"

if not "%EXITCODE%"=="0" (
  echo.
  echo %LOG_PREFIX% ERROR: 2_orquestrator.ps1 termino con codigo %EXITCODE%.
  echo %LOG_PREFIX% Presiona una tecla para cerrar esta ventana...
  pause >nul
)

exit /b %EXITCODE%
