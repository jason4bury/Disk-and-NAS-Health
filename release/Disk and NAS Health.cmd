@echo off
rem Disk and NAS Health - double-click to start it.
rem Each time, this makes (or refreshes) the Disk and NAS Health shortcut in this folder and in the Start menu,
rem then starts Disk and NAS Health from it. After the first run you can use the shortcut, the Start menu or
rem a pinned taskbar button instead: they start Disk and NAS Health without a console window.
rem The execution-policy bypass applies to Disk and NAS Health's own run only; no Windows settings are changed.
rem If Disk and NAS Health doesn't open, run   "Disk and NAS Health.cmd" debug   to start it in this window and see any errors.
setlocal
set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if /i "%~1"=="debug" (
    "%PS%" -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0Disk-and-NAS-Health.ps1"
    pause
    exit /b
)
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0New-DiskNASHealthShortcut.ps1" -Launch
if errorlevel 1 pause
