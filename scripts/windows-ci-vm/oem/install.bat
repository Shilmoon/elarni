@echo off
rem dockur/windows runs this once at the end of the unattended install.
powershell -NoProfile -ExecutionPolicy Bypass -File C:\OEM\install.ps1 > C:\OEM\install.log 2>&1
