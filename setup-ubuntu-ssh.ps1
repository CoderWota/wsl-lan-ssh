[CmdletBinding()]
param(
  [string]$ListenAddress,
  [securestring]$LinuxPassword,
  [switch]$ResetLinuxPassword,
  [switch]$AllowConsolePasswordPrompt,
  [switch]$ShowProgressBar
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

$script:SetupStatusTotalSteps = 9

function Initialize-ConsolePresentation {
  if (-not [Environment]::UserInteractive) {
    return
  }

  $global:ProgressPreference = "SilentlyContinue"

  try {
    if ($Host.Name -eq "ConsoleHost") {
      Clear-Host
    }
  } catch {
    Write-Verbose "Console cleanup was skipped. $($_.Exception.Message)"
  }
}

Initialize-ConsolePresentation

function Write-SetupStatus {
  param(
    [Parameter(Mandatory = $true)][int]$Step,
    [Parameter(Mandatory = $true)][string]$Message
  )

  $boundedStep = [Math]::Min([Math]::Max($Step, 1), $script:SetupStatusTotalSteps)
  if ($ShowProgressBar) {
    $percentComplete = [int][Math]::Floor((($boundedStep - 1) * 100) / $script:SetupStatusTotalSteps)
    Write-Progress -Activity "Setting up WSL Ubuntu SSH" -Status $Message -PercentComplete $percentComplete
  }

  Write-Output "[Step $boundedStep/$($script:SetupStatusTotalSteps)] $Message"
}

function Complete-SetupStatus {
  param([Parameter(Mandatory = $true)][string]$Message)

  if ($ShowProgressBar) {
    Write-Progress -Activity "Setting up WSL Ubuntu SSH" -Status $Message -PercentComplete 100 -Completed
  }

  Write-Output $Message
}

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

function ConvertTo-LinuxPackageTokenList {
  param([Parameter(Mandatory = $true)][string[]]$PackageNames)

  $validatedPackageNames = foreach ($packageName in $PackageNames) {
    $trimmedName = $packageName.Trim()
    if ([string]::IsNullOrWhiteSpace($trimmedName)) {
      throw "Linux package names must not be blank."
    }
    if ($trimmedName -notmatch '^[a-z0-9][a-z0-9+.-]*$') {
      throw "Linux package name '$trimmedName' is invalid."
    }

    $trimmedName
  }

  return [string]::Join(" ", $validatedPackageNames)
}

function ConvertTo-LinuxSingleQuotedText {
  param([Parameter(Mandatory = $true)][string]$Text)

  return "'" + ($Text -replace "'", "'""'""'") + "'"
}

function ConvertFrom-NativeCommandText {
  param([AllowNull()]$Value)

  if ($null -eq $Value) {
    return $null
  }

  $text = [string]$Value
  if ($text.IndexOf([char]0) -ge 0) {
    $text = $text.Replace([string][char]0, "")
  }

  return $text.Trim([char]0xFEFF)
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
  $normalizedOutput = @($output | ForEach-Object { ConvertFrom-NativeCommandText -Value $_ })
  $exitCode = $LASTEXITCODE
  if ($exitCode -ne 0) {
    $message = $normalizedOutput -join [Environment]::NewLine
    throw "$Description failed with exit code $exitCode. $message"
  }

  return $normalizedOutput
}

function Invoke-NativeCommandWithHeartbeat {
  param(
    [Parameter(Mandatory = $true)][string]$FilePath,
    [Parameter(Mandatory = $true)][string[]]$Arguments,
    [Parameter(Mandatory = $true)][string]$Description,
    [Parameter(Mandatory = $true)][string]$HeartbeatMessage,
    [int]$HeartbeatIntervalSeconds = 20
  )

  $sourceIdentifier = "SetupHeartbeat_$([Guid]::NewGuid().ToString('N'))"
  $timer = [System.Timers.Timer]::new($HeartbeatIntervalSeconds * 1000)
  $timer.AutoReset = $true
  $subscription = $null

  try {
    $subscription = Register-ObjectEvent -InputObject $timer -EventName Elapsed -SourceIdentifier $sourceIdentifier -MessageData $HeartbeatMessage -Action {
      Write-Host $event.MessageData
    }
    $timer.Start()

    return Invoke-NativeCommand -FilePath $FilePath -Arguments $Arguments -Description $Description
  } finally {
    if ($null -ne $timer) {
      $timer.Stop()
      $timer.Dispose()
    }
    if ($null -ne $subscription) {
      Unregister-Event -SourceIdentifier $sourceIdentifier -ErrorAction SilentlyContinue
      Remove-Job -Name $sourceIdentifier -Force -ErrorAction SilentlyContinue
    }
  }
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
  $base64Text = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($Text))
  $quotedDirectory = ConvertTo-LinuxSingleQuotedText -Text $directory
  $quotedPath = ConvertTo-LinuxSingleQuotedText -Text $Path
  $quotedBase64Text = ConvertTo-LinuxSingleQuotedText -Text $base64Text
  $shellCommand = "umask 077; /bin/mkdir -p $quotedDirectory"
  if ($PSBoundParameters.ContainsKey("DirectoryMode") -and -not [string]::IsNullOrWhiteSpace($DirectoryMode)) {
    $shellCommand += "; /bin/chmod $DirectoryMode $quotedDirectory"
  }
  $shellCommand += "; /usr/bin/printf '%s' $quotedBase64Text | /usr/bin/base64 --decode > $quotedPath"
  if ($PSBoundParameters.ContainsKey("FileMode") -and -not [string]::IsNullOrWhiteSpace($FileMode)) {
    $shellCommand += "; /bin/chmod $FileMode $quotedPath"
  }
  Invoke-NativeCommand -FilePath "wsl.exe" -Arguments @("--distribution", $DistroName, "--user", "root", "--exec", "/bin/sh", "-c", $shellCommand) -Description "Write Linux file '$Path'"
}

function Get-DefaultSetupProfile {
  param([Parameter(Mandatory = $true)][string]$DefaultLinuxUser)

  return [ordered]@{
    linuxUser = $DefaultLinuxUser
  }
}

function Get-LinuxPasswordValidationError {
  param([AllowEmptyString()][string]$CandidateText)

  if ([string]::IsNullOrWhiteSpace($CandidateText)) {
    return "The Linux password cannot be blank."
  }

  if ($CandidateText.Length -lt 8) {
    return "The Linux password must be at least 8 characters long."
  }

  if ($CandidateText -match "[\r\n:]") {
    return "The Linux password cannot contain a colon or newline."
  }

  if ($CandidateText -match "^\s" -or $CandidateText -match "\s$") {
    return "The Linux password cannot start or end with whitespace."
  }

  foreach ($character in $CandidateText.ToCharArray()) {
    $codePoint = [int][char]$character
    if ($codePoint -lt 33 -or $codePoint -gt 126) {
      return "The Linux password must use visible ASCII characters only. Switch to an English keyboard/input mode and avoid full-width or non-ASCII characters."
    }
  }

  return $null
}

function Test-InteractivePromptAvailable {
  try {
    return [Environment]::UserInteractive -and (-not [Console]::IsInputRedirected)
  } catch {
    return $false
  }
}

function Test-GuiPromptAvailable {
  try {
    if (-not [Environment]::UserInteractive) {
      return $false
    }

    Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
    Add-Type -AssemblyName System.Drawing -ErrorAction Stop
    return $true
  } catch {
    return $false
  }
}

function Get-LinuxPasswordStatusMessage {
  param(
    [AllowEmptyString()][string]$CandidateText,
    [AllowEmptyString()][string]$ConfirmText
  )

  $validationError = Get-LinuxPasswordValidationError -CandidateText $CandidateText
  if ($validationError) {
    return [pscustomobject]@{
      IsReady = $false
      Message = $validationError
    }
  }

  if ($CandidateText -ne $ConfirmText) {
    return [pscustomobject]@{
      IsReady = $false
      Message = "The two password entries do not match yet."
    }
  }

  return [pscustomobject]@{
    IsReady = $true
    Message = "Password looks valid. You can continue."
  }
}

function ConvertFrom-VisibleTextToSecureString {
  param([Parameter(Mandatory = $true)][string]$Text)

  $secureText = [securestring]::new()
  foreach ($character in $Text.ToCharArray()) {
    $secureText.AppendChar($character)
  }

  $secureText.MakeReadOnly()
  return $secureText
}

function Read-GuiLinuxPassword {
  param([Parameter(Mandatory = $true)][string]$LinuxUser)

  $form = [System.Windows.Forms.Form]::new()
  $form.Text = "Set Linux Password"
  $form.StartPosition = "CenterScreen"
  $form.FormBorderStyle = "FixedDialog"
  $form.MaximizeBox = $false
  $form.MinimizeBox = $false
  $form.ClientSize = [System.Drawing.Size]::new(520, 288)
  $form.TopMost = $true

  $introLabel = [System.Windows.Forms.Label]::new()
  $introLabel.Location = [System.Drawing.Point]::new(16, 16)
  $introLabel.Size = [System.Drawing.Size]::new(488, 58)
  $introLabel.Text = "Enter a password for Linux user '$LinuxUser'. This dialog keeps the password visible by default so you can verify it before the script writes anything."
  $form.Controls.Add($introLabel)

  $passwordLabel = [System.Windows.Forms.Label]::new()
  $passwordLabel.Location = [System.Drawing.Point]::new(16, 82)
  $passwordLabel.Size = [System.Drawing.Size]::new(180, 20)
  $passwordLabel.Text = "Password"
  $form.Controls.Add($passwordLabel)

  $passwordBox = [System.Windows.Forms.TextBox]::new()
  $passwordBox.Location = [System.Drawing.Point]::new(16, 102)
  $passwordBox.Size = [System.Drawing.Size]::new(488, 24)
  $passwordBox.UseSystemPasswordChar = $false
  $passwordBox.ImeMode = [System.Windows.Forms.ImeMode]::Disable
  $form.Controls.Add($passwordBox)

  $confirmLabel = [System.Windows.Forms.Label]::new()
  $confirmLabel.Location = [System.Drawing.Point]::new(16, 136)
  $confirmLabel.Size = [System.Drawing.Size]::new(180, 20)
  $confirmLabel.Text = "Confirm password"
  $form.Controls.Add($confirmLabel)

  $confirmBox = [System.Windows.Forms.TextBox]::new()
  $confirmBox.Location = [System.Drawing.Point]::new(16, 156)
  $confirmBox.Size = [System.Drawing.Size]::new(488, 24)
  $confirmBox.UseSystemPasswordChar = $false
  $confirmBox.ImeMode = [System.Windows.Forms.ImeMode]::Disable
  $form.Controls.Add($confirmBox)

  $showPasswordCheckBox = [System.Windows.Forms.CheckBox]::new()
  $showPasswordCheckBox.Location = [System.Drawing.Point]::new(16, 194)
  $showPasswordCheckBox.Size = [System.Drawing.Size]::new(210, 24)
  $showPasswordCheckBox.Text = "Hide characters while typing"
  $showPasswordCheckBox.Checked = $false
  $form.Controls.Add($showPasswordCheckBox)

  $statusLabel = [System.Windows.Forms.Label]::new()
  $statusLabel.Location = [System.Drawing.Point]::new(16, 222)
  $statusLabel.Size = [System.Drawing.Size]::new(488, 32)
  $statusLabel.Text = "Use visible ASCII characters only. No spaces at the start or end."
  $form.Controls.Add($statusLabel)

  $okButton = [System.Windows.Forms.Button]::new()
  $okButton.Location = [System.Drawing.Point]::new(348, 252)
  $okButton.Size = [System.Drawing.Size]::new(75, 26)
  $okButton.Text = "OK"
  $okButton.DialogResult = [System.Windows.Forms.DialogResult]::OK
  $form.Controls.Add($okButton)

  $cancelButton = [System.Windows.Forms.Button]::new()
  $cancelButton.Location = [System.Drawing.Point]::new(429, 252)
  $cancelButton.Size = [System.Drawing.Size]::new(75, 26)
  $cancelButton.Text = "Cancel"
  $cancelButton.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
  $form.Controls.Add($cancelButton)

  $form.AcceptButton = $okButton
  $form.CancelButton = $cancelButton

  $updatePasswordUi = {
    $hideCharacters = $showPasswordCheckBox.Checked
    $passwordBox.UseSystemPasswordChar = $hideCharacters
    $confirmBox.UseSystemPasswordChar = $hideCharacters

    $status = Get-LinuxPasswordStatusMessage -CandidateText $passwordBox.Text -ConfirmText $confirmBox.Text
    $statusLabel.Text = "{0} Length: {1}" -f $status.Message, $passwordBox.Text.Length
    $statusLabel.ForeColor = if ($status.IsReady) { [System.Drawing.Color]::DarkGreen } else { [System.Drawing.Color]::DarkRed }
    $okButton.Enabled = $status.IsReady
  }

  $passwordBox.Add_TextChanged($updatePasswordUi)
  $confirmBox.Add_TextChanged($updatePasswordUi)
  $showPasswordCheckBox.Add_CheckedChanged($updatePasswordUi)

  while ($true) {
    $passwordBox.Text = ""
    $confirmBox.Text = ""
    $null = $form.ActiveControl = $passwordBox
    & $updatePasswordUi
    $dialogResult = $form.ShowDialog()

    if ($dialogResult -ne [System.Windows.Forms.DialogResult]::OK) {
      $form.Dispose()
      throw "Linux password entry was canceled."
    }

    $status = Get-LinuxPasswordStatusMessage -CandidateText $passwordBox.Text -ConfirmText $confirmBox.Text
    if (-not $status.IsReady) {
      [System.Windows.Forms.MessageBox]::Show($status.Message, "Invalid Linux Password", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
      continue
    }

    $securePassword = ConvertFrom-VisibleTextToSecureString -Text $passwordBox.Text
    $form.Dispose()
    return $securePassword
  }
}

function Read-InteractiveLinuxPassword {
  param(
    [Parameter(Mandatory = $true)][string]$LinuxUser,
    [switch]$AllowConsoleFallback
  )

  if (-not (Test-InteractivePromptAvailable)) {
    throw "A Linux password is required, but this session cannot prompt interactively. Rerun setup in an elevated interactive PowerShell window, or pass -LinuxPassword."
  }

  if (Test-GuiPromptAvailable) {
    return Read-GuiLinuxPassword -LinuxUser $LinuxUser
  }

  if (-not $AllowConsoleFallback) {
    throw "A graphical password dialog is not available in this session, and console password prompting is disabled by default because it can hide or distort what you typed. Rerun setup from a normal desktop PowerShell session, pass -LinuxPassword, or explicitly use -AllowConsolePasswordPrompt if you accept the console fallback."
  }

  Write-Output "Password entry is hidden in PowerShell. To avoid accidental extra characters, switch to an English keyboard/input mode and use visible ASCII characters only."

  while ($true) {
    $passwordSecure = Read-Host -AsSecureString -Prompt "Enter a password for Linux user '$LinuxUser'"
    $confirmSecure = Read-Host -AsSecureString -Prompt "Confirm the password for Linux user '$LinuxUser'"
    $passwordText = Convert-SecureStringToPlainText -SecureString $passwordSecure
    $confirmText = Convert-SecureStringToPlainText -SecureString $confirmSecure

    $validationError = Get-LinuxPasswordValidationError -CandidateText $passwordText
    if ($validationError) {
      Write-Warning $validationError
      continue
    }

    if ($passwordText -ne $confirmText) {
      Write-Warning "The Linux password entries did not match. Try again."
      continue
    }

    return $passwordSecure
  }
}

function Read-OrCreate-SetupProfile {
  param(
    [Parameter(Mandatory = $true)][string]$DistroName,
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$DefaultLinuxUser,
    [securestring]$LinuxPassword,
    [switch]$ResetLinuxPassword
  )

  $defaults = Get-DefaultSetupProfile -DefaultLinuxUser $DefaultLinuxUser

  $config = $null
  if (Test-LinuxPathPresent -DistroName $DistroName -Path $Path) {
    try {
      $config = Read-LinuxTextFile -DistroName $DistroName -Path $Path | ConvertFrom-Json
    } catch {
      throw "Could not read setup metadata from $Path inside distro '$DistroName'. $($_.Exception.Message)"
    }
  }

  $linuxUser = if ($config -and ($config.PSObject.Properties.Name -contains "linuxUser") -and -not [string]::IsNullOrWhiteSpace($config.linuxUser)) {
    [string]$config.linuxUser
  } else {
    $defaults.linuxUser
  }

  if ($linuxUser -notmatch '^[a-z_][a-z0-9_-]*$') {
    throw "linuxUser in $Path must match the standard Linux account pattern [a-z_][a-z0-9_-]*."
  }

  $normalizedConfig = [ordered]@{
    linuxUser = $linuxUser
  }

  $shouldWrite = -not $config
  if ($config) {
    $shouldWrite = $shouldWrite -or -not ($config.PSObject.Properties.Name -contains "linuxUser")
    $shouldWrite = $shouldWrite -or ($config.linuxUser -ne $linuxUser)
    $shouldWrite = $shouldWrite -or ($config.PSObject.Properties.Name -contains "linuxPassword")
  }

  if ($shouldWrite) {
    $json = $normalizedConfig | ConvertTo-Json -Depth 8 -Compress
    Write-LinuxTextFile -DistroName $DistroName -Path $Path -Text $json -DirectoryMode "700" -FileMode "600"
  }

  $passwordSecure = $null
  $promptedForPassword = $false
  $passwordActionMessage = $null
  $userAlreadyPresent = Test-LinuxUserPresent -DistroName $DistroName -LinuxUser $linuxUser
  if ($PSBoundParameters.ContainsKey("LinuxPassword")) {
    $providedCandidateText = Convert-SecureStringToPlainText -SecureString $LinuxPassword
    $validationError = Get-LinuxPasswordValidationError -CandidateText $providedCandidateText
    if ($validationError) {
      throw $validationError
    }
    $passwordSecure = $LinuxPassword
  } elseif ($ResetLinuxPassword -or -not $userAlreadyPresent) {
    if ($ResetLinuxPassword) {
      $passwordActionMessage = "Resetting the Linux password for user '$linuxUser'."
    } else {
      $passwordActionMessage = "No password is set through this repository yet for Linux user '$linuxUser'. Setup will prompt for one now."
    }
    $passwordSecure = Read-InteractiveLinuxPassword -LinuxUser $linuxUser -AllowConsoleFallback:$AllowConsolePasswordPrompt
    $promptedForPassword = $true
  }

  return [pscustomobject]@{
    Path = $Path
    LinuxUser = $linuxUser
    PasswordSecure = $passwordSecure
    Created = -not $config
    Updated = $shouldWrite -and $config
    PromptedForPassword = $promptedForPassword
    PasswordActionMessage = $passwordActionMessage
    UserAlreadyPresent = $userAlreadyPresent
  }
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

function Get-LinuxPasswordHash {
  param(
    [Parameter(Mandatory = $true)][string]$DistroName,
    [Parameter(Mandatory = $true)][securestring]$PasswordSecure,
    [string]$Salt
  )

  $plainPassword = Convert-SecureStringToPlainText -SecureString $PasswordSecure
  $opensslArguments = @("--distribution", $DistroName, "--user", "root", "--exec", "/usr/bin/openssl", "passwd", "-6")
  if (-not [string]::IsNullOrWhiteSpace($Salt)) {
    $opensslArguments += @("-salt", $Salt)
  }
  $opensslArguments += $plainPassword

  $mkpasswdArguments = @("--distribution", $DistroName, "--user", "root", "--exec", "/usr/bin/mkpasswd", "-m", "sha-512")
  if (-not [string]::IsNullOrWhiteSpace($Salt)) {
    $mkpasswdArguments += @("-S", $Salt)
  }
  $mkpasswdArguments += $plainPassword

  $hashGenerators = @(
    @{
      Description = "Generate password hash with openssl in distro '$DistroName'"
      Arguments = $opensslArguments
      Prefix = '$6$'
    },
    @{
      Description = "Generate password hash with mkpasswd in distro '$DistroName'"
      Arguments = $mkpasswdArguments
      Prefix = '$6$'
    }
  )

  foreach ($generator in $hashGenerators) {
    try {
      $passwordHash = Invoke-NativeCommand -FilePath "wsl.exe" -Arguments $generator.Arguments -Description $generator.Description
      $passwordHashText = (@($passwordHash) -join "").Trim()
      if (-not [string]::IsNullOrWhiteSpace($passwordHashText) -and $passwordHashText.StartsWith($generator.Prefix)) {
        return $passwordHashText
      }
    } catch {
      Write-Verbose $_.Exception.Message
    }
  }

  throw "Could not generate a usable SHA-512 password hash in distro '$DistroName'. Install /usr/bin/openssl or /usr/bin/mkpasswd inside the distro and rerun setup."
}

function Test-LinuxPasswordMatchesStoredHash {
  param(
    [Parameter(Mandatory = $true)][string]$DistroName,
    [Parameter(Mandatory = $true)][string]$LinuxUser,
    [Parameter(Mandatory = $true)][securestring]$PasswordSecure
  )

  $quotedLinuxUser = ConvertTo-LinuxSingleQuotedText -Text $LinuxUser
  $readShadowCommand = "/usr/bin/getent shadow $quotedLinuxUser | /usr/bin/cut -d: -f2"
  $shadowHash = Invoke-NativeCommand -FilePath "wsl.exe" -Arguments @("--distribution", $DistroName, "--user", "root", "--exec", "/bin/sh", "-lc", $readShadowCommand) -Description "Read password hash for Linux user '$LinuxUser'"
  $shadowHashText = (@($shadowHash) -join "").Trim()
  if ([string]::IsNullOrWhiteSpace($shadowHashText) -or $shadowHashText -eq "!" -or $shadowHashText -eq "*") {
    throw "Linux user '$LinuxUser' does not have a usable password hash after setup."
  }

  if ($shadowHashText -notmatch '^\$6\$([^$]+)\$') {
    throw "Linux user '$LinuxUser' does not have a SHA-512 password hash after setup."
  }

  $storedSalt = $matches[1]
  $candidateHash = Get-LinuxPasswordHash -DistroName $DistroName -PasswordSecure $PasswordSecure -Salt $storedSalt
  return $candidateHash -eq $shadowHashText
}

function Invoke-LinuxShadowPasswordHashUpdate {
  param(
    [Parameter(Mandatory = $true)][string]$DistroName,
    [Parameter(Mandatory = $true)][string]$LinuxUser,
    [Parameter(Mandatory = $true)][string]$ShadowHashText
  )

  Invoke-NativeCommand -FilePath "wsl.exe" -Arguments @(
    "--distribution", $DistroName,
    "--user", "root",
    "--exec", "/usr/sbin/usermod",
    "--password",
    $ShadowHashText,
    $LinuxUser
  ) -Description "Apply password hash to Linux user '$LinuxUser'"
}

function Set-LinuxUserConfigured {
  [CmdletBinding(SupportsShouldProcess = $true)]
  param(
    [Parameter(Mandatory = $true)][string]$DistroName,
    [Parameter(Mandatory = $true)][string]$LinuxUser,
    [securestring]$PasswordSecure
  )

  if ($PSCmdlet.ShouldProcess($LinuxUser, "Configure Linux user in $DistroName")) {
    $userAlreadyPresent = Test-LinuxUserPresent -DistroName $DistroName -LinuxUser $LinuxUser
    if (-not $userAlreadyPresent) {
      if (-not $PSBoundParameters.ContainsKey("PasswordSecure")) {
        throw "A password must be supplied when creating Linux user '$LinuxUser'."
      }
      Invoke-NativeCommand -FilePath "wsl.exe" -Arguments @("--distribution", $DistroName, "--user", "root", "--exec", "/usr/sbin/useradd", "--create-home", "--shell", "/bin/bash", "--groups", "sudo", $LinuxUser) -Description "Create Linux user '$LinuxUser'"
    } else {
      Invoke-NativeCommand -FilePath "wsl.exe" -Arguments @("--distribution", $DistroName, "--user", "root", "--exec", "/usr/sbin/usermod", "--shell", "/bin/bash", "--append", "--groups", "sudo", $LinuxUser) -Description "Refresh Linux user '$LinuxUser'"
    }

    if ($PSBoundParameters.ContainsKey("PasswordSecure")) {
      $passwordHash = Get-LinuxPasswordHash -DistroName $DistroName -PasswordSecure $PasswordSecure
      Invoke-LinuxShadowPasswordHashUpdate -DistroName $DistroName -LinuxUser $LinuxUser -ShadowHashText $passwordHash
      if (-not (Test-LinuxPasswordMatchesStoredHash -DistroName $DistroName -LinuxUser $LinuxUser -PasswordSecure $PasswordSecure)) {
        throw "The Linux password for user '$LinuxUser' was written, but the stored shadow entry does not authenticate the value entered during setup. Retry the password step."
      }
    }
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

  Write-Host "Step 3 detail: WSL is downloading or repairing Ubuntu. This step can take several minutes on the first run."
  Invoke-NativeCommandWithHeartbeat `
    -FilePath "wsl.exe" `
    -Arguments @("--install", "-d", $DistroName, "--web-download", "--no-launch") `
    -Description "Install WSL distro '$DistroName'" `
    -HeartbeatMessage "Step 3 detail: Ubuntu installation is still running inside WSL. Please wait..." | Out-Null

  return [pscustomobject]@{
    InstalledNow = $true
    NeedsReboot = -not (Test-DistroPresent -DistroName $DistroName)
  }
}

function Get-LinuxPackageInstallScriptContent {
  param(
    [Parameter(Mandatory = $true)][string]$TemplatePath,
    [Parameter(Mandatory = $true)][string[]]$RequiredBasePackages,
    [Parameter(Mandatory = $true)][string[]]$BootstrapPackages
  )

  $templateSource = Read-TextFileIfPresent -Path $TemplatePath
  if ($null -eq $templateSource) {
    throw "Linux package install template is missing: $TemplatePath"
  }

  $requiredPackageTokenList = ConvertTo-LinuxPackageTokenList -PackageNames $RequiredBasePackages
  $bootstrapPackageTokenList = ConvertTo-LinuxPackageTokenList -PackageNames $BootstrapPackages
  return ($templateSource.Replace("__REQUIRED_BASE_PACKAGES__", $requiredPackageTokenList).
    Replace("__BOOTSTRAP_PACKAGES__", $bootstrapPackageTokenList))
}

function Install-LinuxBootstrapPackages {
  param(
    [Parameter(Mandatory = $true)][string]$DistroName,
    [Parameter(Mandatory = $true)][string]$TemplatePath,
    [Parameter(Mandatory = $true)][string[]]$RequiredBasePackages,
    [Parameter(Mandatory = $true)][string[]]$BootstrapPackages
  )

  $scriptPath = "/var/lib/wslssh-lan/install-bootstrap-packages.sh"
  $scriptContent = Get-LinuxPackageInstallScriptContent -TemplatePath $TemplatePath -RequiredBasePackages $RequiredBasePackages -BootstrapPackages $BootstrapPackages
  Write-LinuxTextFile -DistroName $DistroName -Path $scriptPath -Text $scriptContent -DirectoryMode "700" -FileMode "700"

  $output = Invoke-NativeCommandWithHeartbeat `
    -FilePath "wsl.exe" `
    -Arguments @("--distribution", $DistroName, "--user", "root", "--exec", "/bin/sh", $scriptPath) `
    -Description "Install Ubuntu bootstrap packages" `
    -HeartbeatMessage "Step 6 detail: Ubuntu package installation is still running inside WSL. Please wait..."

  foreach ($line in $output) {
    if (-not [string]::IsNullOrWhiteSpace($line)) {
      Write-Output $line
    }
  }
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
    [Parameter(Mandatory = $true)][string]$TypeDefinitionTemplatePath,
    [Parameter(Mandatory = $true)][string]$PowerShellScriptTemplatePath,
    [Parameter(Mandatory = $true)][string]$DistroName,
    [Parameter(Mandatory = $true)][int]$Port,
    [Parameter(Mandatory = $true)][int]$IdleShutdownSeconds,
    [Parameter(Mandatory = $true)][string]$PreferredListenAddress,
    [Parameter(Mandatory = $true)][string]$PreferredInterfaceAlias
  )

  $typeDefinitionSource = Read-TextFileIfPresent -Path $TypeDefinitionTemplatePath
  if ($null -eq $typeDefinitionSource) {
    throw "Relay C# type definition template is missing: $TypeDefinitionTemplatePath"
  }

  $relayScriptSource = Read-TextFileIfPresent -Path $PowerShellScriptTemplatePath
  if ($null -eq $relayScriptSource) {
    throw "Relay PowerShell script template is missing: $PowerShellScriptTemplatePath"
  }

  $renderedTypeDefinition = ($typeDefinitionSource.Replace("__DISTRO__", $DistroName).
    Replace("__PORT__", $Port.ToString()).
    Replace("__IDLE_TIMEOUT__", $IdleShutdownSeconds.ToString()).
    Replace("__PREFERRED_ADDRESS__", (ConvertTo-TemplateTokenValue -Text $PreferredListenAddress)).
    Replace("__PREFERRED_ALIAS__", (ConvertTo-TemplateTokenValue -Text $PreferredInterfaceAlias)).
    Replace("__LOG_PATH__", (ConvertTo-TemplateTokenValue -Text "C:\ProgramData\WslSshLan\WslSshRelay.log")))

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
    [AllowNull()]$SshdStartupType,
    [Parameter(Mandatory = $true)][bool]$SshdWasRunning,
    [AllowNull()]$PreviewRuleEnabled,
    [AllowNull()]$StableRuleEnabled,
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
$linuxPackageInstallTemplatePath = Join-Path $scriptRoot $manifest.linuxPackageInstallTemplatePath
$relayTypeDefinitionTemplatePath = Join-Path $scriptRoot $manifest.relayTypeDefinitionTemplatePath
$relayPowerShellScriptTemplatePath = Join-Path $scriptRoot $manifest.relayPowerShellScriptTemplatePath
if (-not (Test-Path -LiteralPath $setupDefaultsPath)) {
  throw "Setup defaults file is missing: $setupDefaultsPath"
}
if (-not (Test-Path -LiteralPath $linuxSecurityProfilePath)) {
  throw "Linux security profile file is missing: $linuxSecurityProfilePath"
}
if (-not (Test-Path -LiteralPath $linuxPackageInstallTemplatePath)) {
  throw "Linux package install template file is missing: $linuxPackageInstallTemplatePath"
}
if (-not (Test-Path -LiteralPath $relayTypeDefinitionTemplatePath)) {
  throw "Relay C# type definition template file is missing: $relayTypeDefinitionTemplatePath"
}
if (-not (Test-Path -LiteralPath $relayPowerShellScriptTemplatePath)) {
  throw "Relay PowerShell script template file is missing: $relayPowerShellScriptTemplatePath"
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
if (-not ($manifest.PSObject.Properties.Name -contains "linuxBootstrapPackages") -or -not $manifest.linuxBootstrapPackages) {
  throw "manifest.json is missing 'linuxBootstrapPackages'."
}
$defaultLinuxUser = [string]$setupDefaults.defaultLinuxUser
$linuxBootstrapPackages = [string[]]$manifest.linuxBootstrapPackages

$stateDir = Join-Path $scriptRoot "state"
$statePath = Join-Path $stateDir "setup-state.json"
$programDataDir = Split-Path -Parent $manifest.programDataScriptPath
$programDataScriptPath = $manifest.programDataScriptPath
$linuxSetupConfigPath = $manifest.linuxSetupConfigPath
$legacyProgramDataScriptPath = Join-Path $programDataDir "Update-WslSshLan.ps1"
$wslConfigPath = Join-Path $env:USERPROFILE ".wslconfig"
$wslConfigHadExistingFile = Test-Path -LiteralPath $wslConfigPath
$wslConfigBackupContent = Read-TextFileIfPresent -Path $wslConfigPath

Write-SetupStatus -Step 1 -Message "Checking Windows prerequisites and WSL features."
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

Write-SetupStatus -Step 2 -Message "Selecting the Windows LAN address and preparing local state."
New-Item -ItemType Directory -Path $stateDir -Force | Out-Null

if ($rebootNeeded) {
  New-Item -ItemType Directory -Path $programDataDir -Force | Out-Null
  $relayScript = Get-RelayScriptContent -TypeDefinitionTemplatePath $relayTypeDefinitionTemplatePath -PowerShellScriptTemplatePath $relayPowerShellScriptTemplatePath -DistroName $manifest.distroName -Port $manifest.sshPort -IdleShutdownSeconds $manifest.relayIdleShutdownSeconds -PreferredListenAddress $ListenAddress -PreferredInterfaceAlias $ListenInterfaceAlias
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

  Complete-SetupStatus -Message "WSL features were enabled. Reboot Windows, then rerun this script to finish installing the distro and starting the relay."
  return
}

Write-SetupStatus -Step 3 -Message "Installing or repairing the managed Ubuntu WSL distro."
$wslInstallResult = Install-WslUbuntuDistro -DistroName $manifest.distroName
$wslInstalledBySetup = $wslInstallResult.InstalledNow
if ($wslInstallResult.NeedsReboot) {
  Complete-SetupStatus -Message "Ubuntu was staged by WSL. Reboot Windows, then rerun this script to finish bootstrapping the distro."
  return
}

try {
  if ($distroAlreadyExists) {
    Write-Output "Existing WSL distro '$($manifest.distroName)' detected. Repairing in place."
  }
  Write-SetupStatus -Step 4 -Message "Loading Linux user metadata and resolving password setup behavior."
  $setupProfileParams = @{
    DistroName = $manifest.distroName
    Path = $linuxSetupConfigPath
    DefaultLinuxUser = $defaultLinuxUser
    ResetLinuxPassword = $ResetLinuxPassword
  }
  if ($PSBoundParameters.ContainsKey("LinuxPassword")) {
    $setupProfileParams.LinuxPassword = $LinuxPassword
  }
  $setupCredentials = Read-OrCreate-SetupProfile @setupProfileParams
  $linuxUser = $setupCredentials.LinuxUser

  if ($setupCredentials.Created) {
    Write-Output "Created Linux setup metadata at $linuxSetupConfigPath."
  }
  if ($setupCredentials.Updated) {
    Write-Output "Updated Linux setup metadata at $linuxSetupConfigPath."
  }
  if ($setupCredentials.PasswordActionMessage) {
    Write-Output $setupCredentials.PasswordActionMessage
  }
  if ($setupCredentials.PromptedForPassword) {
    Write-Output "Captured a Linux password interactively for user '$linuxUser'."
  }

  Write-SetupStatus -Step 5 -Message "Creating or refreshing the Linux user account."
  $setLinuxUserParams = @{
    DistroName = $manifest.distroName
    LinuxUser = $linuxUser
  }
  if ($null -ne $setupCredentials.PasswordSecure) {
    $setLinuxUserParams.PasswordSecure = $setupCredentials.PasswordSecure
  }
  Set-LinuxUserConfigured @setLinuxUserParams
  Write-SetupStatus -Step 6 -Message "Installing required Ubuntu packages and writing Linux-side WSL and SSH configuration."
  Install-LinuxBootstrapPackages -DistroName $manifest.distroName -TemplatePath $linuxPackageInstallTemplatePath -RequiredBasePackages @("apt") -BootstrapPackages $linuxBootstrapPackages
  Initialize-LinuxBootstrapConfiguration -DistroName $manifest.distroName -LinuxUser $linuxUser -SshPort $manifest.sshPort -SecurityProfile $linuxSecurityProfile
  Invoke-NativeCommand -FilePath "wsl.exe" -Arguments @("--shutdown") -Description "Apply Linux bootstrap configuration"

  Write-SetupStatus -Step 7 -Message "Disabling conflicting Windows SSH settings and cleaning old relay state."
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
  Write-SetupStatus -Step 8 -Message "Rendering the relay script, writing .wslconfig, and updating the firewall rule."
  New-Item -ItemType Directory -Path $programDataDir -Force | Out-Null
  $relayScript = Get-RelayScriptContent -TypeDefinitionTemplatePath $relayTypeDefinitionTemplatePath -PowerShellScriptTemplatePath $relayPowerShellScriptTemplatePath -DistroName $manifest.distroName -Port $manifest.sshPort -IdleShutdownSeconds $manifest.relayIdleShutdownSeconds -PreferredListenAddress $ListenAddress -PreferredInterfaceAlias $ListenInterfaceAlias
  [System.IO.File]::WriteAllText($programDataScriptPath, $relayScript, [System.Text.UTF8Encoding]::new($false))
  $programDataScriptCreated = $true

  [System.IO.File]::WriteAllLines($wslConfigPath, [string[]](Get-WslConfigContent -MemoryLimit $manifest.wslMemoryLimit -VmIdleTimeoutMs $manifest.vmIdleTimeoutMs), [System.Text.UTF8Encoding]::new($false))
  $wslConfigCreated = $true
  Set-ManagedFirewallRule -Port $manifest.sshPort
  $managedFirewallRuleChanged = $true

  Write-SetupStatus -Step 9 -Message "Registering and starting the Windows relay task."
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

  Complete-SetupStatus -Message "Setup complete."
  Write-Output "ListenAddress: $ListenAddress"
  Write-Output "ListenInterfaceAlias: $ListenInterfaceAlias"
  Write-Output "Distro: $($manifest.distroName)"
  Write-Output "SSH: ssh -p $($manifest.sshPort) $linuxUser@$ListenAddress"
}
catch {
  Write-Progress -Activity "Setting up WSL Ubuntu SSH" -Status "Setup failed." -Completed
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
