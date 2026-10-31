@echo off
rem Double-click launcher: starts the GUI (asks for administrator rights via UAC).
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0RTAudio.ps1" %*
