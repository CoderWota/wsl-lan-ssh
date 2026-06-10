[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Test-IsAdministrator {
  $currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
  $principal = [Security.Principal.WindowsPrincipal]::new($currentIdentity)
  return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Read-JsonFile {
  param([Parameter(Mandatory = $true)][string]$Path)
  return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
}

function Invoke-NativeCommand {
  param(
    [Parameter(Mandatory = $true)][string]$FilePath,
    [Parameter(Mandatory = $true)][string[]]$Arguments,
    [Parameter(Mandatory = $true)][string]$Description
  )

  $output = & $FilePath @Arguments 2>&1
  $exitCode = $LASTEXITCODE
  if ($exitCode -ne 0) {
    $message = @($output) -join [Environment]::NewLine
    throw "$Description failed with exit code $exitCode. $message"
  }

  return $output
}

function Test-DistroExists {
  param([Parameter(Mandatory = $true)][string]$DistroName)

  $distros = Invoke-NativeCommand -FilePath "wsl.exe" -Arguments @("-l", "-q") -Description "List WSL distributions"
  if (-not $distros) {
    return $false
  }

  return [bool]($distros | Where-Object { $_.Trim() -eq $DistroName } | Select-Object -First 1)
}

function Remove-PortProxyForPort {
  param(
    [Parameter(Mandatory = $true)][int]$ListenPort,
    [string]$ListenAddress
  )

  $rows = Invoke-NativeCommand -FilePath "netsh.exe" -Arguments @("interface", "portproxy", "show", "v4tov4") -Description "List portproxy entries"
  foreach ($row in $rows) {
    if ($ListenAddress) {
      $escapedListenAddress = [regex]::Escape($ListenAddress)
      if ($row -match "^\s*($escapedListenAddress)\s+($ListenPort)\s+\d{1,3}(?:\.\d{1,3}){3}\s+\d+\s*$") {
        Invoke-NativeCommand -FilePath "netsh.exe" -Arguments @("interface", "portproxy", "delete", "v4tov4", "listenaddress=$ListenAddress", "listenport=$ListenPort") -Description "Delete portproxy $ListenAddress`:$ListenPort"
      }
      continue
    }

    if ($row -match "^\s*(\d{1,3}(?:\.\d{1,3}){3})\s+($ListenPort)\s+\d{1,3}(?:\.\d{1,3}){3}\s+\d+\s*$") {
      Invoke-NativeCommand -FilePath "netsh.exe" -Arguments @("interface", "portproxy", "delete", "v4tov4", "listenaddress=$($matches[1])", "listenport=$ListenPort") -Description "Delete portproxy $($matches[1])`:$ListenPort"
    }
  }
}

if (-not (Test-IsAdministrator)) {
  throw "Run this script from an elevated PowerShell session."
}

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$manifestPath = Join-Path $scriptRoot "manifest.json"
$manifest = Read-JsonFile -Path $manifestPath

$statePath = Join-Path (Join-Path $scriptRoot "state") "setup-state.json"
$state = $null
if (Test-Path -LiteralPath $statePath) {
  $state = Read-JsonFile -Path $statePath
}

if (Get-ScheduledTask -TaskName $manifest.refreshTaskName -ErrorAction SilentlyContinue) {
  Stop-ScheduledTask -TaskName $manifest.refreshTaskName -ErrorAction SilentlyContinue
  Unregister-ScheduledTask -TaskName $manifest.refreshTaskName -Confirm:$false
}

if (Get-ScheduledTask -TaskName $manifest.keepAliveTaskName -ErrorAction SilentlyContinue) {
  Stop-ScheduledTask -TaskName $manifest.keepAliveTaskName -ErrorAction SilentlyContinue
  Unregister-ScheduledTask -TaskName $manifest.keepAliveTaskName -Confirm:$false
}

if (Test-Path -LiteralPath $manifest.programDataScriptPath) {
  Remove-Item -LiteralPath $manifest.programDataScriptPath -Force
}

$logPath = "C:\ProgramData\WslSshLan\Update-WslSshLan.log"
if (Test-Path -LiteralPath $logPath) {
  Remove-Item -LiteralPath $logPath -Force
}

Get-NetFirewallRule -DisplayName "WSL SSH LAN 2222" -ErrorAction SilentlyContinue | Remove-NetFirewallRule
if ($state -and $state.listenAddress) {
  Remove-PortProxyForPort -ListenPort $manifest.sshPort -ListenAddress $state.listenAddress
} else {
  Remove-PortProxyForPort -ListenPort $manifest.sshPort
}

if (Test-DistroExists -DistroName $manifest.distroName) {
  Invoke-NativeCommand -FilePath "wsl.exe" -Arguments @("--terminate", $manifest.distroName) -Description "Terminate imported distro"
  Invoke-NativeCommand -FilePath "wsl.exe" -Arguments @("--unregister", $manifest.distroName) -Description "Unregister imported distro"
}

$installPath = Join-Path $scriptRoot $manifest.installPath
if (Test-Path -LiteralPath $installPath) {
  Remove-Item -LiteralPath $installPath -Recurse -Force
}

$wslConfigPath = Join-Path $env:USERPROFILE ".wslconfig"
if ($state -and $state.wslConfigCreated -and (Test-Path -LiteralPath $wslConfigPath)) {
  Remove-Item -LiteralPath $wslConfigPath -Force
}

if ($state -and $state.windowsSshd) {
  if ($state.windowsSshd.serviceExists) {
    if ($state.windowsSshd.startupType) {
      Set-Service sshd -StartupType $state.windowsSshd.startupType -ErrorAction SilentlyContinue
    }
    if ($state.windowsSshd.wasRunning) {
      Start-Service sshd -ErrorAction SilentlyContinue
    }
  }

  if ($null -ne $state.windowsSshd.previewRuleEnabled) {
    if ($state.windowsSshd.previewRuleEnabled -eq "True") {
      Enable-NetFirewallRule -DisplayName "OpenSSH SSH Server Preview (sshd)" -ErrorAction SilentlyContinue | Out-Null
    } else {
      Disable-NetFirewallRule -DisplayName "OpenSSH SSH Server Preview (sshd)" -ErrorAction SilentlyContinue | Out-Null
    }
  }

  if ($null -ne $state.windowsSshd.stableRuleEnabled) {
    if ($state.windowsSshd.stableRuleEnabled -eq "True") {
      Enable-NetFirewallRule -DisplayName "OpenSSH SSH Server (sshd)" -ErrorAction SilentlyContinue | Out-Null
    } else {
      Disable-NetFirewallRule -DisplayName "OpenSSH SSH Server (sshd)" -ErrorAction SilentlyContinue | Out-Null
    }
  }
}

if (Test-Path -LiteralPath $statePath) {
  Remove-Item -LiteralPath $statePath -Force
}

Write-Host "Uninstall complete."
