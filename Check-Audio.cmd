@echo off
rem Double-click quick check: is this PC suitable for real-time audio? Read-only, no administrator rights needed.
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0RTAudio.ps1" -QuickCheck %*
