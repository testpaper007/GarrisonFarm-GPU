@echo off
chcp 65001 >nul
cd /d "%~dp0"
title GarrisonFarm GPU Patch - Install
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "$s=[IO.File]::ReadAllText('gf_gpu.ps1',[Text.Encoding]::UTF8); & ([scriptblock]::Create($s)) install '%~1'"
echo.
pause
