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

function Assert-Condition {
  param(
    [Parameter(Mandatory = $true)][bool]$Condition,
    [Parameter(Mandatory = $true)][string]$Message
  )

  if (-not $Condition) {
    throw $Message
  }
}

function Get-FunctionScriptBlock {
  param(
    [Parameter(Mandatory = $true)][System.Management.Automation.Language.Ast]$Ast,
    [Parameter(Mandatory = $true)][string]$Name
  )

  $func = $Ast.Find({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
  }, $true)

  Assert-Condition -Condition ($null -ne $func) -Message "Function '$Name' was not found."
  return [scriptblock]::Create($func.Extent.Text)
}

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$manifestPath = Join-Path $scriptRoot "manifest.json"
$linuxSecurityProfilePath = $null
$relayTypeDefinitionTemplatePath = $null
$validateFixturesPath = Join-Path $scriptRoot "validate-fixtures.json"
$setupPath = Join-Path $scriptRoot "setup-ubuntu-ssh.ps1"
$uninstallPath = Join-Path $scriptRoot "uninstall-ubuntu-ssh.ps1"

Assert-Condition -Condition (Test-Path -LiteralPath $manifestPath) -Message "manifest.json is missing."
Assert-Condition -Condition (Test-Path -LiteralPath $validateFixturesPath) -Message "validate-fixtures.json is missing."
Assert-Condition -Condition (Test-Path -LiteralPath $setupPath) -Message "setup-ubuntu-ssh.ps1 is missing."
Assert-Condition -Condition (Test-Path -LiteralPath $uninstallPath) -Message "uninstall-ubuntu-ssh.ps1 is missing."

$manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
$setupDefaultsPath = Join-Path $scriptRoot $manifest.setupDefaultsPath
$linuxSecurityProfilePath = Join-Path $scriptRoot $manifest.linuxSecurityProfilePath
$relayTypeDefinitionTemplatePath = Join-Path $scriptRoot $manifest.relayTypeDefinitionTemplatePath
Assert-Condition -Condition (Test-Path -LiteralPath $setupDefaultsPath) -Message "setup-defaults.json is missing."
Assert-Condition -Condition (Test-Path -LiteralPath $linuxSecurityProfilePath) -Message "linux-security-profile.json is missing."
Assert-Condition -Condition (Test-Path -LiteralPath $relayTypeDefinitionTemplatePath) -Message "Relay C# type definition template is missing."
$setupDefaults = Get-Content -LiteralPath $setupDefaultsPath -Raw -Encoding UTF8 | ConvertFrom-Json
$linuxSecurityProfile = Get-Content -LiteralPath $linuxSecurityProfilePath -Raw -Encoding UTF8 | ConvertFrom-Json
$validateFixtures = Get-Content -LiteralPath $validateFixturesPath -Raw -Encoding UTF8 | ConvertFrom-Json
$requiredFields = @(
  "distroName",
  "linuxSetupConfigPath",
  "setupDefaultsPath",
  "linuxSecurityProfilePath",
  "relayTypeDefinitionTemplatePath",
  "sshPort",
  "wslMemoryLimit",
  "vmIdleTimeoutMs",
  "relayIdleShutdownSeconds",
  "programDataScriptPath",
  "relayTaskName"
)

foreach ($field in $requiredFields) {
  Assert-Condition -Condition ($manifest.PSObject.Properties.Name -contains $field) -Message "manifest.json is missing '$field'."
}

Assert-Condition -Condition ($manifest.linuxSetupConfigPath -match '^/') -Message "manifest.json linuxSetupConfigPath must be a Linux path."

$requiredDefaultsFields = @("defaultLinuxUser")
foreach ($field in $requiredDefaultsFields) {
  Assert-Condition -Condition ($setupDefaults.PSObject.Properties.Name -contains $field) -Message "setup-defaults.json is missing '$field'."
}

Assert-Condition -Condition ($linuxSecurityProfile.PSObject.Properties.Name -contains "wslConfTemplateLines") -Message "linux-security-profile.json is missing 'wslConfTemplateLines'."
Assert-Condition -Condition ($linuxSecurityProfile.PSObject.Properties.Name -contains "sshdTemplateLines") -Message "linux-security-profile.json is missing 'sshdTemplateLines'."
Assert-Condition -Condition ($linuxSecurityProfile.wslConfTemplateLines.Count -gt 0) -Message "linux-security-profile.json wslConfTemplateLines must not be empty."
Assert-Condition -Condition ($linuxSecurityProfile.sshdTemplateLines.Count -gt 0) -Message "linux-security-profile.json sshdTemplateLines must not be empty."

Assert-Condition -Condition ($setupDefaults.defaultLinuxUser -match '^[a-z_][a-z0-9_-]*$') -Message "setup-defaults.json defaultLinuxUser is invalid."

$requiredFixtureFields = @(
  "preferredListenAddress",
  "preferredInterfaceAlias"
)
foreach ($field in $requiredFixtureFields) {
  Assert-Condition -Condition ($validateFixtures.PSObject.Properties.Name -contains $field) -Message "validate-fixtures.json is missing '$field'."
}

$tokens = $null
$errors = $null
$setupAst = [System.Management.Automation.Language.Parser]::ParseFile($setupPath, [ref]$tokens, [ref]$errors)
Assert-Condition -Condition ($errors.Count -eq 0) -Message "setup-ubuntu-ssh.ps1 has parse errors."
$setupContent = Get-Content -LiteralPath $setupPath -Raw
Set-Variable -Name ShowProgressBar -Value $false
Set-Variable -Name AllowConsolePasswordPrompt -Value $false
$relayTemplateContent = Get-Content -LiteralPath $relayTypeDefinitionTemplatePath -Raw -Encoding UTF8
Assert-Condition -Condition ($setupContent -match "Initialize-Utf8Output") -Message "setup-ubuntu-ssh.ps1 must initialize UTF-8 output."
Assert-Condition -Condition ($relayTemplateContent -match "File\.AppendAllText\(\s*_logPath,\s*line \+ Environment\.NewLine,\s*new UTF8Encoding\(false\)\s*\)") -Message "Relay logs must be appended with UTF-8 encoding."

$tokens = $null
$errors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($uninstallPath, [ref]$tokens, [ref]$errors)
Assert-Condition -Condition ($errors.Count -eq 0) -Message "uninstall-ubuntu-ssh.ps1 has parse errors."
$uninstallContent = Get-Content -LiteralPath $uninstallPath -Raw
Assert-Condition -Condition ($uninstallContent -notmatch "Get-NetFirewallHyperVRule|Remove-NetFirewallHyperVRule") -Message "uninstall-ubuntu-ssh.ps1 must not reference Hyper-V firewall cmdlets."
Assert-Condition -Condition ($uninstallContent -match "Initialize-Utf8Output") -Message "uninstall-ubuntu-ssh.ps1 must initialize UTF-8 output."

Assert-Condition -Condition (-not ($manifest.PSObject.Properties.Name -contains "linuxUser")) -Message "manifest.json must not define linuxUser; use setup-defaults.json instead."
Assert-Condition -Condition (-not ($manifest.PSObject.Properties.Name -contains "setupConfigPath")) -Message "manifest.json must not define setupConfigPath; use linuxSetupConfigPath instead."

. (Get-FunctionScriptBlock -Ast $setupAst -Name "Get-WslConfigContent")
. (Get-FunctionScriptBlock -Ast $setupAst -Name "Read-TextFileIfPresent")
. (Get-FunctionScriptBlock -Ast $setupAst -Name "ConvertTo-TemplateTokenValue")
. (Get-FunctionScriptBlock -Ast $setupAst -Name "Get-FirewallRuleDisplayName")
. (Get-FunctionScriptBlock -Ast $setupAst -Name "Get-LinuxWslConfigContent")
. (Get-FunctionScriptBlock -Ast $setupAst -Name "Get-LinuxSshdConfigContent")
. (Get-FunctionScriptBlock -Ast $setupAst -Name "Install-WslUbuntuDistro")
. (Get-FunctionScriptBlock -Ast $setupAst -Name "Install-OpenSshServerIfMissing")
. (Get-FunctionScriptBlock -Ast $setupAst -Name "Initialize-LinuxBootstrapConfiguration")
. (Get-FunctionScriptBlock -Ast $setupAst -Name "ConvertTo-LinuxSingleQuotedText")
. (Get-FunctionScriptBlock -Ast $setupAst -Name "Test-LinuxPathPresent")
. (Get-FunctionScriptBlock -Ast $setupAst -Name "Read-LinuxTextFile")
. (Get-FunctionScriptBlock -Ast $setupAst -Name "Write-LinuxTextFile")
. (Get-FunctionScriptBlock -Ast $setupAst -Name "Get-DefaultSetupProfile")
. (Get-FunctionScriptBlock -Ast $setupAst -Name "Get-LinuxPasswordValidationError")
. (Get-FunctionScriptBlock -Ast $setupAst -Name "Get-LinuxPasswordStatusMessage")
. (Get-FunctionScriptBlock -Ast $setupAst -Name "Read-OrCreate-SetupProfile")
. (Get-FunctionScriptBlock -Ast $setupAst -Name "Get-LinuxPasswordHash")
. (Get-FunctionScriptBlock -Ast $setupAst -Name "Test-LinuxPasswordMatchesStoredHash")
. (Get-FunctionScriptBlock -Ast $setupAst -Name "Invoke-LinuxShadowPasswordHashUpdate")
. (Get-FunctionScriptBlock -Ast $setupAst -Name "Set-LinuxUserConfigured")
. (Get-FunctionScriptBlock -Ast $setupAst -Name "Get-RelayScriptContent")

$generatedWslConfig = Get-WslConfigContent -MemoryLimit $manifest.wslMemoryLimit -VmIdleTimeoutMs $manifest.vmIdleTimeoutMs
$expectedWslConfig = @(
  "[wsl2]",
  "memory=$($manifest.wslMemoryLimit)",
  "networkingMode=nat",
  "firewall=true",
  "vmIdleTimeout=$($manifest.vmIdleTimeoutMs)",
  "",
  "[experimental]",
  "autoMemoryReclaim=dropCache"
) -join "`n"
Assert-Condition -Condition (($generatedWslConfig -join "`n") -eq $expectedWslConfig) -Message "Generated .wslconfig content is incorrect."
Assert-Condition -Condition ((Get-FirewallRuleDisplayName -Port $manifest.sshPort) -eq "WSL SSH LAN $($manifest.sshPort)") -Message "Managed firewall rule name is incorrect."

$linuxWslConfig = Get-LinuxWslConfigContent -DefaultLinuxUser $setupDefaults.defaultLinuxUser -TemplateLines ([string[]]$linuxSecurityProfile.wslConfTemplateLines)
$expectedLinuxWslConfig = (($linuxSecurityProfile.wslConfTemplateLines | ForEach-Object {
  $_.Replace("__DEFAULT_LINUX_USER__", $setupDefaults.defaultLinuxUser)
}) -join "`n")
Assert-Condition -Condition (($linuxWslConfig -join "`n") -eq $expectedLinuxWslConfig) -Message "Generated /etc/wsl.conf content is incorrect."

$linuxSshdConfig = Get-LinuxSshdConfigContent -Port $manifest.sshPort -LinuxUser $setupDefaults.defaultLinuxUser -TemplateLines ([string[]]$linuxSecurityProfile.sshdTemplateLines)
$expectedLinuxSshdConfig = (($linuxSecurityProfile.sshdTemplateLines | ForEach-Object {
  $_.Replace("__SSH_PORT__", $manifest.sshPort.ToString()).Replace("__DEFAULT_LINUX_USER__", $setupDefaults.defaultLinuxUser)
}) -join "`n")
Assert-Condition -Condition (($linuxSshdConfig -join "`n") -eq $expectedLinuxSshdConfig) -Message "Generated sshd drop-in content is incorrect."

$setupScriptChecks = @(
  "--install",
  "--web-download",
  "--no-launch",
  "openssh-server",
  "99-wsl-ssh-lan.conf",
  "New-NetFirewallRule",
  "wslConfigBackupContent",
  "Read-Host -AsSecureString",
  "ResetLinuxPassword",
  "AllowConsolePasswordPrompt",
  "ShowProgressBar",
  "Test-InteractivePromptAvailable",
  "cannot prompt interactively",
  "ImeMode",
  "/usr/sbin/usermod",
  "base64 --decode"
)
foreach ($needle in $setupScriptChecks) {
  Assert-Condition -Condition ($setupContent -match [regex]::Escape($needle)) -Message "setup-ubuntu-ssh.ps1 must contain '$needle'."
}
Assert-Condition -Condition (-not ($setupContent -match "Guid\(\)::NewGuid|NewGuid\(\)")) -Message "setup-ubuntu-ssh.ps1 must not generate a default Linux password."
Assert-Condition -Condition ($setupContent -match 'if \s*\(\$ShowProgressBar\)') -Message "setup-ubuntu-ssh.ps1 must gate Write-Progress behind ShowProgressBar."
Assert-Condition -Condition ($setupContent -match 'graphical password dialog is not available.*console password prompting is disabled by default') -Message "setup-ubuntu-ssh.ps1 must refuse console password prompting by default."
Assert-Condition -Condition ($setupContent -match '/usr/bin/openssl.*passwd.*-6' -or $setupContent -match '/usr/bin/mkpasswd.*-m.*sha-512') -Message "setup-ubuntu-ssh.ps1 must generate SHA-512 password hashes inside WSL."
Assert-Condition -Condition ($setupContent -match 'Invoke-LinuxShadowPasswordHashUpdate') -Message "setup-ubuntu-ssh.ps1 must apply the generated password hash through a dedicated helper."
Assert-Condition -Condition ($setupContent -match '/usr/sbin/usermod' -and $setupContent -match '"--password"') -Message "setup-ubuntu-ssh.ps1 must apply the generated password hash with usermod."
Assert-Condition -Condition ($setupContent -match 'Test-LinuxPasswordMatchesStoredHash') -Message "setup-ubuntu-ssh.ps1 must verify that the stored shadow hash authenticates the entered password."

$defaultSetupProfile = Get-DefaultSetupProfile -DefaultLinuxUser $setupDefaults.defaultLinuxUser
Assert-Condition -Condition ($defaultSetupProfile.Contains("linuxUser")) -Message "Default setup profile must contain linuxUser."
Assert-Condition -Condition (-not $defaultSetupProfile.Contains("linuxPassword")) -Message "Default setup profile must not contain a generated password."

$validPasswordStatus = Get-LinuxPasswordStatusMessage -CandidateText "AsciiPass123!" -ConfirmText "AsciiPass123!"
Assert-Condition -Condition $validPasswordStatus.IsReady -Message "A valid ASCII password should be accepted by Get-LinuxPasswordStatusMessage."
$fullWidthCandidate = ([char]0xFF21) + "bcdef12"
$invalidPasswordStatus = Get-LinuxPasswordStatusMessage -CandidateText $fullWidthCandidate -ConfirmText $fullWidthCandidate
Assert-Condition -Condition (-not $invalidPasswordStatus.IsReady) -Message "A password containing non-ASCII characters must be rejected by Get-LinuxPasswordStatusMessage."
$generatedRelayScript = Get-RelayScriptContent -TemplatePath $relayTypeDefinitionTemplatePath -DistroName $manifest.distroName -Port $manifest.sshPort -IdleShutdownSeconds $manifest.relayIdleShutdownSeconds -PreferredListenAddress $validateFixtures.preferredListenAddress -PreferredInterfaceAlias $validateFixtures.preferredInterfaceAlias
Assert-Condition -Condition ($generatedRelayScript -match "TcpListener") -Message "Generated relay script does not create a TCP listener."
Assert-Condition -Condition ($generatedRelayScript -match "WslSshRelay") -Message "Generated relay script does not define the relay class."
Assert-Condition -Condition ($generatedRelayScript -match "--terminate") -Message "Generated relay script does not terminate WSL after idle."
Assert-Condition -Condition ($generatedRelayScript -match "systemctl") -Message "Generated relay script does not start ssh.service."
Assert-Condition -Condition ($generatedRelayScript -match "Initialize-Utf8Output") -Message "Generated relay script must initialize UTF-8 output."
Assert-Condition -Condition ($generatedRelayScript -match "File\.AppendAllText\(_logPath, line \+ Environment\.NewLine, new UTF8Encoding\(false\)\)") -Message "Generated relay script must write logs as UTF-8."
$tokens = $null
$errors = $null
[void][System.Management.Automation.Language.Parser]::ParseInput($generatedRelayScript, [ref]$tokens, [ref]$errors)
Assert-Condition -Condition ($errors.Count -eq 0) -Message "Generated relay script has parse errors."

$historyLeakUserHits = & git.exe log --all --oneline ("-S" + [string]::Join("", @("w", "o", "t", "a"))) -- .
Assert-Condition -Condition (-not $historyLeakUserHits) -Message "Git history still contains the removed Linux user name."

$historyLeakPasswordHits = & git.exe log --all --oneline ("-S" + [string]::Join("", @("8", "2", "2", "1", "7", "9"))) -- .
Assert-Condition -Condition (-not $historyLeakPasswordHits) -Message "Git history still contains the removed password."

Write-Output "Repository validation passed."

