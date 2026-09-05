@echo off
rem ActRunner launcher: double-click to open the window without a console
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0ActRunner.ps1"
