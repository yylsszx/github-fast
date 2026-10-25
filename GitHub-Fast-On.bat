@echo off
title GitHub Fast
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0gh-fast.ps1" -Action on
echo.
pause
