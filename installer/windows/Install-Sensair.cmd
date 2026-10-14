@echo off
rem Sensair installer for Windows: double-click to install the firmware on an ESP32-C3
rem and connect it to your WiFi. Options are passed on, e.g. Install-Sensair.cmd -Port COM5
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0install-sensair.ps1" -PauseAtEnd %*
