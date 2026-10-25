@echo off
title github-fast install
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0gh-fast.ps1" -Action install
echo.
pause
