@echo off
title GitHub Fast - Status
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0gh-fast.ps1" -Action status
echo.
pause
