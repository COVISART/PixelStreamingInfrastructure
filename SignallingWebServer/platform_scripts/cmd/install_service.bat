@Rem Copyright Epic Games, Inc. All Rights Reserved.
@echo off
setlocal

@Rem Convenience wrapper around install_service.ps1, so the installer can be run from
@Rem cmd.exe or double clicked. It asks for elevation when it does not already have it,
@Rem and bypasses the PowerShell execution policy for this one script.
@Rem
@Rem Arguments are forwarded, so all of these work:
@Rem     install_service.bat -OpenFirewall
@Rem     install_service.bat -Force -Rebuild
@Rem     install_service.bat -ServerArgs '--player_port','8080'
@Rem     install_service.bat -DisplayName 'Pixel Streaming'
@Rem     install_service.bat -StartTurn -TurnServer 192.168.1.50:19303 -PublicIp 203.0.113.7
@Rem Quote values with single quotes, not double quotes: cmd.exe hands double quotes to
@Rem PowerShell in a form it re-parses. As with the other scripts here, values containing
@Rem ^ or ! do not survive cmd.exe either. Run install_service.ps1 directly from an
@Rem Administrator PowerShell prompt if that gets in the way.

set "PS_SCRIPT=%~dp0install_service.ps1"
set "PSI_SERVICE_ARGS=%*"

@Rem Two probes, because net session needs the Server service, which is switched off on
@Rem some hardened machines, and fltmc is not present on every SKU.
set "IS_ADMIN="
net session >nul 2>&1
if not errorlevel 1 set "IS_ADMIN=1"
if not defined IS_ADMIN (
    fltmc >nul 2>&1
    if not errorlevel 1 set "IS_ADMIN=1"
)
if defined IS_ADMIN goto :Elevated

echo Administrator rights are required to install a service.
echo Accept the User Account Control prompt to continue.
@Rem Relaunches this same script elevated. cmd /k keeps that window open afterwards so
@Rem the output stays readable.
powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath 'cmd.exe' -Verb RunAs -ArgumentList ('/k \"%~f0\" ' + $env:PSI_SERVICE_ARGS)"
if errorlevel 1 (
    echo.
    echo Elevation was declined. Run this script again from an Administrator command
    echo prompt, or right click it and choose "Run as administrator".
    exit /b 1
)
echo.
echo Setup is running in the new Administrator window.
exit /b 0

:Elevated
@Rem -Command rather than -File so that PowerShell parses the arguments itself and list
@Rem parameters such as -ServerArgs arrive as a list rather than as one string.
powershell -NoProfile -ExecutionPolicy Bypass -Command "& \"%PS_SCRIPT%\" %*"
exit /b %errorlevel%
