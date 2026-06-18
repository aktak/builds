#Requires -Version 5.1
<#
  install-docker-sp-windows.ps1 — Windows port of install-docker-sp-macos.sh.

  Ensures Docker Desktop is installed, running, and set to LINUX containers,
  then brings up the SQL Server 2025 + smart-portal containers.

  Run from an elevated PowerShell the first time (installing Docker needs admin):
    powershell -ExecutionPolicy Bypass -File .\install-docker-sp-windows.ps1
#>

# Keep this 'Continue', NOT 'Stop'. Docker writes warnings/progress to stderr
# (e.g. "WARNING: No blkio throttle.read_bps_device support"), and under 'Stop'
# PowerShell turns each stderr line into a TERMINATING error that aborts the
# script even when docker actually succeeded. We check $LASTEXITCODE ourselves.
$ErrorActionPreference = 'Continue'
# On PS 7+, also stop a non-zero native exit code from throwing. Harmless on 5.1.
$PSNativeCommandUseErrorActionPreference = $false

# --- pretty logging ---------------------------------------------------------
function Log  { param([string]$m) Write-Host "==> $m" -ForegroundColor Blue }
function Warn { param([string]$m) Write-Host "[!] $m"  -ForegroundColor Yellow }
function Fail { param([string]$m) Write-Host "[x] $m"  -ForegroundColor Red }

# Run docker swallowing all output; return $true on exit code 0. With
# $ErrorActionPreference='Continue' (set above), 2>$null discards docker's stderr
# warnings cleanly instead of letting them abort the script.
function Invoke-DockerQuiet {
  & docker @args 2>$null | Out-Null
  return ($LASTEXITCODE -eq 0)
}

# Run docker and return its stdout (trimmed); empty string on any failure.
# stderr is discarded (2>$null) so warnings never land in the returned value.
function Invoke-DockerOut {
  $out = & docker @args 2>$null
  if ($LASTEXITCODE -ne 0) { return '' }
  return ("$out").Trim()
}

# --- config (mirrors the macOS script) -------------------------------------
$NetName = 'nito-network'

$MssqlName               = 'nito-sql2025'
$MssqlImage              = 'mcr.microsoft.com/mssql/server:2025-latest'
$MssqlVolume             = Join-Path $HOME 'nito\sql'
$MssqlBackupDir          = Join-Path $MssqlVolume 'backup'
$MssqlBackupContainerDir = '/var/opt/mssql/backup'
$MssqlSaPassword         = 'StrongP@sswordSql2022'

$SpName             = 'nito-sp-dev'
$SpImage            = 'ghcr.io/aktak/smart-portal:latest'
$SpPlatform         = 'linux/amd64'   # image is amd64-only; emulated on Windows-on-ARM
$SpAppDir           = Join-Path $HOME 'nito\sp-dev'
$SpConfig           = Join-Path $SpAppDir 'config.json'
$SpAppContainerPort = 8080
$SpApiContainerPort = 5001
$SpAppDefaultPort   = 8080
$SpApiDefaultPort   = 5001
$script:SpAppPort   = ''
$script:SpApiPort   = ''

# --- docker helpers ---------------------------------------------------------
function Test-DockerUp   { return (Invoke-DockerQuiet info) }
function Get-DockerOsType { return (Invoke-DockerOut info --format '{{.OSType}}') }

function Get-DockerDesktopExe {
  $c = Join-Path $env:ProgramFiles 'Docker\Docker\Docker Desktop.exe'
  if (Test-Path $c) { return $c }
  return $null
}
function Get-DockerCliExe {
  $c = Join-Path $env:ProgramFiles 'Docker\Docker\DockerCli.exe'
  if (Test-Path $c) { return $c }
  return $null
}

function Test-ContainerExists  { param([string]$Name) return (@(& docker ps -a --format '{{.Names}}' 2>$null) -contains $Name) }
function Test-ContainerRunning { param([string]$Name) return (@(& docker ps    --format '{{.Names}}' 2>$null) -contains $Name) }

# --- Ensure Docker is running AND in LINUX-container mode --------------------
# Order matters: `docker info` talks to whichever engine is selected, so if Docker
# is on Windows containers (or still booting) the Linux pipe doesn't exist and any
# `docker info` fails. So: start the app, request the Linux engine, THEN wait.
function Ensure-DockerLinux {
  # 1) Make sure the Docker Desktop app process is running.
  if (Get-Process 'Docker Desktop' -ErrorAction SilentlyContinue) {
    Log 'Docker Desktop is running.'
  } else {
    $exe = Get-DockerDesktopExe
    if (-not $exe) { Fail 'Could not find "Docker Desktop.exe" to launch.'; throw 'Docker Desktop not found.' }
    Log 'Starting Docker Desktop...'
    Start-Process -FilePath $exe | Out-Null
  }

  # 2) Select the Linux engine (idempotent — no-op if already on Linux).
  $cli = Get-DockerCliExe
  if ($cli) {
    Log 'Selecting the Linux container engine...'
    $null = & $cli -SwitchLinuxEngine 2>&1
  } else {
    Warn 'DockerCli.exe not found — if Docker is on Windows containers, switch via the tray icon.'
  }

  # 3) Wait for the Linux daemon to answer (cold start can take a couple minutes).
  Log 'Waiting for the Docker (Linux) daemon to become ready...'
  for ($i = 0; $i -lt 90; $i++) {
    if (Test-DockerUp) {
      if ((Get-DockerOsType) -eq 'linux') { Log 'Docker daemon is ready (Linux containers).'; return }
      # Came up on Windows containers — flip it and keep waiting.
      if ($cli) { $null = & $cli -SwitchLinuxEngine 2>&1 }
    }
    Start-Sleep -Seconds 2
  }
  Fail 'Timed out waiting for the Linux engine. Open Docker Desktop and switch to Linux containers.'
  throw 'Linux engine not ready.'
}

# --- Network ----------------------------------------------------------------
function Ensure-Network {
  if (Invoke-DockerQuiet network inspect $NetName) {
    Log "Network '$NetName' already exists."
  } else {
    Log "Creating network '$NetName'..."
    & docker network create $NetName | Out-Null
  }
}

function Connect-Network {
  param([string]$Name)
  $nets = Invoke-DockerOut inspect -f '{{range $n,$_ := .NetworkSettings.Networks}}{{$n}} {{end}}' $Name
  if (@($nets -split '\s+') -contains $NetName) {
    Log "Container '$Name' is already on network '$NetName'."
  } else {
    Log "Connecting container '$Name' to network '$NetName'..."
    & docker network connect $NetName $Name
  }
}

# --- SQL Server 2025 --------------------------------------------------------
function Ensure-BackupDir {
  if (-not (Test-Path $MssqlBackupDir)) {
    Log "Creating backup folder at $MssqlBackupDir..."
    New-Item -ItemType Directory -Force -Path $MssqlBackupDir | Out-Null
  }
}

function Ensure-Mssql2025 {
  if (Test-ContainerExists $MssqlName) {
    if (Test-ContainerRunning $MssqlName) {
      Log "Container '$MssqlName' is already running."
    } else {
      Log "Container '$MssqlName' exists but is stopped. Starting it..."
      & docker start $MssqlName | Out-Null
    }
    Connect-Network $MssqlName
    return
  }

  Log "Container '$MssqlName' not found. Creating it..."
  # Only the backup folder is persisted to the host — DB data lives inside the
  # container, so dropping it wipes databases (restore from a .bak to recover).
  Ensure-BackupDir
  & docker run -d --name $MssqlName `
    --network $NetName `
    -e 'ACCEPT_EULA=Y' `
    -e "MSSQL_SA_PASSWORD=$MssqlSaPassword" `
    -e 'MSSQL_PID=developer' `
    -p '1433:1433' `
    -v "${MssqlBackupDir}:${MssqlBackupContainerDir}" `
    $MssqlImage | Out-Null
  Log "Container '$MssqlName' created and started."
}

# --- smart-portal (nito-sp-dev) --------------------------------------------
# Block until a container is at least running (not waiting for app readiness).
function Wait-ContainerRunning {
  param([string]$Name)
  for ($i = 0; $i -lt 30; $i++) {
    if ((Invoke-DockerOut inspect -f '{{.State.Running}}' $Name) -eq 'true') { return $true }
    Start-Sleep -Seconds 1
  }
  Warn "Container '$Name' did not reach 'running' within 30s."
  return $false
}

# Read the published host port for a container port via `docker port` (avoids the
# Go-template quoting pain on Windows). Empty for a stopped/absent container.
function Get-PublishedPort {
  param([string]$Name, [int]$ContainerPort)
  $out = Invoke-DockerOut port $Name "$ContainerPort/tcp"
  if (-not $out) { return '' }
  return ((@($out -split "`n")[0] -split ':')[-1]).Trim()
}

function Read-PortOrDefault {
  param([string]$Prompt, [int]$Default)
  $val = Read-Host "$Prompt [$Default]"
  if ([string]::IsNullOrWhiteSpace($val)) { return $Default }
  if ($val -notmatch '^\d+$' -or [int]$val -lt 1 -or [int]$val -gt 65535) {
    Warn "Invalid port '$val' — using default $Default."
    return $Default
  }
  return [int]$val
}

function Prompt-SpPorts {
  $script:SpAppPort = Read-PortOrDefault 'Host port to publish the smart-portal WEB APP on' $SpAppDefaultPort
  $script:SpApiPort = Read-PortOrDefault 'Host port to publish the smart-portal API on'     $SpApiDefaultPort
}

# Make sure a host-side config.json exists to mount into the smart-portal
# container. On first run it's written with the default below (db_server points
# at the SQL container); afterwards the host file is the source of truth.
function Ensure-SpConfig {
  New-Item -ItemType Directory -Force -Path $SpAppDir | Out-Null
  if (-not (Test-Path $SpConfig)) {
    Log "Writing smart-portal config at $SpConfig..."
    # Build via a hashtable + ConvertTo-Json (no here-string — those break when the
    # .ps1 has LF line endings, as it does when fetched from raw.githubusercontent).
    $cfg = [ordered]@{
      customer    = 'DEV'
      db_server   = $MssqlName
      db_username = 'sa'
      db_userpass = $MssqlSaPassword
      db_name     = 'Sova_monitoring'
      app_port    = "$SpAppContainerPort"
      api_port    = "$SpApiContainerPort"
      x_api_key   = 'change-me-to-a-long-random-secret'
    }
    # WriteAllText => UTF-8 without BOM (a BOM can trip up JSON parsers).
    [System.IO.File]::WriteAllText($SpConfig, ($cfg | ConvertTo-Json))
  }
}

function Report-SpImage {
  $digest  = Invoke-DockerOut image inspect --format '{{range .RepoDigests}}{{.}} {{end}}' $SpImage
  $created = Invoke-DockerOut image inspect --format '{{.Created}}' $SpImage
  if ([string]::IsNullOrWhiteSpace($digest))  { $digest  = $SpImage }
  if ([string]::IsNullOrWhiteSpace($created)) { $created = 'unknown' }
  Log "Using image: $digest (built $created)"
}

# Pull the latest smart-portal image, prompting for ghcr.io credentials only if
# the pull fails (i.e. not already authenticated to the private registry).
function Pull-SpImage {
  Log "Pulling latest '$SpImage'..."
  & docker pull --platform $SpPlatform $SpImage
  if ($LASTEXITCODE -eq 0) { Report-SpImage; return }

  Warn 'Pull failed — authenticating with ghcr.io...'
  $ghUser        = Read-Host 'GitHub username'
  $ghTokenSecure = Read-Host 'GitHub token (PAT with read:packages)' -AsSecureString
  $ghToken = [Runtime.InteropServices.Marshal]::PtrToStringBSTR(
               [Runtime.InteropServices.Marshal]::SecureStringToBSTR($ghTokenSecure))
  if ([string]::IsNullOrWhiteSpace($ghUser) -or [string]::IsNullOrWhiteSpace($ghToken)) {
    Fail 'Username and token are required to pull from ghcr.io.'
    throw 'Missing ghcr.io credentials.'
  }
  $ghToken | & docker login ghcr.io -u $ghUser --password-stdin
  if ($LASTEXITCODE -ne 0) { Fail 'docker login to ghcr.io failed.'; throw 'docker login failed.' }

  & docker pull --platform $SpPlatform $SpImage
  if ($LASTEXITCODE -eq 0) { Report-SpImage; return }

  if (Invoke-DockerQuiet image inspect $SpImage) {
    Warn '############################################################'
    Warn "# COULD NOT FETCH THE LATEST '$SpImage'."
    Warn '# Continuing with the OLD locally cached image — it may be'
    Warn '# OUTDATED. Fix connectivity/ghcr.io auth and rerun to update.'
    Warn '############################################################'
    Report-SpImage
    return
  }
  Fail "Unable to obtain image '$SpImage'."
  throw 'Image unavailable.'
}

function Run-SpDev {
  Ensure-SpConfig
  if (-not $script:SpAppPort) { $script:SpAppPort = $SpAppDefaultPort }
  if (-not $script:SpApiPort) { $script:SpApiPort = $SpApiDefaultPort }
  & docker run -d --name $SpName `
    --platform $SpPlatform `
    --network $NetName `
    -p "$($script:SpAppPort):$SpAppContainerPort" `
    -p "$($script:SpApiPort):$SpApiContainerPort" `
    -v "${SpConfig}:/app/config.json" `
    $SpImage | Out-Null
  Wait-ContainerRunning $SpName | Out-Null
  Log "Container '$SpName' created and started (web $($script:SpAppPort)->$SpAppContainerPort, api $($script:SpApiPort)->$SpApiContainerPort)."
}

function Ensure-SpDev {
  # Always fetch the latest image first, then make the container match it.
  Pull-SpImage

  $latestImg = Invoke-DockerOut image inspect --format '{{.Id}}' $SpImage

  if (Test-ContainerExists $SpName) {
    # Container exists — reuse its published host ports (don't ask).
    $script:SpAppPort = Get-PublishedPort $SpName $SpAppContainerPort; if (-not $script:SpAppPort) { $script:SpAppPort = $SpAppDefaultPort }
    $script:SpApiPort = Get-PublishedPort $SpName $SpApiContainerPort; if (-not $script:SpApiPort) { $script:SpApiPort = $SpApiDefaultPort }
    Log "Container '$SpName' is published on host ports web=$($script:SpAppPort) api=$($script:SpApiPort)."

    $currentImg = Invoke-DockerOut inspect --format '{{.Image}}' $SpName
    if ($currentImg -ne $latestImg) {
      Log "Newer image pulled. Recreating '$SpName'..."
      & docker rm -f $SpName | Out-Null
      Run-SpDev
      return
    }
    if (Test-ContainerRunning $SpName) {
      Log "Container '$SpName' is already running on the latest image."
    } else {
      Log "Container '$SpName' is up to date but stopped. Starting it..."
      & docker start $SpName | Out-Null
      Wait-ContainerRunning $SpName | Out-Null
    }
    Connect-Network $SpName
    return
  }

  # First create — ask which host ports to publish on (defaults 8080 / 5001).
  Log "Container '$SpName' not found. Creating it from $SpImage..."
  Prompt-SpPorts
  Run-SpDev
}

# --- Install Docker Desktop (winget > choco > direct download) --------------
function Install-DockerDesktop {
  Log 'Docker not found. Installing Docker Desktop for Windows...'

  if (Get-Command winget -ErrorAction SilentlyContinue) {
    Log 'Installing via winget (Docker.DockerDesktop)...'
    winget install -e --id Docker.DockerDesktop --accept-package-agreements --accept-source-agreements
    return
  }
  if (Get-Command choco -ErrorAction SilentlyContinue) {
    Log 'Installing via Chocolatey (docker-desktop)...'
    choco install docker-desktop -y
    return
  }

  Warn 'winget/choco not found — downloading the Docker Desktop installer directly.'
  $installer = Join-Path $env:TEMP 'DockerDesktopInstaller.exe'
  $url = 'https://desktop.docker.com/win/main/amd64/Docker Desktop Installer.exe'
  Log 'Downloading Docker Desktop installer...'
  Invoke-WebRequest -Uri $url -OutFile $installer -ErrorAction Stop
  Log 'Running the installer (quiet, accept license)...'
  Start-Process -FilePath $installer -ArgumentList 'install','--quiet','--accept-license' -Wait
  Remove-Item $installer -ErrorAction SilentlyContinue
}

# --- Sanity: Windows only ---------------------------------------------------
if ($env:OS -ne 'Windows_NT') {
  Fail 'This script only supports Windows.'
  exit 1
}

# --- Already installed? -----------------------------------------------------
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
  Install-DockerDesktop
  # Make `docker` resolvable in this session without a relaunch.
  $env:Path = (Join-Path $env:ProgramFiles 'Docker\Docker\resources\bin') + ';' + $env:Path
  if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    Warn 'Docker was installed but the `docker` CLI is not on PATH yet.'
    Warn 'Sign out and back in (or reboot) to finish Docker Desktop setup, then re-run this script.'
    exit 0
  }
} else {
  Log "Docker is already installed: $(& docker --version)"
}

Ensure-DockerLinux
Ensure-Network
Ensure-Mssql2025
Ensure-SpDev
Log 'Done.'
