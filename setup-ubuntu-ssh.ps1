[CmdletBinding()]
param(
  [string]$ListenAddress
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Test-IsAdministrator {
  $currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
  $principal = [Security.Principal.WindowsPrincipal]::new($currentIdentity)
  return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-CurrentWindowsUser {
  return [Security.Principal.WindowsIdentity]::GetCurrent().Name
}

function Read-JsonFile {
  param([Parameter(Mandatory = $true)][string]$Path)
  return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
}

function Write-JsonFile {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)]$Object
  )

  $json = $Object | ConvertTo-Json -Depth 8
  Set-Content -LiteralPath $Path -Value $json -Encoding UTF8
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

function Get-RepositoryOriginUrl {
  param([Parameter(Mandatory = $true)][string]$RepositoryRoot)

  try {
    $originUrl = Invoke-NativeCommand -FilePath "git.exe" -Arguments @("-C", $RepositoryRoot, "remote", "get-url", "origin") -Description "Read git origin URL"
    return ($originUrl | Select-Object -First 1).Trim()
  } catch {
    return $null
  }
}

function Get-GitHubRepositoryInfo {
  param([Parameter(Mandatory = $true)][string]$OriginUrl)

  if ($OriginUrl -match "^https://github\.com/([^/]+)/([^/]+?)(?:\.git)?/?$") {
    return [pscustomobject]@{
      Owner = $matches[1]
      Repo = $matches[2]
    }
  }

  if ($OriginUrl -match "^git@github\.com:([^/]+)/([^/]+?)(?:\.git)?$") {
    return [pscustomobject]@{
      Owner = $matches[1]
      Repo = $matches[2]
    }
  }

  return $null
}

function Resolve-ReleaseAssetUrl {
  param(
    [Parameter(Mandatory = $true)][string]$RepositoryRoot,
    [Parameter(Mandatory = $true)]$Manifest
  )

  if ($Manifest.PSObject.Properties.Name -contains "imageDownloadUrl" -and -not [string]::IsNullOrWhiteSpace($Manifest.imageDownloadUrl)) {
    return $Manifest.imageDownloadUrl
  }

  $originUrl = Get-RepositoryOriginUrl -RepositoryRoot $RepositoryRoot
  if ([string]::IsNullOrWhiteSpace($originUrl)) {
    return $null
  }

  $repoInfo = Get-GitHubRepositoryInfo -OriginUrl $originUrl
  if (-not $repoInfo) {
    return $null
  }

  $assetName = if (
    $Manifest.PSObject.Properties.Name -contains "imageReleaseAssetName" -and
    -not [string]::IsNullOrWhiteSpace($Manifest.imageReleaseAssetName)
  ) {
    $Manifest.imageReleaseAssetName
  } else {
    Split-Path -Leaf $Manifest.imagePath
  }

  $releaseApiUrl = if (
    $Manifest.PSObject.Properties.Name -contains "imageReleaseTag" -and
    -not [string]::IsNullOrWhiteSpace($Manifest.imageReleaseTag)
  ) {
    "https://api.github.com/repos/$($repoInfo.Owner)/$($repoInfo.Repo)/releases/tags/$($Manifest.imageReleaseTag)"
  } else {
    "https://api.github.com/repos/$($repoInfo.Owner)/$($repoInfo.Repo)/releases/latest"
  }

  try {
    $release = Invoke-RestMethod -Uri $releaseApiUrl -Headers @{ "User-Agent" = "Codex-WSL-Setup" }
  } catch {
    throw "Could not read the GitHub release metadata from $releaseApiUrl. $($_.Exception.Message)"
  }

  $asset = $release.assets | Where-Object { $_.name -eq $assetName } | Select-Object -First 1
  if (-not $asset) {
    throw "Could not find release asset '$assetName' in the configured GitHub release."
  }

  return $asset.browser_download_url
}

function Ensure-ImagePresent {
  param(
    [Parameter(Mandatory = $true)][string]$ImagePath,
    [Parameter(Mandatory = $true)][string]$RepositoryRoot,
    [Parameter(Mandatory = $true)]$Manifest
  )

  if (Test-Path -LiteralPath $ImagePath) {
    return
  }

  $assetUrl = Resolve-ReleaseAssetUrl -RepositoryRoot $RepositoryRoot -Manifest $Manifest
  if ([string]::IsNullOrWhiteSpace($assetUrl)) {
    throw "Image not found: $ImagePath. No imageDownloadUrl was configured and no GitHub release asset could be resolved from origin."
  }

  New-Item -ItemType Directory -Path (Split-Path -Parent $ImagePath) -Force | Out-Null
  $downloadPath = "$ImagePath.download"
  if (Test-Path -LiteralPath $downloadPath) {
    Remove-Item -LiteralPath $downloadPath -Force
  }

  Write-Host "Downloading WSL image from $assetUrl"
  try {
    Invoke-WebRequest -Uri $assetUrl -OutFile $downloadPath -Headers @{ "User-Agent" = "Codex-WSL-Setup" }
    Move-Item -LiteralPath $downloadPath -Destination $ImagePath -Force
  } catch {
    if (Test-Path -LiteralPath $downloadPath) {
      Remove-Item -LiteralPath $downloadPath -Force -ErrorAction SilentlyContinue
    }
    throw "Failed to download the WSL image from $assetUrl. $($_.Exception.Message)"
  }
}

function Get-TrustedLanCandidates {
  return Get-NetIPConfiguration |
    Where-Object {
      $_.IPv4DefaultGateway -and
      $_.NetAdapter.Status -eq "Up" -and
      $_.IPv4Address.IPAddress -notlike "169.254.*" -and
      ($_.NetProfile.NetworkCategory -eq "Private" -or $_.NetProfile.NetworkCategory -eq "DomainAuthenticated")
    } |
    ForEach-Object {
      [pscustomobject]@{
        InterfaceAlias = $_.InterfaceAlias
        IPAddress = $_.IPv4Address.IPAddress
      }
    }
}

function Test-WslFeatureEnabled {
  $feature = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Windows-Subsystem-Linux
  return $feature.State -eq "Enabled"
}

function Test-VmpFeatureEnabled {
  $feature = Get-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform
  return $feature.State -eq "Enabled"
}

function Enable-WslFeaturesIfNeeded {
  $changes = $false

  if (-not (Test-WslFeatureEnabled)) {
    Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Windows-Subsystem-Linux -All -NoRestart | Out-Null
    $changes = $true
  }

  if (-not (Test-VmpFeatureEnabled)) {
    Enable-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform -All -NoRestart | Out-Null
    $changes = $true
  }

  return $changes
}

function Test-DistroExists {
  param([Parameter(Mandatory = $true)][string]$DistroName)

  $distros = Invoke-NativeCommand -FilePath "wsl.exe" -Arguments @("-l", "-q") -Description "List WSL distributions"
  if (-not $distros) {
    return $false
  }

  return [bool]($distros | Where-Object { $_.Trim() -eq $DistroName } | Select-Object -First 1)
}

function Test-TaskExists {
  param([Parameter(Mandatory = $true)][string]$TaskName)
  return [bool](Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue)
}

function Get-RefreshScriptContent {
  param(
    [Parameter(Mandatory = $true)][string]$DistroName,
    [Parameter(Mandatory = $true)][int]$Port,
    [Parameter(Mandatory = $true)][string]$ExpectedListenAddress
  )

@"
`$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Invoke-NativeCommand {
  param(
    [Parameter(Mandatory = `$true)][string]`$FilePath,
    [Parameter(Mandatory = `$true)][string[]]`$Arguments,
    [Parameter(Mandatory = `$true)][string]`$Description
  )

  `$output = & `$FilePath @Arguments 2>&1
  `$exitCode = `$LASTEXITCODE
  if (`$exitCode -ne 0) {
    `$message = @(`$output) -join [Environment]::NewLine
    throw "`$Description failed with exit code `$exitCode. `$message"
  }

  return `$output
}

`$Distro = "$DistroName"
`$Port = $Port
`$ExpectedListenAddress = "$ExpectedListenAddress"
`$LogPath = "C:\ProgramData\WslSshLan\Update-WslSshLan.log"
`$AllowRuleName = "WSL SSH LAN 2222"
`$LegacyBlockRuleName = "WSL SSH Block Non-LAN 2222"
`$LegacyPublicBlockRuleName = "WSL SSH Block Public 2222"

function Write-Log {
  param([Parameter(Mandatory = `$true)][string]`$Message)

  `$line = "{0} {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), `$Message
  Add-Content -LiteralPath `$LogPath -Value `$line
  Write-Host `$Message
}

function Get-PortProxyForPort {
  param(
    [Parameter(Mandatory = `$true)][string]`$ListenAddress,
    [Parameter(Mandatory = `$true)][int]`$ListenPort
  )

  `$escapedListenAddress = [regex]::Escape(`$ListenAddress)
  `$rows = Invoke-NativeCommand -FilePath "netsh.exe" -Arguments @("interface", "portproxy", "show", "v4tov4") -Description "List portproxy entries"
  foreach (`$row in `$rows) {
    if (`$row -match "^\s*(`$escapedListenAddress)\s+(`$ListenPort)\s+(\d{1,3}(?:\.\d{1,3}){3})\s+(\d+)\s*$") {
      return [pscustomobject]@{
        ListenAddress = `$matches[1]
        ListenPort = [int]`$matches[2]
        ConnectAddress = `$matches[3]
        ConnectPort = [int]`$matches[4]
      }
    }
  }

  return `$null
}

function Remove-PortProxyForPort {
  param(
    [Parameter(Mandatory = `$true)][string]`$ListenAddress,
    [Parameter(Mandatory = `$true)][int]`$ListenPort
  )

  `$escapedListenAddress = [regex]::Escape(`$ListenAddress)
  `$rows = Invoke-NativeCommand -FilePath "netsh.exe" -Arguments @("interface", "portproxy", "show", "v4tov4") -Description "List portproxy entries"
  foreach (`$row in `$rows) {
    if (`$row -match "^\s*(`$escapedListenAddress)\s+(`$ListenPort)\s+\d{1,3}(?:\.\d{1,3}){3}\s+\d+\s*$") {
      Invoke-NativeCommand -FilePath "netsh.exe" -Arguments @("interface", "portproxy", "delete", "v4tov4", "listenaddress=`$ListenAddress", "listenport=`$ListenPort") -Description "Delete portproxy `${ListenAddress}:`$ListenPort"
    }
  }
}

function Get-TrustedLanConfig {
  return Get-NetIPConfiguration |
    Where-Object {
      `$_.IPv4Address.IPAddress -eq `$ExpectedListenAddress -and
      `$_.IPv4DefaultGateway -and
      `$_.NetAdapter.Status -eq "Up" -and
      `$_.IPv4Address.IPAddress -notlike "169.254.*" -and
      (`$_.NetProfile.NetworkCategory -eq "Private" -or `$_.NetProfile.NetworkCategory -eq "DomainAuthenticated")
    } |
    Sort-Object -Property InterfaceIndex |
    Select-Object -First 1
}

New-Item -ItemType Directory -Path (Split-Path -Parent `$LogPath) -Force | Out-Null

`$lanConfig = Get-TrustedLanConfig
if (-not `$lanConfig) {
  throw "Could not find the expected trusted LAN address `$ExpectedListenAddress."
}

`$listenAddress = `$lanConfig.IPv4Address.IPAddress

Invoke-NativeCommand -FilePath "wsl.exe" -Arguments @("-d", `$Distro, "-u", "root", "--", "sh", "-lc", "systemctl disable --now ssh.socket >/dev/null 2>&1 || true; systemctl enable --now ssh.service >/dev/null 2>&1 || service ssh start >/dev/null 2>&1 || true") -Description "Prepare WSL ssh service"

`$wslAddress = Invoke-NativeCommand -FilePath "wsl.exe" -Arguments @("-d", `$Distro, "--", "sh", "-lc", "hostname -I | tr ' ' '\n' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -n 1") -Description "Read WSL IPv4 address"
if (-not `$wslAddress) {
  throw "Could not determine WSL IPv4 address."
}

`$listenCheck = Invoke-NativeCommand -FilePath "wsl.exe" -Arguments @("-d", `$Distro, "--", "sh", "-lc", "ss -ltnH '( sport = :`$Port )' 2>/dev/null | head -n 1") -Description "Verify WSL sshd listener"
if (-not `$listenCheck) {
  throw "WSL sshd is not listening on port `$Port."
}

Remove-NetFirewallRule -DisplayName `$LegacyBlockRuleName -ErrorAction SilentlyContinue
Remove-NetFirewallRule -DisplayName `$LegacyPublicBlockRuleName -ErrorAction SilentlyContinue

if (Get-Command Get-NetFirewallHyperVRule -ErrorAction SilentlyContinue) {
  Get-NetFirewallHyperVRule -DisplayName `$LegacyPublicBlockRuleName -ErrorAction SilentlyContinue | Remove-NetFirewallHyperVRule -ErrorAction SilentlyContinue
  Get-NetFirewallHyperVRule -DisplayName `$AllowRuleName -ErrorAction SilentlyContinue | Remove-NetFirewallHyperVRule -ErrorAction SilentlyContinue
}

`$portProxy = Get-PortProxyForPort -ListenAddress `$listenAddress -ListenPort `$Port
if (
  -not `$portProxy -or
  `$portProxy.ConnectAddress -ne `$wslAddress -or
  `$portProxy.ConnectPort -ne `$Port
) {
  Remove-PortProxyForPort -ListenAddress `$listenAddress -ListenPort `$Port
  Invoke-NativeCommand -FilePath "netsh.exe" -Arguments @("interface", "portproxy", "add", "v4tov4", "listenaddress=`$listenAddress", "listenport=`$Port", "connectaddress=`$wslAddress", "connectport=`$Port") -Description "Add portproxy `${listenAddress}:`$Port"
}

`$existingRule = Get-NetFirewallRule -DisplayName `$AllowRuleName -ErrorAction SilentlyContinue | Select-Object -First 1
`$ruleNeedsReplace = `$false

if (-not `$existingRule) {
  `$ruleNeedsReplace = `$true
} else {
  `$addressFilter = `$existingRule | Get-NetFirewallAddressFilter
  `$portFilter = `$existingRule | Get-NetFirewallPortFilter
  if (
    `$existingRule.Enabled -ne "True" -or
    `$existingRule.Direction -ne "Inbound" -or
    `$existingRule.Action -ne "Allow" -or
    `$existingRule.Profile -ne 3 -or
    `$addressFilter.LocalAddress -ne `$listenAddress -or
    `$addressFilter.RemoteAddress -ne "LocalSubnet" -or
    `$portFilter.Protocol -ne "TCP" -or
    `$portFilter.LocalPort -ne `$Port
  ) {
    `$ruleNeedsReplace = `$true
  }
}

if (`$ruleNeedsReplace) {
  Remove-NetFirewallRule -DisplayName `$AllowRuleName -ErrorAction SilentlyContinue
  New-NetFirewallRule `
    -DisplayName `$AllowRuleName `
    -Direction Inbound `
    -Action Allow `
    -Protocol TCP `
    -LocalAddress `$listenAddress `
    -LocalPort `$Port `
    -RemoteAddress LocalSubnet `
    -Profile Domain,Private | Out-Null
}

Write-Log "NAT WSL SSH ready on `${listenAddress}:`$Port -> `${wslAddress}:`$Port."
"@
}

function Restore-PartialSetup {
  param(
    [Parameter(Mandatory = $true)][bool]$RefreshTaskCreated,
    [Parameter(Mandatory = $true)][bool]$KeepAliveTaskCreated,
    [Parameter(Mandatory = $true)][bool]$ProgramDataScriptCreated,
    [Parameter(Mandatory = $true)][bool]$WslConfigCreated,
    [Parameter(Mandatory = $true)][bool]$WslImported,
    [Parameter(Mandatory = $true)][bool]$SshdStateChanged,
    [Parameter(Mandatory = $true)][bool]$FirewallRulesChanged,
    [Parameter(Mandatory = $true)][bool]$SshdServiceExists,
    [Parameter(Mandatory = $true)]$SshdStartupType,
    [Parameter(Mandatory = $true)][bool]$SshdWasRunning,
    [Parameter(Mandatory = $true)]$PreviewRuleEnabled,
    [Parameter(Mandatory = $true)]$StableRuleEnabled,
    [Parameter(Mandatory = $true)][string]$DistroName,
    [Parameter(Mandatory = $true)][string]$ProgramDataScriptPath,
    [Parameter(Mandatory = $true)][string]$WslConfigPath,
    [Parameter(Mandatory = $true)][string]$InstallPath,
    [Parameter(Mandatory = $true)][string]$RefreshTaskName,
    [Parameter(Mandatory = $true)][string]$KeepAliveTaskName
  )

  if ($RefreshTaskCreated -and (Get-ScheduledTask -TaskName $RefreshTaskName -ErrorAction SilentlyContinue)) {
    Stop-ScheduledTask -TaskName $RefreshTaskName -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $RefreshTaskName -Confirm:$false -ErrorAction SilentlyContinue
  }

  if ($KeepAliveTaskCreated -and (Get-ScheduledTask -TaskName $KeepAliveTaskName -ErrorAction SilentlyContinue)) {
    Stop-ScheduledTask -TaskName $KeepAliveTaskName -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $KeepAliveTaskName -Confirm:$false -ErrorAction SilentlyContinue
  }

  if ($ProgramDataScriptCreated -and (Test-Path -LiteralPath $ProgramDataScriptPath)) {
    Remove-Item -LiteralPath $ProgramDataScriptPath -Force -ErrorAction SilentlyContinue
  }

  if ($WslConfigCreated -and (Test-Path -LiteralPath $WslConfigPath)) {
    Remove-Item -LiteralPath $WslConfigPath -Force -ErrorAction SilentlyContinue
  }

  if ($WslImported -and (Test-DistroExists -DistroName $DistroName)) {
    Invoke-NativeCommand -FilePath "wsl.exe" -Arguments @("--terminate", $DistroName) -Description "Terminate imported distro"
    Invoke-NativeCommand -FilePath "wsl.exe" -Arguments @("--unregister", $DistroName) -Description "Unregister imported distro"
  }

  if (Test-Path -LiteralPath $InstallPath) {
    Remove-Item -LiteralPath $InstallPath -Recurse -Force -ErrorAction SilentlyContinue
  }

  if ($SshdStateChanged -and $SshdServiceExists) {
    if ($SshdStartupType) {
      Set-Service sshd -StartupType $SshdStartupType -ErrorAction SilentlyContinue
    }

    if ($SshdWasRunning) {
      Start-Service sshd -ErrorAction SilentlyContinue
    }
  }

  if ($FirewallRulesChanged) {
    if ($null -ne $PreviewRuleEnabled) {
      if ($PreviewRuleEnabled -eq "True") {
        Enable-NetFirewallRule -DisplayName "OpenSSH SSH Server Preview (sshd)" -ErrorAction SilentlyContinue | Out-Null
      } else {
        Disable-NetFirewallRule -DisplayName "OpenSSH SSH Server Preview (sshd)" -ErrorAction SilentlyContinue | Out-Null
      }
    }

    if ($null -ne $StableRuleEnabled) {
      if ($StableRuleEnabled -eq "True") {
        Enable-NetFirewallRule -DisplayName "OpenSSH SSH Server (sshd)" -ErrorAction SilentlyContinue | Out-Null
      } else {
        Disable-NetFirewallRule -DisplayName "OpenSSH SSH Server (sshd)" -ErrorAction SilentlyContinue | Out-Null
      }
    }
  }
}

if (-not (Test-IsAdministrator)) {
  throw "Run this script from an elevated PowerShell session."
}

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$manifestPath = Join-Path $scriptRoot "manifest.json"
$manifest = Read-JsonFile -Path $manifestPath

$imagePath = Join-Path $scriptRoot $manifest.imagePath
$installPath = Join-Path $scriptRoot $manifest.installPath
$stateDir = Join-Path $scriptRoot "state"
$statePath = Join-Path $stateDir "setup-state.json"
$programDataDir = Split-Path -Parent $manifest.programDataScriptPath
$programDataScriptPath = $manifest.programDataScriptPath
$wslConfigPath = Join-Path $env:USERPROFILE ".wslconfig"

$rebootNeeded = Enable-WslFeaturesIfNeeded
if ($rebootNeeded) {
  Write-Host "WSL or VirtualMachinePlatform was enabled. Reboot Windows, then rerun this script."
  exit 0
}

$currentUser = $null
$wslImported = $false
$wslConfigCreated = $false
$programDataScriptCreated = $false
$refreshTaskCreated = $false
$keepAliveTaskCreated = $false
$sshdStateChanged = $false
$firewallRulesChanged = $false
$sshdServiceExists = $false
$sshdStartupType = $null
$sshdWasRunning = $false
$previewRuleEnabled = $null
$stableRuleEnabled = $null

if (Test-DistroExists -DistroName $manifest.distroName) {
  throw "A distro named '$($manifest.distroName)' already exists. Setup stops on conflicts."
}

if (Test-Path -LiteralPath $wslConfigPath) {
  throw "An existing .wslconfig was found at $wslConfigPath. Setup stops on conflicts."
}

if (Test-TaskExists -TaskName $manifest.refreshTaskName) {
  throw "A scheduled task named '$($manifest.refreshTaskName)' already exists. Setup stops on conflicts."
}

if (Test-TaskExists -TaskName $manifest.keepAliveTaskName) {
  throw "A scheduled task named '$($manifest.keepAliveTaskName)' already exists. Setup stops on conflicts."
}

if (Test-Path -LiteralPath $programDataScriptPath) {
  throw "An existing ProgramData refresh script was found at $programDataScriptPath. Setup stops on conflicts."
}

if ([string]::IsNullOrWhiteSpace($ListenAddress)) {
  $candidates = @(Get-TrustedLanCandidates)
  if ($candidates.Count -ne 1) {
    $details = $candidates | ForEach-Object { "$($_.InterfaceAlias): $($_.IPAddress)" }
    throw "Could not auto-select a unique trusted LAN IPv4. Rerun with -ListenAddress. Candidates: $($details -join '; ')"
  }
  $ListenAddress = $candidates[0].IPAddress
} else {
  $matchedCandidate = Get-TrustedLanCandidates | Where-Object { $_.IPAddress -eq $ListenAddress } | Select-Object -First 1
  if (-not $matchedCandidate) {
    throw "ListenAddress '$ListenAddress' is not an active trusted LAN IPv4 on this machine."
  }
}

New-Item -ItemType Directory -Path (Split-Path -Parent $imagePath) -Force | Out-Null
New-Item -ItemType Directory -Path (Split-Path -Parent $installPath) -Force | Out-Null
New-Item -ItemType Directory -Path $stateDir -Force | Out-Null

Ensure-ImagePresent -ImagePath $imagePath -RepositoryRoot $scriptRoot -Manifest $manifest

try {
  Invoke-NativeCommand -FilePath "wsl.exe" -Arguments @("--import", $manifest.distroName, $installPath, $imagePath, "--version", "2") -Description "Import WSL distro"
  $wslImported = $true
  Invoke-NativeCommand -FilePath "wsl.exe" -Arguments @("--set-default", $manifest.distroName) -Description "Set default WSL distro"
  Invoke-NativeCommand -FilePath "wsl.exe" -Arguments @("--manage", $manifest.distroName, "--set-default-user", $manifest.linuxUser) -Description "Set default WSL user"

  $sshdService = Get-Service sshd -ErrorAction SilentlyContinue
  $sshdServiceExists = $null -ne $sshdService
  if ($sshdServiceExists) {
    $sshdStartupType = $sshdService.StartType.ToString()
    $sshdWasRunning = $sshdService.Status -eq "Running"
    Stop-Service sshd -ErrorAction SilentlyContinue
    Set-Service sshd -StartupType Disabled -ErrorAction SilentlyContinue
    $sshdStateChanged = $true
  }

  $previewRule = Get-NetFirewallRule -DisplayName "OpenSSH SSH Server Preview (sshd)" -ErrorAction SilentlyContinue | Select-Object -First 1
  $stableRule = Get-NetFirewallRule -DisplayName "OpenSSH SSH Server (sshd)" -ErrorAction SilentlyContinue | Select-Object -First 1
  $previewRuleEnabled = if ($previewRule) { $previewRule.Enabled.ToString() } else { $null }
  $stableRuleEnabled = if ($stableRule) { $stableRule.Enabled.ToString() } else { $null }
  if ($previewRule) {
    Disable-NetFirewallRule -DisplayName "OpenSSH SSH Server Preview (sshd)" | Out-Null
    $firewallRulesChanged = $true
  }
  if ($stableRule) {
    Disable-NetFirewallRule -DisplayName "OpenSSH SSH Server (sshd)" | Out-Null
    $firewallRulesChanged = $true
  }

  New-Item -ItemType Directory -Path $programDataDir -Force | Out-Null
  $refreshScript = Get-RefreshScriptContent -DistroName $manifest.distroName -Port $manifest.sshPort -ExpectedListenAddress $ListenAddress
  Set-Content -LiteralPath $programDataScriptPath -Value $refreshScript -Encoding UTF8
  $programDataScriptCreated = $true

  Set-Content -LiteralPath $wslConfigPath -Value @(
    "[wsl2]",
    "networkingMode=nat",
    "firewall=true"
  ) -Encoding ASCII
  $wslConfigCreated = $true

  $currentUser = Get-CurrentWindowsUser
  $refreshAction = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$programDataScriptPath`""
  $refreshBootTrigger = New-ScheduledTaskTrigger -AtStartup
  $refreshBootTrigger.Delay = "PT30S"
  $refreshLogonTrigger = New-ScheduledTaskTrigger -AtLogOn -User $currentUser
  $refreshLogonTrigger.Delay = "PT30S"
  $refreshPrincipal = New-ScheduledTaskPrincipal -UserId $currentUser -LogonType S4U -RunLevel Highest
  $refreshSettings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
  Register-ScheduledTask -TaskName $manifest.refreshTaskName -Action $refreshAction -Trigger @($refreshBootTrigger, $refreshLogonTrigger) -Principal $refreshPrincipal -Settings $refreshSettings -Force | Out-Null
  $refreshTaskCreated = $true

  $keepAliveAction = New-ScheduledTaskAction -Execute "wsl.exe" -Argument "-d $($manifest.distroName) --exec /bin/sleep infinity"
  $keepAliveBootTrigger = New-ScheduledTaskTrigger -AtStartup
  $keepAliveBootTrigger.Delay = "PT20S"
  $keepAliveLogonTrigger = New-ScheduledTaskTrigger -AtLogOn -User $currentUser
  $keepAliveLogonTrigger.Delay = "PT20S"
  $keepAlivePrincipal = New-ScheduledTaskPrincipal -UserId $currentUser -LogonType S4U
  $keepAliveSettings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew
  Register-ScheduledTask -TaskName $manifest.keepAliveTaskName -Action $keepAliveAction -Trigger @($keepAliveBootTrigger, $keepAliveLogonTrigger) -Principal $keepAlivePrincipal -Settings $keepAliveSettings -Force | Out-Null
  $keepAliveTaskCreated = $true

  Start-ScheduledTask -TaskName $manifest.keepAliveTaskName
  Start-Sleep -Seconds 2
  Start-ScheduledTask -TaskName $manifest.refreshTaskName
  Start-Sleep -Seconds 5

  $state = [ordered]@{
    windowsUser = $currentUser
    listenAddress = $ListenAddress
    distroName = $manifest.distroName
    linuxUser = $manifest.linuxUser
    imagePath = $imagePath
    installPath = $installPath
    refreshTaskName = $manifest.refreshTaskName
    keepAliveTaskName = $manifest.keepAliveTaskName
    programDataScriptPath = $programDataScriptPath
    wslConfigCreated = $true
    setupTimeUtc = (Get-Date).ToUniversalTime().ToString("o")
    windowsSshd = [ordered]@{
      serviceExists = $sshdServiceExists
      startupType = $sshdStartupType
      wasRunning = $sshdWasRunning
      previewRuleEnabled = $previewRuleEnabled
      stableRuleEnabled = $stableRuleEnabled
    }
  }
  Write-JsonFile -Path $statePath -Object $state

  Write-Host "Setup complete."
  Write-Host "ListenAddress: $ListenAddress"
  Write-Host "Distro: $($manifest.distroName)"
  Write-Host "SSH: ssh -p $($manifest.sshPort) $($manifest.linuxUser)@$ListenAddress"
}
catch {
  try {
    Restore-PartialSetup `
      -RefreshTaskCreated $refreshTaskCreated `
      -KeepAliveTaskCreated $keepAliveTaskCreated `
      -ProgramDataScriptCreated $programDataScriptCreated `
      -WslConfigCreated $wslConfigCreated `
      -WslImported $wslImported `
      -SshdStateChanged $sshdStateChanged `
      -FirewallRulesChanged $firewallRulesChanged `
      -SshdServiceExists $sshdServiceExists `
      -SshdStartupType $sshdStartupType `
      -SshdWasRunning $sshdWasRunning `
      -PreviewRuleEnabled $previewRuleEnabled `
      -StableRuleEnabled $stableRuleEnabled `
      -DistroName $manifest.distroName `
      -ProgramDataScriptPath $programDataScriptPath `
      -WslConfigPath $wslConfigPath `
      -InstallPath $installPath `
      -RefreshTaskName $manifest.refreshTaskName `
      -KeepAliveTaskName $manifest.keepAliveTaskName
  } catch {
    Write-Warning "Rollback encountered an issue: $($_.Exception.Message)"
  }
  throw
}
