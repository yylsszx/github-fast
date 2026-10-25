@echo off
title GitHub Fast - Off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0gh-fast.ps1" -Action off
echo.
pause
