@echo off
setlocal EnableExtensions DisableDelayedExpansion

rem === Config ===
set "REPO1=%USERPROFILE%\AppData\LocalLow\BouncyRock Entertainment\TaleSpire\Symbiotes\Toolset"
set "REMOTE1=https://github.com/Huakus/TaleSpire-5E-Toolset"

set "INTERVAL=10"
set "BRANCH=main"

set "GIT=%ProgramFiles%\Git\cmd\git.exe"
if not exist "%GIT%" set "GIT=%ProgramFiles(x86)%\Git\cmd\git.exe"
if not exist "%GIT%" set "GIT=%LOCALAPPDATA%\Programs\Git\cmd\git.exe"
if not exist "%GIT%" set "GIT=git"

set "PSFILE=%TEMP%\talespire-sync.ps1"

break > "%PSFILE%"

>>"%PSFILE%" echo $ErrorActionPreference = 'Continue'
>>"%PSFILE%" echo $Git = "%GIT%"
>>"%PSFILE%" echo $Repo1 = "%REPO1%"
>>"%PSFILE%" echo $Remote1 = "%REMOTE1%"
>>"%PSFILE%" echo $Interval = %INTERVAL%
>>"%PSFILE%" echo $Branch = 'main'
>>"%PSFILE%" echo $Proc = 'TaleSpire'
>>"%PSFILE%" echo $script:lastInline = $false
>>"%PSFILE%" echo(

>>"%PSFILE%" echo function Write-Log([string]^$Message,[switch]^$Inline){
>>"%PSFILE%" echo ^    if(^$Inline){
>>"%PSFILE%" echo ^        Write-Host -NoNewline ^$Message
>>"%PSFILE%" echo ^        ^$script:lastInline = ^$true
>>"%PSFILE%" echo ^    } else {
>>"%PSFILE%" echo ^        if(^$script:lastInline){ Write-Host '' }
>>"%PSFILE%" echo ^        Write-Host ^$Message
>>"%PSFILE%" echo ^        ^$script:lastInline = ^$false
>>"%PSFILE%" echo ^    }
>>"%PSFILE%" echo }
>>"%PSFILE%" echo(
>>"%PSFILE%" echo function Get-DiffColor([string]^$Message){
>>"%PSFILE%" echo ^    if(^$Message -match 'insertion') { return 'Green' }
>>"%PSFILE%" echo ^    if(^$Message -match 'deletion') { return 'Red' }
>>"
