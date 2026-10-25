@echo off
title github-fast uninstall
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0gh-fast.ps1" -Action uninstall
echo.
pause
