[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

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
$setupPath = Join-Path $scriptRoot "setup-ubuntu-ssh.ps1"
$uninstallPath = Join-Path $scriptRoot "uninstall-ubuntu-ssh.ps1"

Assert-Condition -Condition (Test-Path -LiteralPath $manifestPath) -Message "manifest.json is missing."
Assert-Condition -Condition (Test-Path -LiteralPath $setupPath) -Message "setup-ubuntu-ssh.ps1 is missing."
Assert-Condition -Condition (Test-Path -LiteralPath $uninstallPath) -Message "uninstall-ubuntu-ssh.ps1 is missing."

$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
$requiredFields = @(
  "distroName",
  "linuxUser",
  "sshPort",
  "imagePath",
  "imageReleaseAssetName",
  "installPath",
  "programDataScriptPath",
  "refreshTaskName",
  "keepAliveTaskName"
)

foreach ($field in $requiredFields) {
  Assert-Condition -Condition ($manifest.PSObject.Properties.Name -contains $field) -Message "manifest.json is missing '$field'."
}

$tokens = $null
$errors = $null
$setupAst = [System.Management.Automation.Language.Parser]::ParseFile($setupPath, [ref]$tokens, [ref]$errors)
Assert-Condition -Condition ($errors.Count -eq 0) -Message "setup-ubuntu-ssh.ps1 has parse errors."

$tokens = $null
$errors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($uninstallPath, [ref]$tokens, [ref]$errors)
Assert-Condition -Condition ($errors.Count -eq 0) -Message "uninstall-ubuntu-ssh.ps1 has parse errors."

. (Get-FunctionScriptBlock -Ast $setupAst -Name "Get-GitHubRepositoryInfo")
. (Get-FunctionScriptBlock -Ast $setupAst -Name "Resolve-ReleaseAssetUrl")
. (Get-FunctionScriptBlock -Ast $setupAst -Name "Get-RefreshScriptContent")

$httpsRepo = Get-GitHubRepositoryInfo -OriginUrl "https://github.com/example/recovery-kit.git"
$sshRepo = Get-GitHubRepositoryInfo -OriginUrl "git@github.com:example/recovery-kit.git"

Assert-Condition -Condition ($httpsRepo.Owner -eq "example" -and $httpsRepo.Repo -eq "recovery-kit") -Message "HTTPS GitHub origin parsing failed."
Assert-Condition -Condition ($sshRepo.Owner -eq "example" -and $sshRepo.Repo -eq "recovery-kit") -Message "SSH GitHub origin parsing failed."

$downloadOverrideManifest = [pscustomobject]@{
  imagePath = "artifacts\\ubuntu-ssh-image.tar"
  imageReleaseAssetName = "ubuntu-ssh-image.tar"
  imageDownloadUrl = "https://example.com/placeholder.tar"
}

$resolvedOverrideUrl = Resolve-ReleaseAssetUrl -RepositoryRoot $scriptRoot -Manifest $downloadOverrideManifest
Assert-Condition -Condition ($resolvedOverrideUrl -eq $downloadOverrideManifest.imageDownloadUrl) -Message "imageDownloadUrl override was not honored."

$generatedRefreshScript = Get-RefreshScriptContent -DistroName "Ubuntu" -Port 2222 -ExpectedListenAddress "192.0.2.10"
$tokens = $null
$errors = $null
[void][System.Management.Automation.Language.Parser]::ParseInput($generatedRefreshScript, [ref]$tokens, [ref]$errors)
Assert-Condition -Condition ($errors.Count -eq 0) -Message "Generated refresh script has parse errors."

Write-Host "Repository validation passed."
