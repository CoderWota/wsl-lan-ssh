[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Initialize-Utf8Output {
  $utf8 = [System.Text.UTF8Encoding]::new($false)
  try {
    [Console]::InputEncoding = $utf8
    [Console]::OutputEncoding = $utf8
  } catch {
    Write-Verbose "Console UTF-8 initialization was skipped. $($_.Exception.Message)"
  }
  Set-Variable -Scope Script -Name OutputEncoding -Value $utf8
  if (-not (Get-Variable -Scope Script -Name PSDefaultParameterValues -ErrorAction SilentlyContinue)) {
    Set-Variable -Scope Script -Name PSDefaultParameterValues -Value @{}
  }
  $script:PSDefaultParameterValues["Out-File:Encoding"] = "utf8"
  $script:PSDefaultParameterValues["Set-Content:Encoding"] = "utf8"
  $script:PSDefaultParameterValues["Add-Content:Encoding"] = "utf8"
}

Initialize-Utf8Output

function Test-IsAdministrator {
  $currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
  $principal = [Security.Principal.WindowsPrincipal]::new($currentIdentity)
  return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Read-JsonFile {
  param([Parameter(Mandatory = $true)][string]$Path)
  return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Write-Utf8TextFile {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text
  )

  [System.IO.File]::WriteAllText($Path, $Text, [System.Text.UTF8Encoding]::new($false))
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

function Test-DistroPresent {
  param([Parameter(Mandatory = $true)][string]$DistroName)

  try {
    $distros = Invoke-NativeCommand -FilePath "wsl.exe" -Arguments @("-l", "-q") -Description "List WSL distributions"
  } catch {
    Write-Verbose "WSL distribution list is unavailable."
    return $false
  }
  if (-not $distros) {
    return $false
  }

  return [bool]($distros | Where-Object { $_.Trim() -eq $DistroName } | Select-Object -First 1)
}

function Remove-PortProxyForPort {
  [CmdletBinding(SupportsShouldProcess = $true)]
  param(
    [Parameter(Mandatory = $true)][int]$ListenPort,
    [string]$ListenAddress
  )

  $rows = Invoke-NativeCommand -FilePath "netsh.exe" -Arguments @("interface", "portproxy", "show", "v4tov4") -Description "List portproxy entries"
  foreach ($row in $rows) {
    if ($ListenAddress) {
      $escapedListenAddress = [regex]::Escape($ListenAddress)
      if ($row -match "^\s*($escapedListenAddress)\s+($ListenPort)\s+\d{1,3}(?:\.\d{1,3}){3}\s+\d+\s*$") {
        if ($PSCmdlet.ShouldProcess("$ListenAddress`:$ListenPort", "Delete portproxy")) {
          Invoke-NativeCommand -FilePath "netsh.exe" -Arguments @("interface", "portproxy", "delete", "v4tov4", "listenaddress=$ListenAddress", "listenport=$ListenPort") -Description "Delete portproxy $ListenAddress`:$ListenPort"
        }
      }
      continue
    }

    if ($row -match "^\s*(\d{1,3}(?:\.\d{1,3}){3})\s+($ListenPort)\s+\d{1,3}(?:\.\d{1,3}){3}\s+\d+\s*$") {
      if ($PSCmdlet.ShouldProcess("$($matches[1]):$ListenPort", "Delete portproxy")) {
        Invoke-NativeCommand -FilePath "netsh.exe" -Arguments @("interface", "portproxy", "delete", "v4tov4", "listenaddress=$($matches[1])", "listenport=$ListenPort") -Description "Delete portproxy $($matches[1])`:$ListenPort"
      }
    }
  }
}

function Get-FirewallRuleDisplayName {
  param([Parameter(Mandatory = $true)][int]$Port)

  return "WSL SSH LAN $Port"
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

if (Get-ScheduledTask -TaskName $manifest.relayTaskName -ErrorAction SilentlyContinue) {
  Stop-ScheduledTask -TaskName $manifest.relayTaskName -ErrorAction SilentlyContinue
  Unregister-ScheduledTask -TaskName $manifest.relayTaskName -Confirm:$false
}

if (Test-Path -LiteralPath $manifest.programDataScriptPath) {
  Remove-Item -LiteralPath $manifest.programDataScriptPath -Force
}

$legacyProgramDataScriptPath = Join-Path (Split-Path -Parent $manifest.programDataScriptPath) "Update-WslSshLan.ps1"
if ($legacyProgramDataScriptPath -ne $manifest.programDataScriptPath -and (Test-Path -LiteralPath $legacyProgramDataScriptPath)) {
  Remove-Item -LiteralPath $legacyProgramDataScriptPath -Force
}

$logPaths = @(
  "C:\ProgramData\WslSshLan\WslSshRelay.log",
  "C:\ProgramData\WslSshLan\Update-WslSshLan.log"
)
foreach ($logPath in $logPaths) {
  if (Test-Path -LiteralPath $logPath) {
    Remove-Item -LiteralPath $logPath -Force
  }
}

Get-NetFirewallRule -DisplayName (Get-FirewallRuleDisplayName -Port $manifest.sshPort) -ErrorAction SilentlyContinue | Remove-NetFirewallRule
if ($state -and $state.listenAddress) {
  Remove-PortProxyForPort -ListenPort $manifest.sshPort -ListenAddress $state.listenAddress
} else {
  Remove-PortProxyForPort -ListenPort $manifest.sshPort
}

if (Test-DistroPresent -DistroName $manifest.distroName) {
  Invoke-NativeCommand -FilePath "wsl.exe" -Arguments @("--terminate", $manifest.distroName) -Description "Terminate WSL distro"
  Invoke-NativeCommand -FilePath "wsl.exe" -Arguments @("--unregister", $manifest.distroName) -Description "Unregister WSL distro"
}

$wslConfigPath = Join-Path $env:USERPROFILE ".wslconfig"
if ($state -and $state.wslConfigCreated) {
  if (($state.PSObject.Properties.Name -contains "wslConfigHadExistingFile") -and $state.wslConfigHadExistingFile) {
    $backupContent = if ($state.PSObject.Properties.Name -contains "wslConfigBackupContent") { [string]$state.wslConfigBackupContent } else { "" }
    Write-Utf8TextFile -Path $wslConfigPath -Text $backupContent
  } elseif (Test-Path -LiteralPath $wslConfigPath) {
    Remove-Item -LiteralPath $wslConfigPath -Force
  }
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

Write-Output "Uninstall complete."
