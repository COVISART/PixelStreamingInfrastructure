# Copyright Epic Games, Inc. All Rights Reserved.
#Requires -Version 5.1

<#
.SYNOPSIS
    Stops and removes the Pixel Streaming signalling server Windows service installed by
    install_service.ps1.

.DESCRIPTION
    Removes the service from the Service Control Manager. Build output, config.json and
    the server's own logs are left alone, so the server can still be started by hand with
    start.bat afterwards.

.PARAMETER ServiceName
    Service id to remove. Must match the -ServiceName used at install time.

.PARAMETER TurnServiceName
    TURN service id to remove, if install_service.ps1 -StartTurn was used. Ignored when
    no such service exists.

.PARAMETER RemoveFirewallRules
    Also delete the inbound firewall rules in the "Pixel Streaming" group that
    install_service.ps1 -OpenFirewall created. Off by default, because other things on
    this machine may rely on those ports being open.

.PARAMETER Purge
    Also delete the service directory, including the downloaded wrapper and the service
    log files.

.EXAMPLE
    .\uninstall_service.ps1

.EXAMPLE
    .\uninstall_service.ps1 -RemoveFirewallRules -Purge
#>

[CmdletBinding()]
param(
    [ValidatePattern('^[A-Za-z0-9_.-]+$')]
    [string] $ServiceName = 'PixelStreamingSignalling',

    [ValidatePattern('^[A-Za-z0-9_.-]+$')]
    [string] $TurnServiceName = 'PixelStreamingTurn',

    [switch] $RemoveFirewallRules,
    [switch] $Purge
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

function Write-Step([string] $Message) {
    Write-Host ''
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Write-Note([string] $Message) {
    Write-Host "    $Message"
}

function Write-Warn([string] $Message) {
    Write-Host "    WARNING: $Message" -ForegroundColor Yellow
}

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Removing a Windows service requires elevation. Re-run this from an Administrator PowerShell prompt, or run uninstall_service.bat which asks for elevation itself.'
}

$scriptDir = $PSScriptRoot
$serviceDir = Join-Path $scriptDir 'service'
$serviceXml = Join-Path $serviceDir "$ServiceName.xml"

function Remove-WrappedService([string] $Id) {
    $wrapperExe = Join-Path $serviceDir "$Id.exe"
    $service = Get-Service -Name $Id -ErrorAction SilentlyContinue

    if (-not $service) {
        Write-Host ''
        Write-Host "No service named '$Id' is installed." -ForegroundColor Yellow
        return
    }

    if ($service.Status -ne 'Stopped') {
        Write-Step "Stopping $Id"
        Stop-Service -Name $Id -Force -ErrorAction SilentlyContinue
        try {
            $service.WaitForStatus('Stopped', [TimeSpan]::FromSeconds(30))
            Write-Note 'Stopped.'
        }
        catch {
            Write-Warn 'The service did not stop within 30 seconds, removing it anyway.'
        }
    }

    Write-Step "Removing $Id"
    if (Test-Path $wrapperExe) {
        & $wrapperExe 'uninstall'
        if ($LASTEXITCODE -ne 0) {
            Write-Warn "The wrapper reported exit code $LASTEXITCODE, falling back to sc.exe."
            & sc.exe delete $Id | Out-Null
        }
    }
    else {
        # The wrapper is gone, but the service registration can still be deleted.
        & sc.exe delete $Id | Out-Null
    }

    # The SCM only drops a service once every handle to it is closed, so a services.msc
    # window left open on this machine can delay the removal by a few seconds.
    $waited = 0
    while ((Get-Service -Name $Id -ErrorAction SilentlyContinue) -and $waited -lt 30) {
        Start-Sleep -Seconds 1
        $waited++
    }

    if (Get-Service -Name $Id -ErrorAction SilentlyContinue) {
        Write-Warn "The service is still registered, most likely because something holds a handle to it. Close services.msc, Event Viewer and Task Manager, then run this script again."
    }
    else {
        Write-Note 'Removed.'
    }
}

Remove-WrappedService -Id $ServiceName
Remove-WrappedService -Id $TurnServiceName

if ($RemoveFirewallRules) {
    Write-Step 'Removing the Pixel Streaming firewall rules'
    try {
        $rules = Get-NetFirewallRule -Group 'Pixel Streaming' -ErrorAction SilentlyContinue
        if ($rules) {
            foreach ($rule in $rules) {
                Write-Note "Removing '$($rule.DisplayName)'."
            }
            $rules | Remove-NetFirewallRule
        }
        else {
            Write-Note 'None found.'
        }
    }
    catch {
        Write-Warn "Could not remove the firewall rules: $($_.Exception.Message)"
    }
}

if ($Purge) {
    Write-Step 'Deleting the service directory'
    if (Test-Path $serviceDir) {
        try {
            Remove-Item -Path $serviceDir -Recurse -Force
            Write-Note "Deleted $serviceDir."
        }
        catch {
            # A file still mapped by a process that has not fully exited yet is the usual
            # reason this fails right after a removal.
            Write-Warn "Could not delete $serviceDir - $($_.Exception.Message). Try again in a few seconds."
        }
    }
    else {
        Write-Note 'Nothing to delete.'
    }
}
else {
    if (Test-Path $serviceXml) {
        Write-Note ''
        Write-Note "The wrapper and its logs are still in $serviceDir. Re-run with -Purge to delete them."
    }
}

Write-Host ''
Write-Host 'Done. The server itself is untouched and can still be started with start.bat.' -ForegroundColor Green
Write-Host ''
