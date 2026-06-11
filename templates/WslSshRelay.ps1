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

$distroName = "__DISTRO__"
$port = "__PORT__"
$idleTimeout = "__IDLE_TIMEOUT__"
$preferredAddress = "__PREFERRED_ADDRESS__"
$preferredAlias = "__PREFERRED_ALIAS__"
$logPath = "__LOG_PATH__"

$relay = [WslSshRelay]::new($distroName, $port, $idleTimeout, $preferredAddress, $preferredAlias, $logPath)
$relay.Run()
