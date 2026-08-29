@Rem Copyright Epic Games, Inc. All Rights Reserved.
@echo off
setlocal

@Rem Convenience wrapper around uninstall_service.ps1. See install_service.bat for what
@Rem this adds: elevation, and an execution policy bypass for the one script.
@Rem
@Rem Arguments are forwarded, so these work:
@Rem     uninstall_service.bat -Purge
@Rem     uninstall_service.bat -RemoveFirewallRules
@Rem     uninstall_service.bat -ServiceName PixelStreamingSignalling2

set "PS_SCRIPT=%~dp0uninstall_service.ps1"
set "PSI_SERVICE_ARGS=%*"

set "IS_ADMIN="
net session >nul 2>&1
if not errorlevel 1 set "IS_ADMIN=1"
if not defined IS_ADMIN (
    fltmc >nul 2>&1
    if not errorlevel 1 set "IS_ADMIN=1"
)
if defined IS_ADMIN goto :Elevated

echo Administrator rights are required to remove a service.
echo Accept the User Account Control prompt to continue.
powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath 'cmd.exe' -Verb RunAs -ArgumentList ('/k \"%~f0\" ' + $env:PSI_SERVICE_ARGS)"
if errorlevel 1 (
    echo.
    echo Elevation was declined. Run this script again from an Administrator command
    echo prompt, or right click it and choose "Run as administrator".
    exit /b 1
)
echo.
echo Removal is running in the new Administrator window.
exit /b 0

:Elevated
powershell -NoProfile -ExecutionPolicy Bypass -Command "& \"%PS_SCRIPT%\" %*"
exit /b %errorlevel%
