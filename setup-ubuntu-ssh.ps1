[CmdletBinding()]
param(
  [string]$ListenAddress
)

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

function Get-CurrentWindowsUser {
  return [Security.Principal.WindowsIdentity]::GetCurrent().Name
}

function Read-JsonFile {
  param([Parameter(Mandatory = $true)][string]$Path)
  return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Write-JsonFile {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)]$Object
  )

  $json = $Object | ConvertTo-Json -Depth 8
  [System.IO.File]::WriteAllText($Path, $json, [System.Text.UTF8Encoding]::new($false))
}

function Read-TextFileIfPresent {
  param([Parameter(Mandatory = $true)][string]$Path)

  if (-not (Test-Path -LiteralPath $Path)) {
    return $null
  }

  return Get-Content -LiteralPath $Path -Raw -Encoding UTF8
}

function Write-Utf8TextFile {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text
  )

  [System.IO.File]::WriteAllText($Path, $Text, [System.Text.UTF8Encoding]::new($false))
}

function ConvertTo-TemplateTokenValue {
  param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text)

  return $Text.Replace('"', '""')
}

function ConvertTo-LinuxSingleQuotedText {
  param([Parameter(Mandatory = $true)][string]$Text)

  return "'" + ($Text -replace "'", "'""'""'") + "'"
}

function Invoke-NativeCommand {
  param(
    [Parameter(Mandatory = $true)][string]$FilePath,
    [Parameter(Mandatory = $true)][string[]]$Arguments,
    [Parameter(Mandatory = $true)][string]$Description,
    [string]$InputText
  )

  $output = if ($PSBoundParameters.ContainsKey("InputText")) {
    $InputText | & $FilePath @Arguments 2>&1
  } else {
    & $FilePath @Arguments 2>&1
  }
  $exitCode = $LASTEXITCODE
  if ($exitCode -ne 0) {
    $message = @($output) -join [Environment]::NewLine
    throw "$Description failed with exit code $exitCode. $message"
  }

  return $output
}

function Test-LinuxPathPresent {
  param(
    [Parameter(Mandatory = $true)][string]$DistroName,
    [Parameter(Mandatory = $true)][string]$Path
  )

  try {
    Invoke-NativeCommand -FilePath "wsl.exe" -Arguments @("--distribution", $DistroName, "--user", "root", "--exec", "/bin/test", "-f", $Path) -Description "Check Linux path '$Path'"
    return $true
  } catch {
    Write-Verbose "Linux path '$Path' is not present in distro '$DistroName'."
    return $false
  }
}

function Read-LinuxTextFile {
  param(
    [Parameter(Mandatory = $true)][string]$DistroName,
    [Parameter(Mandatory = $true)][string]$Path
  )

  $content = Invoke-NativeCommand -FilePath "wsl.exe" -Arguments @("--distribution", $DistroName, "--user", "root", "--exec", "/bin/cat", $Path) -Description "Read Linux file '$Path'"
  return (@($content) -join [Environment]::NewLine)
}

function Write-LinuxTextFile {
  param(
    [Parameter(Mandatory = $true)][string]$DistroName,
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$Text,
    [string]$DirectoryMode,
    [string]$FileMode
  )

  $directory = if ($Path -match '^(.+)/[^/]+$') { $matches[1] } else { "." }
  $quotedDirectory = ConvertTo-LinuxSingleQuotedText -Text $directory
  $quotedPath = ConvertTo-LinuxSingleQuotedText -Text $Path
  $shellCommand = "umask 077; /bin/mkdir -p $quotedDirectory"
  if ($PSBoundParameters.ContainsKey("DirectoryMode") -and -not [string]::IsNullOrWhiteSpace($DirectoryMode)) {
    $shellCommand += "; /bin/chmod $DirectoryMode $quotedDirectory"
  }
  $shellCommand += "; /bin/cat > $quotedPath"
  if ($PSBoundParameters.ContainsKey("FileMode") -and -not [string]::IsNullOrWhiteSpace($FileMode)) {
    $shellCommand += "; /bin/chmod $FileMode $quotedPath"
  }
  Invoke-NativeCommand -FilePath "wsl.exe" -Arguments @("--distribution", $DistroName, "--user", "root", "--exec", "/bin/sh", "-c", $shellCommand) -InputText $Text -Description "Write Linux file '$Path'"
}

function Get-DefaultSetupProfile {
  param([Parameter(Mandatory = $true)][string]$DefaultLinuxUser)

  return [ordered]@{
    linuxUser = $DefaultLinuxUser
    linuxPassword = "Wsl-" + ([Guid]::NewGuid().ToString("N"))
  }
}

function Read-OrCreate-SetupProfile {
  param(
    [Parameter(Mandatory = $true)][string]$DistroName,
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$DefaultLinuxUser
  )

  $defaults = Get-DefaultSetupProfile -DefaultLinuxUser $DefaultLinuxUser

  $config = $null
  if (Test-LinuxPathPresent -DistroName $DistroName -Path $Path) {
    try {
      $config = Read-LinuxTextFile -DistroName $DistroName -Path $Path | ConvertFrom-Json
    } catch {
      throw "Could not read setup credentials from $Path inside distro '$DistroName'. $($_.Exception.Message)"
    }
  }

  $linuxUser = if ($config -and ($config.PSObject.Properties.Name -contains "linuxUser") -and -not [string]::IsNullOrWhiteSpace($config.linuxUser)) {
    [string]$config.linuxUser
  } else {
    $defaults.linuxUser
  }

  $loginSecretText = if ($config -and ($config.PSObject.Properties.Name -contains "linuxPassword") -and -not [string]::IsNullOrWhiteSpace($config.linuxPassword)) {
    [string]$config.linuxPassword
  } else {
    $defaults.linuxPassword
  }

  if ($linuxUser -notmatch '^[a-z_][a-z0-9_-]*$') {
    throw "linuxUser in $Path must match the standard Linux account pattern [a-z_][a-z0-9_-]*."
  }

  if ($loginSecretText -match "[\r\n:]") {
    throw "linuxPassword in $Path cannot contain a colon or newline."
  }

  $normalizedConfig = [ordered]@{
    linuxUser = $linuxUser
    linuxPassword = $loginSecretText
  }

  $shouldWrite = -not $config
  if ($config) {
    $shouldWrite = $shouldWrite -or -not ($config.PSObject.Properties.Name -contains "linuxUser") -or -not ($config.PSObject.Properties.Name -contains "linuxPassword")
    $shouldWrite = $shouldWrite -or ($config.linuxUser -ne $linuxUser) -or ($config.linuxPassword -ne $loginSecretText)
  }

  if ($shouldWrite) {
    $json = $normalizedConfig | ConvertTo-Json -Depth 8 -Compress
    Write-LinuxTextFile -DistroName $DistroName -Path $Path -Text $json -DirectoryMode "700" -FileMode "600"
  }

  return [pscustomobject]@{
    Path = $Path
    LinuxUser = $linuxUser
    LinuxPassword = $loginSecretText
    Created = -not $config
    Updated = $shouldWrite -and $config
  }
}

function Convert-PlainTextToSecureString {
  param([Parameter(Mandatory = $true)][string]$Text)

  $secure = [System.Security.SecureString]::new()
  foreach ($character in $Text.ToCharArray()) {
    $secure.AppendChar($character)
  }

  $secure.MakeReadOnly()
  return $secure
}

function Convert-SecureStringToPlainText {
  param([Parameter(Mandatory = $true)][securestring]$SecureString)

  $bstr = [System.IntPtr]::Zero
  try {
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureString)
    return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
  } finally {
    if ($bstr -ne [System.IntPtr]::Zero) {
      [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
  }
}

function Test-LinuxUserPresent {
  param(
    [Parameter(Mandatory = $true)][string]$DistroName,
    [Parameter(Mandatory = $true)][string]$LinuxUser
  )

  try {
    Invoke-NativeCommand -FilePath "wsl.exe" -Arguments @("--distribution", $DistroName, "--user", "root", "--exec", "/usr/bin/id", "-u", $LinuxUser) -Description "Check Linux user '$LinuxUser'"
    return $true
  } catch {
    Write-Verbose "Linux user '$LinuxUser' is not present in distro '$DistroName'."
    return $false
  }
}

function Set-LinuxUserConfigured {
  [CmdletBinding(SupportsShouldProcess = $true)]
  param(
    [Parameter(Mandatory = $true)][string]$DistroName,
    [Parameter(Mandatory = $true)][string]$LinuxUser,
    [Parameter(Mandatory = $true)][securestring]$PasswordSecure
  )

  if ($PSCmdlet.ShouldProcess($LinuxUser, "Configure Linux user in $DistroName")) {
    $plainPassword = Convert-SecureStringToPlainText -SecureString $PasswordSecure
    if (-not (Test-LinuxUserPresent -DistroName $DistroName -LinuxUser $LinuxUser)) {
      Invoke-NativeCommand -FilePath "wsl.exe" -Arguments @("--distribution", $DistroName, "--user", "root", "--exec", "/usr/sbin/useradd", "--create-home", "--shell", "/bin/bash", "--groups", "sudo", $LinuxUser) -Description "Create Linux user '$LinuxUser'"
    } else {
      Invoke-NativeCommand -FilePath "wsl.exe" -Arguments @("--distribution", $DistroName, "--user", "root", "--exec", "/usr/sbin/usermod", "--shell", "/bin/bash", "--append", "--groups", "sudo", $LinuxUser) -Description "Refresh Linux user '$LinuxUser'"
    }

    Invoke-NativeCommand -FilePath "wsl.exe" -Arguments @("--distribution", $DistroName, "--user", "root", "--exec", "/usr/sbin/chpasswd") -InputText ("{0}:{1}" -f $LinuxUser, $plainPassword) -Description "Set password for Linux user '$LinuxUser'"
  }
}

function Get-LinuxWslConfigContent {
  param(
    [Parameter(Mandatory = $true)][string]$DefaultLinuxUser,
    [Parameter(Mandatory = $true)][AllowEmptyString()][string[]]$TemplateLines
  )

  return $TemplateLines | ForEach-Object {
    $_.Replace("__DEFAULT_LINUX_USER__", $DefaultLinuxUser)
  }
}

function Get-LinuxSshdConfigContent {
  param(
    [Parameter(Mandatory = $true)][int]$Port,
    [Parameter(Mandatory = $true)][string]$LinuxUser,
    [Parameter(Mandatory = $true)][AllowEmptyString()][string[]]$TemplateLines
  )

  return $TemplateLines | ForEach-Object {
    $_.
      Replace("__SSH_PORT__", $Port.ToString()).
      Replace("__DEFAULT_LINUX_USER__", $LinuxUser)
  }
}

function Install-WslUbuntuDistro {
  param([Parameter(Mandatory = $true)][string]$DistroName)

  if (Test-DistroPresent -DistroName $DistroName) {
    try {
      Invoke-NativeCommand -FilePath "wsl.exe" -Arguments @("--distribution", $DistroName, "--exec", "/bin/true") -Description "Probe WSL distro '$DistroName'"
      return [pscustomobject]@{
        InstalledNow = $false
        NeedsReboot = $false
      }
    } catch {
      $probeMessage = $_.Exception.Message
      if ($probeMessage -match "ERROR_PATH_NOT_FOUND|ext4\.vhdx|path\s+not\s+found|MountDisk") {
        Write-Output "Existing WSL distro '$DistroName' is registered but its disk is missing. Reinstalling it."
        Invoke-NativeCommand -FilePath "wsl.exe" -Arguments @("--unregister", $DistroName) -Description "Unregister stale WSL distro '$DistroName'"
      } else {
        throw "Existing WSL distro '$DistroName' is registered but not usable. $probeMessage"
      }
    }
  }

  Invoke-NativeCommand -FilePath "wsl.exe" -Arguments @("--install", "-d", $DistroName, "--web-download", "--no-launch") -Description "Install WSL distro '$DistroName'" | Out-Null

  return [pscustomobject]@{
    InstalledNow = $true
    NeedsReboot = -not (Test-DistroPresent -DistroName $DistroName)
  }
}

function Install-OpenSshServerIfMissing {
  param([Parameter(Mandatory = $true)][string]$DistroName)

  try {
    Invoke-NativeCommand -FilePath "wsl.exe" -Arguments @("--distribution", $DistroName, "--user", "root", "--exec", "/usr/bin/dpkg", "-s", "openssh-server") -Description "Check OpenSSH server package"
    return $false
  } catch {
    Write-Verbose "OpenSSH server package is not installed in distro '$DistroName'. Installing it now."
  }

  Invoke-NativeCommand -FilePath "wsl.exe" -Arguments @("--distribution", $DistroName, "--user", "root", "--exec", "/usr/bin/apt-get", "update") -Description "Update Linux package lists"
  Invoke-NativeCommand -FilePath "wsl.exe" -Arguments @("--distribution", $DistroName, "--user", "root", "--exec", "/usr/bin/env", "DEBIAN_FRONTEND=noninteractive", "/usr/bin/apt-get", "install", "-y", "openssh-server") -Description "Install OpenSSH server"
  return $true
}

function Initialize-LinuxBootstrapConfiguration {
  param(
    [Parameter(Mandatory = $true)][string]$DistroName,
    [Parameter(Mandatory = $true)][string]$LinuxUser,
    [Parameter(Mandatory = $true)][int]$SshPort,
    [Parameter(Mandatory = $true)]$SecurityProfile
  )

  $wslConfigText = [string]::Join([Environment]::NewLine, (Get-LinuxWslConfigContent -DefaultLinuxUser $LinuxUser -TemplateLines ([string[]]$SecurityProfile.wslConfTemplateLines)))
  Write-LinuxTextFile -DistroName $DistroName -Path "/etc/wsl.conf" -Text $wslConfigText -FileMode "644"

  $sshConfigText = [string]::Join([Environment]::NewLine, (Get-LinuxSshdConfigContent -Port $SshPort -LinuxUser $LinuxUser -TemplateLines ([string[]]$SecurityProfile.sshdTemplateLines)))
  Write-LinuxTextFile -DistroName $DistroName -Path "/etc/ssh/sshd_config.d/99-wsl-ssh-lan.conf" -Text $sshConfigText -FileMode "644"
}

function Get-TrustedLanCandidate {
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
        InterfaceIndex = $_.InterfaceIndex
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

function Test-TaskPresent {
  param([Parameter(Mandatory = $true)][string]$TaskName)
  return [bool](Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue)
}

function Get-WslConfigContent {
  param(
    [Parameter(Mandatory = $true)][string]$MemoryLimit,
    [Parameter(Mandatory = $true)][int]$VmIdleTimeoutMs
  )

  return @(
    "[wsl2]",
    "memory=$MemoryLimit",
    "networkingMode=nat",
    "firewall=true",
    "vmIdleTimeout=$VmIdleTimeoutMs",
    "",
    "[experimental]",
    "autoMemoryReclaim=dropCache"
  )
}

function Get-FirewallRuleDisplayName {
  param([Parameter(Mandatory = $true)][int]$Port)

  return "WSL SSH LAN $Port"
}

function Set-ManagedFirewallRule {
  [CmdletBinding(SupportsShouldProcess = $true)]
  param([Parameter(Mandatory = $true)][int]$Port)

  $displayName = Get-FirewallRuleDisplayName -Port $Port
  Get-NetFirewallRule -DisplayName $displayName -ErrorAction SilentlyContinue | Remove-NetFirewallRule

  if ($PSCmdlet.ShouldProcess($displayName, "Create Windows Firewall inbound allow rule")) {
    New-NetFirewallRule `
      -DisplayName $displayName `
      -Direction Inbound `
      -Action Allow `
      -Profile Domain,Private `
      -Protocol TCP `
      -LocalPort $Port `
      -RemoteAddress LocalSubnet | Out-Null
  }
}

function Remove-PortProxyForPort {
  [CmdletBinding(SupportsShouldProcess = $true)]
  param([Parameter(Mandatory = $true)][int]$ListenPort)

  $rows = Invoke-NativeCommand -FilePath "netsh.exe" -Arguments @("interface", "portproxy", "show", "v4tov4") -Description "List portproxy entries"
  foreach ($row in $rows) {
    if ($row -match "^\s*(\d{1,3}(?:\.\d{1,3}){3})\s+($ListenPort)\s+\d{1,3}(?:\.\d{1,3}){3}\s+\d+\s*$") {
      if ($PSCmdlet.ShouldProcess("$($matches[1]):$ListenPort", "Delete portproxy")) {
        Invoke-NativeCommand -FilePath "netsh.exe" -Arguments @("interface", "portproxy", "delete", "v4tov4", "listenaddress=$($matches[1])", "listenport=$ListenPort") -Description "Delete portproxy $($matches[1])`:$ListenPort"
      }
    }
  }
}

function Get-RelayScriptContent {
  param(
    [Parameter(Mandatory = $true)][string]$TemplatePath,
    [Parameter(Mandatory = $true)][string]$DistroName,
    [Parameter(Mandatory = $true)][int]$Port,
    [Parameter(Mandatory = $true)][int]$IdleShutdownSeconds,
    [Parameter(Mandatory = $true)][string]$PreferredListenAddress,
    [Parameter(Mandatory = $true)][string]$PreferredInterfaceAlias
  )

  $typeDefinitionSource = Read-TextFileIfPresent -Path $TemplatePath
  if ($null -eq $typeDefinitionSource) {
    throw "Relay C# type definition template is missing: $TemplatePath"
  }

  $renderedTypeDefinition = ($typeDefinitionSource.Replace("__DISTRO__", $DistroName).
    Replace("__PORT__", $Port.ToString()).
    Replace("__IDLE_TIMEOUT__", $IdleShutdownSeconds.ToString()).
    Replace("__PREFERRED_ADDRESS__", (ConvertTo-TemplateTokenValue -Text $PreferredListenAddress)).
    Replace("__PREFERRED_ALIAS__", (ConvertTo-TemplateTokenValue -Text $PreferredInterfaceAlias)).
    Replace("__LOG_PATH__", (ConvertTo-TemplateTokenValue -Text "C:\ProgramData\WslSshLan\WslSshRelay.log")))

  $relayScriptSource = @'
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

Add-Type -TypeDefinition @"
__TYPE_DEFINITION__
"@

$relay = [WslSshRelay]::new("__DISTRO__", __PORT__, __IDLE_TIMEOUT__, "__PREFERRED_ADDRESS__", "__PREFERRED_ALIAS__", "__LOG_PATH__")
$relay.Run()
'@

  return ($relayScriptSource.Replace("__TYPE_DEFINITION__", $renderedTypeDefinition).
    Replace("__DISTRO__", $DistroName).
    Replace("__PORT__", $Port.ToString()).
    Replace("__IDLE_TIMEOUT__", $IdleShutdownSeconds.ToString()).
    Replace("__PREFERRED_ADDRESS__", (ConvertTo-TemplateTokenValue -Text $PreferredListenAddress)).
    Replace("__PREFERRED_ALIAS__", (ConvertTo-TemplateTokenValue -Text $PreferredInterfaceAlias)).
    Replace("__LOG_PATH__", (ConvertTo-TemplateTokenValue -Text "C:\ProgramData\WslSshLan\WslSshRelay.log")))
}

function Restore-PartialSetup {
  param(
    [Parameter(Mandatory = $true)][bool]$RelayTaskCreated,
    [Parameter(Mandatory = $true)][bool]$ProgramDataScriptCreated,
    [Parameter(Mandatory = $true)][bool]$WslConfigCreated,
    [Parameter(Mandatory = $true)][bool]$ManagedFirewallRuleChanged,
    [Parameter(Mandatory = $true)][bool]$WslInstalledBySetup,
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
    [Parameter(Mandatory = $true)][bool]$WslConfigHadExistingFile,
    [AllowNull()][string]$WslConfigBackupContent,
    [Parameter(Mandatory = $true)][int]$SshPort,
    [Parameter(Mandatory = $true)][string]$RelayTaskName
  )

  if ($RelayTaskCreated -and (Get-ScheduledTask -TaskName $RelayTaskName -ErrorAction SilentlyContinue)) {
    Stop-ScheduledTask -TaskName $RelayTaskName -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $RelayTaskName -Confirm:$false -ErrorAction SilentlyContinue
  }

  if ($ProgramDataScriptCreated -and (Test-Path -LiteralPath $ProgramDataScriptPath)) {
    Remove-Item -LiteralPath $ProgramDataScriptPath -Force -ErrorAction SilentlyContinue
  }

  if ($WslConfigCreated) {
    if ($WslConfigHadExistingFile) {
      Write-Utf8TextFile -Path $WslConfigPath -Text $WslConfigBackupContent
    } elseif (Test-Path -LiteralPath $WslConfigPath) {
      Remove-Item -LiteralPath $WslConfigPath -Force -ErrorAction SilentlyContinue
    }
  }

  if ($WslInstalledBySetup -and (Test-DistroPresent -DistroName $DistroName)) {
    Invoke-NativeCommand -FilePath "wsl.exe" -Arguments @("--terminate", $DistroName) -Description "Terminate WSL distro"
    Invoke-NativeCommand -FilePath "wsl.exe" -Arguments @("--unregister", $DistroName) -Description "Unregister WSL distro"
  }

  if ($ManagedFirewallRuleChanged) {
    Get-NetFirewallRule -DisplayName (Get-FirewallRuleDisplayName -Port $SshPort) -ErrorAction SilentlyContinue | Remove-NetFirewallRule
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
$setupDefaultsPath = Join-Path $scriptRoot $manifest.setupDefaultsPath
$linuxSecurityProfilePath = Join-Path $scriptRoot $manifest.linuxSecurityProfilePath
$relayTypeDefinitionTemplatePath = Join-Path $scriptRoot $manifest.relayTypeDefinitionTemplatePath
if (-not (Test-Path -LiteralPath $setupDefaultsPath)) {
  throw "Setup defaults file is missing: $setupDefaultsPath"
}
if (-not (Test-Path -LiteralPath $linuxSecurityProfilePath)) {
  throw "Linux security profile file is missing: $linuxSecurityProfilePath"
}
if (-not (Test-Path -LiteralPath $relayTypeDefinitionTemplatePath)) {
  throw "Relay C# type definition template file is missing: $relayTypeDefinitionTemplatePath"
}

$setupDefaults = Read-JsonFile -Path $setupDefaultsPath
$linuxSecurityProfile = Read-JsonFile -Path $linuxSecurityProfilePath
if (-not ($setupDefaults.PSObject.Properties.Name -contains "defaultLinuxUser") -or [string]::IsNullOrWhiteSpace($setupDefaults.defaultLinuxUser)) {
  throw "Setup defaults file is missing 'defaultLinuxUser'."
}
if (-not ($linuxSecurityProfile.PSObject.Properties.Name -contains "wslConfTemplateLines") -or -not $linuxSecurityProfile.wslConfTemplateLines) {
  throw "Linux security profile is missing 'wslConfTemplateLines'."
}
if (-not ($linuxSecurityProfile.PSObject.Properties.Name -contains "sshdTemplateLines") -or -not $linuxSecurityProfile.sshdTemplateLines) {
  throw "Linux security profile is missing 'sshdTemplateLines'."
}
$defaultLinuxUser = [string]$setupDefaults.defaultLinuxUser

$stateDir = Join-Path $scriptRoot "state"
$statePath = Join-Path $stateDir "setup-state.json"
$programDataDir = Split-Path -Parent $manifest.programDataScriptPath
$programDataScriptPath = $manifest.programDataScriptPath
$linuxSetupConfigPath = $manifest.linuxSetupConfigPath
$legacyProgramDataScriptPath = Join-Path $programDataDir "Update-WslSshLan.ps1"
$wslConfigPath = Join-Path $env:USERPROFILE ".wslconfig"
$wslConfigHadExistingFile = Test-Path -LiteralPath $wslConfigPath
$wslConfigBackupContent = Read-TextFileIfPresent -Path $wslConfigPath

$rebootNeeded = Enable-WslFeaturesIfNeeded
$currentUser = $null
$wslInstalledBySetup = $false
$wslConfigCreated = $false
$managedFirewallRuleChanged = $false
$programDataScriptCreated = $false
$relayTaskCreated = $false
$sshdStateChanged = $false
$firewallRulesChanged = $false
$sshdServiceExists = $false
$sshdStartupType = $null
$sshdWasRunning = $false
$previewRuleEnabled = $null
$stableRuleEnabled = $null
$distroAlreadyExists = $false

if (-not $rebootNeeded) {
  if (Test-DistroPresent -DistroName $manifest.distroName) {
    try {
      Invoke-NativeCommand -FilePath "wsl.exe" -Arguments @("--distribution", $manifest.distroName, "--exec", "/bin/true") -Description "Probe WSL distro '$($manifest.distroName)'"
      $distroAlreadyExists = $true
    } catch {
      Write-Verbose "Registered WSL distro '$($manifest.distroName)' is not currently usable."
      $distroAlreadyExists = $false
    }
  }
}

if (Test-TaskPresent -TaskName $manifest.relayTaskName) {
  Stop-ScheduledTask -TaskName $manifest.relayTaskName -ErrorAction SilentlyContinue
  Unregister-ScheduledTask -TaskName $manifest.relayTaskName -Confirm:$false
}

if (Test-Path -LiteralPath $programDataScriptPath) {
  Remove-Item -LiteralPath $programDataScriptPath -Force
}

if ($legacyProgramDataScriptPath -ne $programDataScriptPath -and (Test-Path -LiteralPath $legacyProgramDataScriptPath)) {
  Remove-Item -LiteralPath $legacyProgramDataScriptPath -Force
}

if ([string]::IsNullOrWhiteSpace($ListenAddress)) {
  $candidates = @(Get-TrustedLanCandidate)
  if ($candidates.Count -lt 1) {
    throw "Could not auto-select a trusted LAN IPv4. Rerun with -ListenAddress."
  }
  if ($candidates.Count -gt 1) {
    $details = $candidates | ForEach-Object { "$($_.InterfaceAlias): $($_.IPAddress)" }
    Write-Output "Multiple trusted LAN IPv4s detected. Using the first one as the preferred address: $($details -join '; ')"
  }
  $listenConfig = $candidates | Sort-Object -Property InterfaceIndex | Select-Object -First 1
} else {
  $matchedCandidate = Get-TrustedLanCandidate | Where-Object { $_.IPAddress -eq $ListenAddress } | Select-Object -First 1
  if (-not $matchedCandidate) {
    throw "ListenAddress '$ListenAddress' is not an active trusted LAN IPv4 on this machine."
  }
  $listenConfig = $matchedCandidate
}

$ListenAddress = $listenConfig.IPAddress
$ListenInterfaceAlias = $listenConfig.InterfaceAlias

New-Item -ItemType Directory -Path $stateDir -Force | Out-Null

if ($rebootNeeded) {
  New-Item -ItemType Directory -Path $programDataDir -Force | Out-Null
  $relayScript = Get-RelayScriptContent -TemplatePath $relayTypeDefinitionTemplatePath -DistroName $manifest.distroName -Port $manifest.sshPort -IdleShutdownSeconds $manifest.relayIdleShutdownSeconds -PreferredListenAddress $ListenAddress -PreferredInterfaceAlias $ListenInterfaceAlias
  [System.IO.File]::WriteAllText($programDataScriptPath, $relayScript, [System.Text.UTF8Encoding]::new($false))
  [System.IO.File]::WriteAllLines($wslConfigPath, [string[]](Get-WslConfigContent -MemoryLimit $manifest.wslMemoryLimit -VmIdleTimeoutMs $manifest.vmIdleTimeoutMs), [System.Text.UTF8Encoding]::new($false))

  $state = [ordered]@{
    listenAddress = $ListenAddress
    listenInterfaceAlias = $ListenInterfaceAlias
    distroName = $manifest.distroName
    relayTaskName = $manifest.relayTaskName
    programDataScriptPath = $programDataScriptPath
    programDataScriptCreated = $true
    wslConfigCreated = $true
    wslConfigHadExistingFile = $wslConfigHadExistingFile
    wslConfigBackupContent = $wslConfigBackupContent
    linuxSetupConfigPath = $linuxSetupConfigPath
    setupTimeUtc = (Get-Date).ToUniversalTime().ToString("o")
    pendingFeatureReboot = $true
  }
  Write-JsonFile -Path $statePath -Object $state

  Write-Output "WSL features were enabled. Reboot Windows, then rerun this script to finish installing the distro and starting the relay."
  return
}

$wslInstallResult = Install-WslUbuntuDistro -DistroName $manifest.distroName
$wslInstalledBySetup = $wslInstallResult.InstalledNow
if ($wslInstallResult.NeedsReboot) {
  Write-Output "Ubuntu was staged by WSL. Reboot Windows, then rerun this script to finish bootstrapping the distro."
  return
}

try {
  if ($distroAlreadyExists) {
    Write-Output "Existing WSL distro '$($manifest.distroName)' detected. Repairing in place."
  }
  $setupCredentials = Read-OrCreate-SetupProfile -DistroName $manifest.distroName -Path $linuxSetupConfigPath -DefaultLinuxUser $defaultLinuxUser
  $linuxUser = $setupCredentials.LinuxUser
  $loginSecretText = $setupCredentials.LinuxPassword
  $loginPasswordSecure = Convert-PlainTextToSecureString -Text $loginSecretText
  $loginSecretText = $null

  if ($setupCredentials.Created) {
    Write-Output "Created Linux setup credentials at $linuxSetupConfigPath."
  }
  if ($setupCredentials.Updated) {
    Write-Output "Updated Linux setup credentials at $linuxSetupConfigPath."
  }

  Set-LinuxUserConfigured -DistroName $manifest.distroName -LinuxUser $linuxUser -PasswordSecure $loginPasswordSecure
  Install-OpenSshServerIfMissing -DistroName $manifest.distroName
  Initialize-LinuxBootstrapConfiguration -DistroName $manifest.distroName -LinuxUser $linuxUser -SshPort $manifest.sshPort -SecurityProfile $linuxSecurityProfile
  Invoke-NativeCommand -FilePath "wsl.exe" -Arguments @("--shutdown") -Description "Apply Linux bootstrap configuration"

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

  Remove-PortProxyForPort -ListenPort $manifest.sshPort
  New-Item -ItemType Directory -Path $programDataDir -Force | Out-Null
  $relayScript = Get-RelayScriptContent -TemplatePath $relayTypeDefinitionTemplatePath -DistroName $manifest.distroName -Port $manifest.sshPort -IdleShutdownSeconds $manifest.relayIdleShutdownSeconds -PreferredListenAddress $ListenAddress -PreferredInterfaceAlias $ListenInterfaceAlias
  [System.IO.File]::WriteAllText($programDataScriptPath, $relayScript, [System.Text.UTF8Encoding]::new($false))
  $programDataScriptCreated = $true

  [System.IO.File]::WriteAllLines($wslConfigPath, [string[]](Get-WslConfigContent -MemoryLimit $manifest.wslMemoryLimit -VmIdleTimeoutMs $manifest.vmIdleTimeoutMs), [System.Text.UTF8Encoding]::new($false))
  $wslConfigCreated = $true
  Set-ManagedFirewallRule -Port $manifest.sshPort
  $managedFirewallRuleChanged = $true

  $currentUser = Get-CurrentWindowsUser
  $relayAction = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$programDataScriptPath`""
  $relayBootTrigger = New-ScheduledTaskTrigger -AtStartup
  $relayBootTrigger.Delay = "PT20S"
  $relayLogonTrigger = New-ScheduledTaskTrigger -AtLogOn -User $currentUser
  $relayLogonTrigger.Delay = "PT20S"
  $relayPrincipal = New-ScheduledTaskPrincipal -UserId $currentUser -LogonType S4U -RunLevel Highest
  $relaySettings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew
  Register-ScheduledTask -TaskName $manifest.relayTaskName -Action $relayAction -Trigger @($relayBootTrigger, $relayLogonTrigger) -Principal $relayPrincipal -Settings $relaySettings -Force | Out-Null
  $relayTaskCreated = $true

  Start-ScheduledTask -TaskName $manifest.relayTaskName
  Start-Sleep -Seconds 2

  $state = [ordered]@{
    windowsUser = $currentUser
    listenAddress = $ListenAddress
    listenInterfaceAlias = $ListenInterfaceAlias
    distroName = $manifest.distroName
    wslInstalledBySetup = $wslInstalledBySetup
    linuxUser = $linuxUser
    relayTaskName = $manifest.relayTaskName
    programDataScriptPath = $programDataScriptPath
    linuxSetupConfigPath = $linuxSetupConfigPath
    wslConfigCreated = $true
    wslConfigHadExistingFile = $wslConfigHadExistingFile
    wslConfigBackupContent = $wslConfigBackupContent
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

  Write-Output "Setup complete."
  Write-Output "ListenAddress: $ListenAddress"
  Write-Output "ListenInterfaceAlias: $ListenInterfaceAlias"
  Write-Output "Distro: $($manifest.distroName)"
  Write-Output "SSH: ssh -p $($manifest.sshPort) $linuxUser@$ListenAddress"
}
catch {
  try {
    Restore-PartialSetup `
      -RelayTaskCreated $relayTaskCreated `
      -ProgramDataScriptCreated $programDataScriptCreated `
      -WslConfigCreated $wslConfigCreated `
      -ManagedFirewallRuleChanged $managedFirewallRuleChanged `
      -WslInstalledBySetup $wslInstalledBySetup `
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
      -WslConfigHadExistingFile $wslConfigHadExistingFile `
      -WslConfigBackupContent $wslConfigBackupContent `
      -SshPort $manifest.sshPort `
      -RelayTaskName $manifest.relayTaskName
  } catch {
    Write-Warning "Rollback encountered an issue: $($_.Exception.Message)"
  }
  throw
}
