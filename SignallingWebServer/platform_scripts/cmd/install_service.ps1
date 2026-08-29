# Copyright Epic Games, Inc. All Rights Reserved.
#Requires -Version 5.1

<#
.SYNOPSIS
    Sets up the Pixel Streaming signalling server (Wilbur), and optionally a TURN server,
    as Windows services that start automatically when the machine boots.

.DESCRIPTION
    Node is not a service binary, so it cannot be handed to sc.exe directly - a service
    host has to own the process. This script uses WinSW (https://github.com/winsw/winsw),
    a single self-contained executable that the Service Control Manager starts, and which
    in turn runs "node dist\index.js". WinSW is downloaded on first run and checked
    against a pinned SHA-256.

    Everything the services need at runtime is written to a "service" directory beside
    this script, alongside the downloaded node and coturn directories, and that path is
    already covered by the repository's .gitignore.

    The signalling server reads SignallingWebServer\config.json exactly as it does when
    launched by start.bat, so ports, http_root and TLS are configured there. Anything
    passed to -ServerArgs is appended to the service command line and takes precedence.

    This is the service equivalent of start.bat, and the TURN options below mirror its
    flags. Two deliberate differences:

    - ICE configuration is written to a file and passed with --peer_options_file rather
      than as JSON on the command line, which is what the server itself recommends and
      what stops cmd.exe from mangling the credentials.
    - start.bat looks up the public IP from api.ipify.org when -PublicIp is not given.
      A service baking in whatever that returned at install time would go stale, so this
      script uses the machine's own address instead and says so.

.PARAMETER ServiceName
    Service id, used for the service itself and for the names of the generated files.

.PARAMETER DisplayName
    Name shown in services.msc.

.PARAMETER Description
    Description shown in services.msc.

.PARAMETER ServerArgs
    Extra arguments appended to the signalling server command line, for example
    -ServerArgs '--player_port','8080','--rest_api'. Run "node dist\index.js --help"
    from the SignallingWebServer directory for the full list.

.PARAMETER ConfigFile
    Config file for the service to use instead of SignallingWebServer\config.json, so the
    service does not have to share its settings with interactive start.bat runs.

.PARAMETER StunServer
    STUN server given to players, as host:port. Matches --stun in start.bat. Only sent
    when TURN is configured or this is passed explicitly; pass an empty string to leave
    STUN out.

.PARAMETER TurnServer
    TURN server given to players, as host:port. Matches --turn in start.bat. Note that
    this is the address players connect to, so it has to be reachable from wherever they
    are - 127.0.0.1 only works for a browser on this machine.

.PARAMETER TurnUser
    Username for the TURN server. Matches --turn-user in start.bat.

.PARAMETER TurnPass
    Password for the TURN server. Matches --turn-pass in start.bat.

.PARAMETER StartTurn
    Also install the bundled coturn as its own Windows service. Matches --start-turn in
    start.bat. The two services are independent, so either can be restarted alone.

.PARAMETER TurnServiceName
    Service id for the TURN server.

.PARAMETER PublicIp
    Address the TURN server advertises to peers as its relay address (coturn -X). Matches
    --publicip in start.bat. Defaults to this machine's own address.

.PARAMETER TurnLocalIp
    Address the TURN server listens and relays on (coturn -E, -L and --allowed-peer-ip).
    Defaults to the address the machine's hostname resolves to, which is what start.bat
    derives by pinging the computer name.

.PARAMETER ServiceAccount
    Built-in account the services log on as. LocalSystem (the default) can always write
    the log directories inside the repository; NetworkService and LocalService hold fewer
    privileges but need write access to those directories granted to them first.

.PARAMETER DelayedStart
    Start the services shortly after boot rather than during it. Worth using when TURN is
    bound to a specific address, because that adapter may not be ready when services
    first start.

.PARAMETER Rebuild
    Force a rebuild of the libraries, frontend and server even when build output exists.

.PARAMETER SkipBuild
    Do not run setup.bat or build anything, just install the services. Fails if the
    server has not been built.

.PARAMETER NoStart
    Install the services but leave them stopped. They still start at the next boot.

.PARAMETER OpenFirewall
    Add inbound Windows Firewall rules for the player, streamer and SFU ports, and for
    the TURN listening and relay ports when TURN is installed. Opening ports changes the
    machine's security configuration, so this is opt-in. The rules are tagged with the
    group "Pixel Streaming" so uninstall_service.ps1 can find them.

.PARAMETER WinswPath
    Use an existing WinSW executable instead of downloading one, for machines with no
    internet access.

.PARAMETER WinswVersion
    WinSW release to download. Changing this also requires -SkipHashCheck, because the
    pinned hashes only cover the default release.

.PARAMETER SkipHashCheck
    Skip SHA-256 verification of the downloaded WinSW executable.

.PARAMETER Force
    Replace existing services that have the same names.

.EXAMPLE
    .\install_service.ps1

    Builds whatever is missing and installs the signalling server using the ports in
    config.json.

.EXAMPLE
    .\install_service.ps1 -StartTurn -TurnServer 127.0.0.1:19303 -PublicIp 192.168.137.2

    The service equivalent of:
        start.bat --start-turn --turn 127.0.0.1:19303 --publicip 192.168.137.2

.EXAMPLE
    .\install_service.ps1 -ServerArgs '--player_port','8080' -OpenFirewall

    Serves the frontend on port 8080 and opens the firewall for the streaming ports.

.EXAMPLE
    .\install_service.ps1 -Force -Rebuild

    Rebuilds everything and reinstalls over existing services.
#>

[CmdletBinding()]
param(
    [ValidatePattern('^[A-Za-z0-9_.-]+$')]
    [string] $ServiceName = 'PixelStreamingSignalling',

    [string] $DisplayName = 'Pixel Streaming Signalling Server (Wilbur)',

    [string] $Description = 'Signalling and web server for Unreal Engine Pixel Streaming. Serves the player frontend and brokers WebRTC connections between streamers and players.',

    [string[]] $ServerArgs = @(),

    [string] $ConfigFile = '',

    [string] $StunServer = 'stun.l.google.com:19302',
    [string] $TurnServer = '',
    [string] $TurnUser = 'PixelStreamingUser',
    [string] $TurnPass = 'AnotherTURNintheroad',

    [switch] $StartTurn,

    [ValidatePattern('^[A-Za-z0-9_.-]+$')]
    [string] $TurnServiceName = 'PixelStreamingTurn',

    [string] $PublicIp = '',
    [string] $TurnLocalIp = '',

    [ValidateSet('LocalSystem', 'NetworkService', 'LocalService')]
    [string] $ServiceAccount = 'LocalSystem',

    [switch] $DelayedStart,
    [switch] $Rebuild,
    [switch] $SkipBuild,
    [switch] $NoStart,
    [switch] $OpenFirewall,

    [string] $WinswPath = '',
    [string] $WinswVersion = '2.12.0',
    [switch] $SkipHashCheck,

    [switch] $Force
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

# SHA-256 of the assets of the pinned WinSW release. A download that does not match is
# deleted rather than run.
$PinnedWinswVersion = '2.12.0'
$WinswHashes = @{
    'x64' = '05B82D46AD331CC16BDC00DE5C6332C1EF818DF8CEEFCD49C726553209B3A0DA'
    'x86' = '0C21327463A43A61F2EFB227EC4AFD2467FDE91618CC725148C1099001CA91AE'
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

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

function Assert-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Installing a Windows service requires elevation. Re-run this from an Administrator PowerShell prompt, or run install_service.bat which asks for elevation itself.'
    }
}

# Reads the value of a --option out of a command line fragment, supporting both
# "--option value" and "--option=value". Returns $null when the option is absent.
function Get-OptionValue([string[]] $Arguments, [string] $Name) {
    for ($i = 0; $i -lt $Arguments.Count; $i++) {
        if ($Arguments[$i] -eq "--$Name") {
            if ($i + 1 -lt $Arguments.Count) {
                return $Arguments[$i + 1]
            }
        }
        elseif ($Arguments[$i] -like "--$Name=*") {
            return $Arguments[$i].Substring($Name.Length + 3)
        }
    }
    return $null
}

# Precedence for a setting: -ServerArgs first, then the config file, then the server's
# own default. This mirrors how the server resolves its options.
function Resolve-Setting([string] $Name, $Config, $Default) {
    $fromArgs = Get-OptionValue -Arguments $ServerArgs -Name $Name
    if ($null -ne $fromArgs) { return $fromArgs }
    if ($null -ne $Config -and ($Config.PSObject.Properties.Name -contains $Name)) {
        $value = $Config.$Name
        if ($null -ne $value -and "$value" -ne '') { return $value }
    }
    return $Default
}

# Quotes one token for a Windows command line. The wrapper passes <arguments> to the
# process verbatim, so a path containing spaces has to be quoted here.
function Format-CommandLineArgument([string] $Value) {
    if ($Value -match '[\s"]') {
        return '"' + ($Value -replace '"', '\"') + '"'
    }
    return $Value
}

function Format-CommandLine([string[]] $Arguments) {
    return (($Arguments | ForEach-Object { Format-CommandLineArgument $_ }) -join ' ')
}

function Get-XmlText([string] $Value) {
    return [System.Security.SecurityElement]::Escape($Value)
}

function Test-TcpPort([string] $ComputerName, [int] $Port, [int] $TimeoutMs = 3000) {
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $async = $client.BeginConnect($ComputerName, $Port, $null, $null)
        if (-not $async.AsyncWaitHandle.WaitOne($TimeoutMs, $false)) { return $false }
        $client.EndConnect($async)
        return $true
    }
    catch {
        return $false
    }
    finally {
        $client.Close()
    }
}

function Show-ServiceLogTail([string] $LogDirectory, [string] $Id) {
    foreach ($suffix in @('err', 'out', 'wrapper')) {
        $logFile = Join-Path $LogDirectory "$Id.$suffix.log"
        if ((Test-Path $logFile) -and (Get-Item $logFile).Length -gt 0) {
            Write-Host ''
            Write-Host "--- last lines of $logFile ---" -ForegroundColor Yellow
            Get-Content -Path $logFile -Tail 20 | ForEach-Object { Write-Host "    $_" }
        }
    }
}

# Native tools that write to stderr abort the script when $ErrorActionPreference is Stop
# and their output is redirected, so redirected calls run with it relaxed.
function Invoke-NativeCapture([string] $FilePath, [string[]] $Arguments) {
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & $FilePath @Arguments 2>&1
        return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $output }
    }
    finally {
        $ErrorActionPreference = $previous
    }
}

function New-WrapperXml {
    param(
        [string] $Id,
        [string] $Name,
        [string] $ServiceDescription,
        [string] $Executable,
        [string] $ArgumentString,
        [string] $WorkingDirectory,
        [string] $LogDirectory,
        [switch] $Delayed
    )

    $delayedElement = ''
    if ($Delayed) {
        $delayedElement = "`n  <delayedAutoStart>true</delayedAutoStart>"
    }

    return @"
<?xml version="1.0" encoding="UTF-8"?>
<!--
  Generated by install_service.ps1. Changes made here are overwritten the next time that
  script runs. The available options are documented at
  https://github.com/winsw/winsw/blob/v$WinswVersion/doc/xmlConfigFile.md
-->
<service>
  <id>$(Get-XmlText $Id)</id>
  <name>$(Get-XmlText $Name)</name>
  <description>$(Get-XmlText $ServiceDescription)</description>
  <executable>$(Get-XmlText $Executable)</executable>
  <arguments>$(Get-XmlText $ArgumentString)</arguments>
  <workingdirectory>$(Get-XmlText $WorkingDirectory)</workingdirectory>
  <startmode>Automatic</startmode>$delayedElement
  <onfailure action="restart" delay="10 sec"/>
  <onfailure action="restart" delay="30 sec"/>
  <onfailure action="restart" delay="60 sec"/>
  <resetfailure>1 hour</resetfailure>
  <stoptimeout>15 sec</stoptimeout>
  <logpath>$(Get-XmlText $LogDirectory)</logpath>
  <log mode="roll-by-size">
    <sizeThreshold>10240</sizeThreshold>
    <keepFiles>8</keepFiles>
  </log>
</service>
"@
}

function Remove-ExistingService {
    param(
        [string] $Id,
        [string] $WrapperExe
    )

    $service = Get-Service -Name $Id -ErrorAction SilentlyContinue
    if (-not $service) { return }

    Write-Note "Removing the existing '$Id' service."

    if ($service.Status -ne 'Stopped') {
        Stop-Service -Name $Id -Force -ErrorAction SilentlyContinue
        try {
            $service.WaitForStatus('Stopped', [TimeSpan]::FromSeconds(30))
        }
        catch {
            Write-Warn 'The service did not stop within 30 seconds, removing it anyway.'
        }
    }

    if (Test-Path $WrapperExe) {
        & $WrapperExe 'uninstall' | Out-Null
    }
    else {
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
        throw "The existing '$Id' service could not be removed. Close services.msc, Event Viewer and Task Manager, then try again."
    }
}

function Install-WrappedService {
    param(
        [string] $Id,
        [string] $Name,
        [string] $ServiceDescription,
        [string] $Executable,
        [string] $ArgumentString,
        [string] $WorkingDirectory,
        [string] $ServiceDirectory,
        [string] $LogDirectory,
        [string] $WrapperSource,
        [string] $Account,
        [switch] $Delayed,
        [switch] $DoNotStart
    )

    $wrapperExe = Join-Path $ServiceDirectory "$Id.exe"
    $wrapperXml = Join-Path $ServiceDirectory "$Id.xml"

    Copy-Item -Path $WrapperSource -Destination $wrapperExe -Force

    $xml = New-WrapperXml -Id $Id -Name $Name -ServiceDescription $ServiceDescription `
        -Executable $Executable -ArgumentString $ArgumentString `
        -WorkingDirectory $WorkingDirectory -LogDirectory $LogDirectory -Delayed:$Delayed

    # UTF-8 with no BOM: the wrapper parses this as XML, and a BOM ahead of the
    # declaration is a parse error.
    [System.IO.File]::WriteAllText($wrapperXml, $xml, (New-Object System.Text.UTF8Encoding($false)))

    Write-Note "Command    : $Executable $ArgumentString"
    Write-Note "Working dir: $WorkingDirectory"

    & $wrapperExe 'install'
    if ($LASTEXITCODE -ne 0) {
        throw "The service wrapper failed to install '$Id' (exit code $LASTEXITCODE)."
    }

    if ($Account -ne 'LocalSystem') {
        $accountNames = @{
            'NetworkService' = 'NT AUTHORITY\NetworkService'
            'LocalService'   = 'NT AUTHORITY\LocalService'
        }
        $accountName = $accountNames[$Account]
        & sc.exe config $Id obj= $accountName | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to set the logon account of '$Id' to $accountName (sc.exe exit code $LASTEXITCODE)."
        }
        Write-Note "Logon as   : $accountName"
    }

    if ($DoNotStart) {
        Write-Note "Installed, left stopped."
        return $false
    }

    $started = $true
    try {
        Start-Service -Name $Id
        (Get-Service -Name $Id).WaitForStatus('Running', [TimeSpan]::FromSeconds(30))
    }
    catch {
        $started = $false
        Write-Warn "'$Id' did not reach the Running state: $($_.Exception.Message)"
    }

    if ($started) {
        # A service whose child process dies immediately still reports Running for a
        # moment, so give it a few seconds before believing it.
        Start-Sleep -Seconds 3
        if ((Get-Service -Name $Id).Status -ne 'Running') {
            $started = $false
            Write-Warn "'$Id' stopped again shortly after starting."
        }
    }

    if (-not $started) {
        Show-ServiceLogTail -LogDirectory $LogDirectory -Id $Id
        return $false
    }

    Write-Note 'Running.'
    return $true
}

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------

Assert-Administrator

$scriptDir = $PSScriptRoot
$serverDir = (Resolve-Path (Join-Path $scriptDir '..\..')).Path
$repoRoot = (Resolve-Path (Join-Path $serverDir '..')).Path
$serviceDir = Join-Path $scriptDir 'service'
$serviceLogDir = Join-Path $serviceDir 'logs'
$serviceExe = Join-Path $serviceDir "$ServiceName.exe"
$turnWrapperExe = Join-Path $serviceDir "$TurnServiceName.exe"
$serverEntry = Join-Path $serverDir 'dist\index.js'
$coturnDir = Join-Path $scriptDir 'coturn'
$turnExe = Join-Path $coturnDir 'turnserver.exe'

Write-Host ''
Write-Host 'Pixel Streaming signalling server - Windows service setup' -ForegroundColor Green
Write-Note "Repository : $repoRoot"
Write-Note "Server     : $serverDir"
Write-Note "Service id : $ServiceName"

if ($Rebuild -and $SkipBuild) {
    throw 'Use either -Rebuild or -SkipBuild, not both.'
}
if ($ServiceName -eq $TurnServiceName) {
    throw 'The signalling server and TURN services need different names.'
}

$wanted = @($ServiceName)
if ($StartTurn) { $wanted += $TurnServiceName }
foreach ($id in $wanted) {
    if ((Get-Service -Name $id -ErrorAction SilentlyContinue) -and -not $Force) {
        throw "A service named '$id' already exists. Re-run with -Force to replace it, run uninstall_service.ps1 to remove it, or pass -ServiceName / -TurnServiceName to install under another name."
    }
}

# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------

if ($SkipBuild) {
    Write-Step 'Skipping setup and build (-SkipBuild)'
}
else {
    Write-Step 'Setting up dependencies and building the frontend'
    Write-Note 'On a first run this downloads Node and builds every workspace, which takes several minutes.'

    $setupArgs = @()
    if ($Rebuild) {
        $setupArgs += '--rebuild'
        $setupArgs += '--deps'
    }
    elseif (-not (Test-Path (Join-Path $repoRoot 'node_modules'))) {
        # setup.bat only installs workspace dependencies when it had to download Node
        # itself, so an existing node directory with no node_modules would otherwise
        # produce a server that builds but cannot resolve its imports at runtime.
        Write-Note 'Workspace dependencies are missing, forcing an npm install.'
        $setupArgs += '--deps'
    }

    $setupBat = Join-Path $scriptDir 'setup.bat'
    & $setupBat @setupArgs
    if ($LASTEXITCODE -ne 0) {
        Write-Warn "setup.bat exited with code $LASTEXITCODE. Continuing - the checks below will catch a broken build."
    }
}

# Node is resolved after setup.bat, because that is what downloads the bundled copy.
$bundledNodeDir = Join-Path $scriptDir 'node'
$bundledNode = Join-Path $bundledNodeDir 'node.exe'
if (Test-Path $bundledNode) {
    $nodeExe = $bundledNode
    $env:Path = "$bundledNodeDir;$env:Path"
}
else {
    $systemNode = Get-Command 'node.exe' -ErrorAction SilentlyContinue
    if (-not $systemNode) {
        throw "Could not find node.exe. Run setup.bat in $scriptDir first, or install Node.js and put it on PATH."
    }
    $nodeExe = $systemNode.Source
    Write-Warn "Using the system Node at $nodeExe. setup.bat normally installs a matching copy under $bundledNodeDir."
}

$nodeVersion = (& $nodeExe '-v') -join ''
$requiredVersion = (Get-Content -Path (Join-Path $repoRoot 'NODE_VERSION') -Raw).Trim()
Write-Note "Node       : $nodeVersion ($nodeExe)"
if ($nodeVersion -ne $requiredVersion) {
    Write-Warn "This repository is built and tested against Node $requiredVersion."
}

if (-not $SkipBuild) {
    # setup.bat installs dependencies and builds the libraries and frontend; the server
    # itself is built by start.bat, which this service replaces.
    if ($Rebuild -or -not (Test-Path $serverEntry)) {
        Write-Step 'Building the signalling server'
        Push-Location $serverDir
        try {
            $npmCmd = Join-Path $bundledNodeDir 'npm.cmd'
            if (-not (Test-Path $npmCmd)) { $npmCmd = 'npm.cmd' }
            & $npmCmd 'run' 'build'
            if ($LASTEXITCODE -ne 0) { throw "npm run build failed with exit code $LASTEXITCODE." }
        }
        finally {
            Pop-Location
        }
    }
}

if (-not (Test-Path $serverEntry)) {
    throw "The signalling server has not been built - $serverEntry is missing. Re-run without -SkipBuild, or build it by hand with 'npm run build' in $serverDir."
}

if ($StartTurn -and -not (Test-Path $turnExe)) {
    throw "-StartTurn was requested but the TURN server is not installed at $turnExe. Run setup.bat in $scriptDir to download it, or re-run this script without -SkipBuild."
}

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

Write-Step 'Reading the server configuration'

if ($ConfigFile) {
    if (-not (Test-Path $ConfigFile)) {
        throw "The config file '$ConfigFile' does not exist."
    }
    $configPath = (Resolve-Path $ConfigFile).Path
}
else {
    $configPath = Join-Path $serverDir 'config.json'
}

$config = $null
if (Test-Path $configPath) {
    try {
        $config = Get-Content -Path $configPath -Raw | ConvertFrom-Json
        Write-Note "Config     : $configPath"
    }
    catch {
        throw "Failed to parse $configPath as JSON: $($_.Exception.Message)"
    }
}
else {
    Write-Note "Config     : none at $configPath, so the server's built-in defaults apply."
}

$playerPort = [int](Resolve-Setting -Name 'player_port' -Config $config -Default 80)
$streamerPort = [int](Resolve-Setting -Name 'streamer_port' -Config $config -Default 8888)
$sfuPort = [int](Resolve-Setting -Name 'sfu_port' -Config $config -Default 8889)
$httpsPort = [int](Resolve-Setting -Name 'https_port' -Config $config -Default 443)

$httpsEnabled = $false
if ($ServerArgs -contains '--https') {
    $httpsEnabled = $true
}
elseif ($null -ne $config -and ($config.PSObject.Properties.Name -contains 'https')) {
    $httpsEnabled = [bool]$config.https
}

$httpsRedirect = $false
if ($ServerArgs -contains '--https_redirect') {
    $httpsRedirect = $true
}
elseif ($null -ne $config -and ($config.PSObject.Properties.Name -contains 'https_redirect')) {
    $httpsRedirect = [bool]$config.https_redirect
}

# With HTTPS on and no redirect the player port is never bound - the signalling server
# hands player connections to the HTTPS listener instead - so the health check below has
# to look at the port that is actually meant to be listening.
if ($httpsEnabled -and -not $httpsRedirect) { $probePort = $httpsPort } else { $probePort = $playerPort }

# The service passes --serve, the same as "npm start" does, unless the config file turns
# the web server off on purpose. A command line flag cannot be unset from the config, so
# that opt-out has to be honoured here.
$serveDisabled = ($null -ne $config) -and
                 ($config.PSObject.Properties.Name -contains 'serve') -and
                 (-not [bool]$config.serve)

$homepage = [string](Resolve-Setting -Name 'homepage' -Config $config -Default 'player.html')
$httpRoot = [string](Resolve-Setting -Name 'http_root' -Config $config -Default (Join-Path $serverDir 'www'))
if (-not [System.IO.Path]::IsPathRooted($httpRoot)) {
    # The server resolves a relative root against its working directory, which is the
    # SignallingWebServer directory for this service.
    $httpRoot = Join-Path $serverDir $httpRoot
}

$httpRootFromArgs = $null -ne (Get-OptionValue -Arguments $ServerArgs -Name 'http_root')
$httpRootOverride = ''

Write-Note "Ports      : players $playerPort, streamers $streamerPort, SFU $sfuPort"
if ($httpsEnabled) { Write-Note "HTTPS port : $httpsPort" }

if ($serveDisabled) {
    Write-Note 'Web root   : none, "serve" is false in the config file so only signalling runs.'
}
else {
    if (-not (Test-Path (Join-Path $httpRoot $homepage))) {
        $builtFrontend = Join-Path $serverDir 'www'

        if (-not $httpRootFromArgs -and (Test-Path (Join-Path $builtFrontend $homepage))) {
            # config.json normally holds an absolute http_root written by whichever
            # checkout last ran with --save, so a moved or re-cloned repository leaves it
            # pointing at a directory that no longer exists. The server starts perfectly
            # well like that and answers every page request with "Unable to locate file
            # player.html", which looks like a broken build rather than a stale path.
            # start.bat sidesteps this by always passing the frontend directory it just
            # built, so the service does the same.
            $httpRootOverride = $builtFrontend
            $httpRoot = $builtFrontend
            Write-Note "Web root   : $httpRoot"
            Write-Warn "The http_root in the config file does not contain '$homepage', so the service will serve the frontend built in this repository instead."
            Write-Warn "Set http_root to that path in $configPath to have start.bat use it too."
        }
        else {
            Write-Note "Web root   : $httpRoot"
            Write-Warn "'$homepage' is not in $httpRoot, so the service will start but serve no frontend."
            Write-Warn "Build the frontend with -Rebuild, or correct http_root in $configPath."
        }
    }
    else {
        Write-Note "Web root   : $httpRoot"
    }
}

# ---------------------------------------------------------------------------
# STUN and TURN
# ---------------------------------------------------------------------------

# Only send ICE servers when they were actually asked for. start.bat always sends both,
# because it defaults TURN to the public IP whether or not a TURN server exists there.
$stunRequested = $PSBoundParameters.ContainsKey('StunServer') -and $StunServer
$turnRequested = [bool]$TurnServer -or $StartTurn
$peerOptionsWanted = $stunRequested -or $turnRequested
$peerOptionsFile = ''
$turnPort = 0

if ($peerOptionsWanted) {
    Write-Step 'Working out the ICE configuration'

    if ($ServerArgs -contains '--peer_options' -or $ServerArgs -contains '--peer_options_file') {
        throw 'Pass the ICE servers with -StunServer / -TurnServer, or with -ServerArgs, but not both.'
    }

    # Mirrors :SetupTurnStun in common.bat, which points TURN at the public IP on the
    # default port when --start-turn was given without an explicit --turn.
    if (-not $TurnLocalIp) {
        $addresses = [System.Net.Dns]::GetHostAddresses($env:COMPUTERNAME) |
            Where-Object { $_.AddressFamily -eq 'InterNetwork' }
        if (-not $addresses) {
            throw 'Could not work out this machine''s IPv4 address. Pass -TurnLocalIp explicitly.'
        }
        $TurnLocalIp = $addresses[0].IPAddressToString
    }

    if (-not $PublicIp) {
        # start.bat asks api.ipify.org at this point. Baking that answer into a service
        # that starts at every boot would silently go stale, so use the local address and
        # let the operator override it.
        $PublicIp = $TurnLocalIp
        Write-Note "No -PublicIp given, the TURN server will advertise $PublicIp."
    }

    if ($StartTurn -and -not $TurnServer) {
        $TurnServer = "$($PublicIp):19303"
        Write-Note "No -TurnServer given, players will be sent to $TurnServer."
    }

    if ($TurnServer) {
        $turnPortText = ($TurnServer -split ':')[-1]
        if ($turnPortText -eq $TurnServer -or -not ($turnPortText -match '^\d+$')) {
            $turnPort = 3478
        }
        else {
            $turnPort = [int]$turnPortText
        }
    }

    $iceServers = @()
    $urls = @()
    if ($StunServer) { $urls += "stun:$StunServer" }
    if ($TurnServer) { $urls += "turn:$TurnServer" }

    if ($TurnServer) {
        $iceServers += [ordered]@{
            urls       = $urls
            username   = $TurnUser
            credential = $TurnPass
        }
    }
    else {
        $iceServers += [ordered]@{ urls = $urls }
    }

    $peerOptions = [ordered]@{ iceServers = $iceServers }

    New-Item -Path $serviceDir -ItemType Directory -Force | Out-Null
    $peerOptionsFile = Join-Path $serviceDir 'peer_options.json'
    # A file rather than --peer_options on the command line: the server warns that JSON
    # on a command line is unreliable, and cmd.exe eats ^ and ! from credentials.
    [System.IO.File]::WriteAllText(
        $peerOptionsFile,
        ($peerOptions | ConvertTo-Json -Depth 6 -Compress),
        (New-Object System.Text.UTF8Encoding($false)))

    Write-Note "ICE servers: $($urls -join ', ')"
    Write-Note "Written to : $peerOptionsFile"

    if ($TurnServer -and ($TurnServer -match '^(127\.0\.0\.1|localhost)\b')) {
        Write-Warn "Players are told to reach TURN at $TurnServer, which only resolves on this machine. Use the address other devices see if they need to relay."
    }
}

# ---------------------------------------------------------------------------
# Smoke test
# ---------------------------------------------------------------------------

Write-Step 'Checking that the server runs'

$smokeArgs = @($serverEntry, '--help')
if ($ConfigFile) {
    # So the check reads the same file the service will, not the default config.json.
    $smokeArgs = @($serverEntry, '--config_file', $configPath, '--help')
}

Push-Location $serverDir
try {
    # --help parses the config file and exits before any port is bound, so this catches
    # missing dependencies and a malformed config without disturbing a running server.
    $smoke = Invoke-NativeCapture -FilePath $nodeExe -Arguments $smokeArgs
}
finally {
    Pop-Location
}

if ($smoke.ExitCode -ne 0) {
    Write-Host ''
    $smoke.Output | Select-Object -First 20 | ForEach-Object { Write-Host "    $_" -ForegroundColor Red }
    throw "'node dist\index.js --help' failed with exit code $($smoke.ExitCode), so the service would not start either. The output above says why - a missing module means dependencies were not installed, in which case re-run with -Rebuild."
}
Write-Note 'The server starts and reads its configuration.'

# ---------------------------------------------------------------------------
# Service wrapper
# ---------------------------------------------------------------------------

Write-Step 'Preparing the service wrapper'

New-Item -Path $serviceDir -ItemType Directory -Force | Out-Null
New-Item -Path $serviceLogDir -ItemType Directory -Force | Out-Null

if ($WinswPath) {
    if (-not (Test-Path $WinswPath)) {
        throw "The WinSW executable '$WinswPath' does not exist."
    }
    $winswSource = (Resolve-Path $WinswPath).Path
    Write-Note "Using the supplied wrapper at $winswSource."
}
else {
    if ([Environment]::Is64BitOperatingSystem) { $arch = 'x64' } else { $arch = 'x86' }
    if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') {
        # WinSW publishes no ARM64 asset; the x64 build runs under emulation.
        Write-Note 'ARM64 Windows detected, using the x64 wrapper under emulation.'
    }

    if (-not $SkipHashCheck -and $WinswVersion -ne $PinnedWinswVersion) {
        throw "The pinned SHA-256 hashes only cover WinSW $PinnedWinswVersion. Re-run with -SkipHashCheck to accept WinSW $WinswVersion, or download it yourself and pass -WinswPath."
    }

    $winswSource = Join-Path $serviceDir "WinSW-$arch.exe"
    $expectedHash = $WinswHashes[$arch]
    $verifyHash = -not $SkipHashCheck

    $needsDownload = $true
    if (Test-Path $winswSource) {
        if (-not $verifyHash) {
            $needsDownload = $false
        }
        elseif ((Get-FileHash -Path $winswSource -Algorithm SHA256).Hash -eq $expectedHash) {
            $needsDownload = $false
            Write-Note "Reusing the verified wrapper at $winswSource."
        }
        else {
            Write-Warn 'The cached wrapper does not match the expected hash and will be downloaded again.'
        }
    }

    if ($needsDownload) {
        $winswUrl = "https://github.com/winsw/winsw/releases/download/v$WinswVersion/WinSW-$arch.exe"
        Write-Note "Downloading $winswUrl"
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $previousProgress = $ProgressPreference
        $ProgressPreference = 'SilentlyContinue'
        try {
            Invoke-WebRequest -Uri $winswUrl -OutFile $winswSource -UseBasicParsing
        }
        catch {
            throw "Failed to download WinSW from $winswUrl - $($_.Exception.Message). Without internet access, download it on another machine and pass -WinswPath."
        }
        finally {
            $ProgressPreference = $previousProgress
        }

        if ($verifyHash) {
            $actualHash = (Get-FileHash -Path $winswSource -Algorithm SHA256).Hash
            if ($actualHash -ne $expectedHash) {
                Remove-Item -Path $winswSource -Force
                throw "The downloaded WinSW executable does not match the expected SHA-256 for version $WinswVersion (expected $expectedHash, got $actualHash). The file has been deleted."
            }
            Write-Note 'SHA-256 verified.'
        }
    }
}

# ---------------------------------------------------------------------------
# TURN service
# ---------------------------------------------------------------------------

$turnRunning = $false

if ($StartTurn) {
    Write-Step "Installing the TURN service ($TurnServiceName)"

    Remove-ExistingService -Id $TurnServiceName -WrapperExe $turnWrapperExe

    # These are the arguments common.bat builds for --start-turn. The config file it
    # names does not ship with the repository; coturn logs that it is missing and falls
    # back to these command line settings, which is the behaviour start.bat relies on.
    $turnArguments = @(
        '-c', '..\..\..\turnserver.conf',
        "--allowed-peer-ip=$TurnLocalIp",
        '-p', "$turnPort",
        '-r', 'PixelStreaming',
        '-X', $PublicIp,
        '-E', $TurnLocalIp,
        '-L', $TurnLocalIp,
        '--no-cli', '--no-tls', '--no-dtls',
        '--pidfile', (Join-Path $coturnDir 'coturn.pid'),
        '-f', '-a', '-v',
        '-u', "$($TurnUser):$($TurnPass)"
    )

    Write-Note "Listening  : $($TurnLocalIp):$turnPort"
    Write-Note "Advertising: $PublicIp"

    $turnRunning = Install-WrappedService `
        -Id $TurnServiceName `
        -Name 'Pixel Streaming TURN Server (coturn)' `
        -ServiceDescription "TURN relay for Unreal Engine Pixel Streaming, used by peers that cannot connect directly." `
        -Executable $turnExe `
        -ArgumentString (Format-CommandLine $turnArguments) `
        -WorkingDirectory $coturnDir `
        -ServiceDirectory $serviceDir `
        -LogDirectory $serviceLogDir `
        -WrapperSource $winswSource `
        -Account $ServiceAccount `
        -Delayed:$DelayedStart `
        -DoNotStart:$NoStart

    if (-not $turnRunning -and -not $NoStart) {
        # Not fatal: the signalling server is still worth installing, and TURN failing to
        # bind an address that is not up yet is exactly what the restart actions are for.
        Write-Warn "The TURN service is installed but not running. It will be retried automatically, and at the next boot."
    }
}

# ---------------------------------------------------------------------------
# Signalling service
# ---------------------------------------------------------------------------

Write-Step "Installing the signalling service ($ServiceName)"

Remove-ExistingService -Id $ServiceName -WrapperExe $serviceExe

$commandLine = @($serverEntry)
if (-not $serveDisabled) {
    $commandLine += '--serve'
}
# The startup configuration ends up in the server log, which is the only view into a
# service that will not start.
$commandLine += '--log_config'
if ($ConfigFile) {
    $commandLine += @('--config_file', $configPath)
}
if ($httpRootOverride) {
    $commandLine += @('--http_root', $httpRootOverride)
}
if ($peerOptionsFile) {
    $commandLine += @('--peer_options_file', $peerOptionsFile)
}
$commandLine += $ServerArgs

$signallingRunning = Install-WrappedService `
    -Id $ServiceName `
    -Name $DisplayName `
    -ServiceDescription $Description `
    -Executable $nodeExe `
    -ArgumentString (Format-CommandLine $commandLine) `
    -WorkingDirectory $serverDir `
    -ServiceDirectory $serviceDir `
    -LogDirectory $serviceLogDir `
    -WrapperSource $winswSource `
    -Account $ServiceAccount `
    -Delayed:$DelayedStart `
    -DoNotStart:$NoStart

if ($ServiceAccount -ne 'LocalSystem') {
    Write-Warn "$ServiceAccount needs write access to $serviceLogDir and $(Join-Path $serverDir 'logs') or the services will fail to start."
}

if (-not $signallingRunning -and -not $NoStart) {
    throw "The '$ServiceName' service was installed but is not running. The logs above and in $serviceLogDir say why - a port already in use is the most common cause, so check that no other copy of the server is listening on port $probePort."
}

if (-not $NoStart) {
    if (Test-TcpPort -ComputerName '127.0.0.1' -Port $probePort) {
        Write-Note "Port $probePort is accepting connections."
    }
    else {
        Write-Warn "The service is running but nothing is listening on port $probePort yet. Check $(Join-Path $serverDir 'logs')."
    }
}

# ---------------------------------------------------------------------------
# Firewall
# ---------------------------------------------------------------------------

if ($OpenFirewall) {
    Write-Step 'Adding Windows Firewall rules'

    $firewallRules = @(
        @{ Name = "Pixel Streaming - Players (TCP $playerPort)"; Protocol = 'TCP'; Port = "$playerPort" },
        @{ Name = "Pixel Streaming - Streamers (TCP $streamerPort)"; Protocol = 'TCP'; Port = "$streamerPort" },
        @{ Name = "Pixel Streaming - SFU (TCP $sfuPort)"; Protocol = 'TCP'; Port = "$sfuPort" }
    )
    if ($httpsEnabled) {
        $firewallRules += @{ Name = "Pixel Streaming - Players HTTPS (TCP $httpsPort)"; Protocol = 'TCP'; Port = "$httpsPort" }
    }
    if ($StartTurn) {
        $firewallRules += @{ Name = "Pixel Streaming - TURN (UDP $turnPort)"; Protocol = 'UDP'; Port = "$turnPort" }
        $firewallRules += @{ Name = "Pixel Streaming - TURN (TCP $turnPort)"; Protocol = 'TCP'; Port = "$turnPort" }
        # coturn allocates relay sockets from this range by default. Without it a peer
        # can authenticate against TURN and still fail to relay any media.
        $firewallRules += @{ Name = 'Pixel Streaming - TURN relay (UDP 49152-65535)'; Protocol = 'UDP'; Port = '49152-65535' }
    }

    foreach ($rule in $firewallRules) {
        try {
            Get-NetFirewallRule -DisplayName $rule.Name -ErrorAction SilentlyContinue |
                Remove-NetFirewallRule -ErrorAction SilentlyContinue
            New-NetFirewallRule -DisplayName $rule.Name `
                -Group 'Pixel Streaming' `
                -Direction Inbound `
                -Action Allow `
                -Protocol $rule.Protocol `
                -LocalPort $rule.Port `
                -Profile Any | Out-Null
            Write-Note "Allowed inbound $($rule.Protocol) $($rule.Port)."
        }
        catch {
            # The services are installed by this point, so a firewall failure is reported
            # rather than treated as fatal.
            Write-Warn "Could not add the rule '$($rule.Name)': $($_.Exception.Message)"
        }
    }
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

$hostName = $env:COMPUTERNAME
if ($httpsEnabled) {
    if ($httpsPort -eq 443) { $playerUrl = "https://$hostName" } else { $playerUrl = "https://$($hostName):$httpsPort" }
}
else {
    if ($playerPort -eq 80) { $playerUrl = "http://$hostName" } else { $playerUrl = "http://$($hostName):$playerPort" }
}

Write-Host ''
Write-Host 'Done.' -ForegroundColor Green
Write-Host ''
Write-Host "  Service        : $ServiceName ($DisplayName)"
if ($StartTurn) {
    Write-Host "  TURN service   : $TurnServiceName"
}
Write-Host "  Starts at boot : yes"
if ($NoStart) {
    Write-Host "  Right now      : stopped, start it with 'Start-Service $ServiceName'"
}
else {
    Write-Host "  Right now      : running"
}
if (-not $serveDisabled) {
    Write-Host "  Players open   : $playerUrl"
}
Write-Host "  Streamers use  : ws://$($hostName):$streamerPort   (the signalling server URL in Unreal)"
if ($peerOptionsFile) {
    Write-Host "  ICE servers    : $peerOptionsFile"
}
Write-Host "  Server logs    : $(Join-Path $serverDir 'logs')"
Write-Host "  Service logs   : $serviceLogDir"
if ($StartTurn) {
    Write-Host "  TURN logs      : $coturnDir"
}
Write-Host ''
Write-Host '  Manage them with:'
Write-Host "    Get-Service $ServiceName$(if ($StartTurn) { ", $TurnServiceName" })"
Write-Host "    Restart-Service $ServiceName"
Write-Host "    .\uninstall_service.ps1 -ServiceName $ServiceName"
Write-Host ''
Write-Host "  Settings live in $configPath - edit it, then restart the service to apply them."
Write-Host ''
