<#
.SYNOPSIS
    Installs the WslDiskSpace module for the current user.

.DESCRIPTION
    Copies the module into the user's module folder of Windows PowerShell and,
    if installed, PowerShell 7. Every new session then knows the command
    Optimize-WslDiskSpace, including tab completion for its parameters and for
    the names of the installed WSL distributions.

    If the execution policy would block the module, the installer offers to
    set it to RemoteSigned for the current user.

.PARAMETER Uninstall
    Removes the module again.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Install.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Install.ps1 -Uninstall
#>
[CmdletBinding()]
param(
    [switch] $Uninstall
)

$ErrorActionPreference = 'Continue'

#region Helpers

function Get-PowerShellEdition {
    # Both editions keep their user modules in separate folders under Documents
    # (which may have been moved, e.g. into OneDrive).
    $documentsPath = [Environment]::GetFolderPath('MyDocuments')

    [pscustomobject]@{
        Name           = 'Windows PowerShell'
        ExecutablePath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        ModulesPath    = Join-Path $documentsPath 'WindowsPowerShell\Modules'
    }

    $powerShellCorePath = if ($PSVersionTable.PSEdition -eq 'Core') {
        Join-Path $PSHOME 'pwsh.exe'
    }
    else {
        (Get-Command -Name 'pwsh.exe' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1).Source
    }
    if ($powerShellCorePath) {
        [pscustomobject]@{
            Name           = 'PowerShell 7'
            ExecutablePath = $powerShellCorePath
            ModulesPath    = Join-Path $documentsPath 'PowerShell\Modules'
        }
    }
}

function Invoke-EditionCommand {
    # Runs a command in a fresh session of the given edition and returns its last output line.
    param(
        [Parameter(Mandatory)] [pscustomobject] $Edition,
        [Parameter(Mandatory)] [string] $Command
    )

    # An encoded command avoids every quoting issue when passing the command on.
    $encodedCommand = [Convert]::ToBase64String(
        [System.Text.Encoding]::Unicode.GetBytes("`$ProgressPreference = 'SilentlyContinue'; $Command"))

    # '-ExecutionPolicy Bypass' of this installer is stored in an environment variable,
    # which the child would inherit. Without it, the child sees the policy of a normal session.
    $previousPolicyPreference = $env:PSExecutionPolicyPreference
    try {
        $env:PSExecutionPolicyPreference = $null
        $output = & $Edition.ExecutablePath -NoProfile -NonInteractive -EncodedCommand $encodedCommand 2>$null
    }
    finally {
        $env:PSExecutionPolicyPreference = $previousPolicyPreference
    }

    @($output | Where-Object { $_ -is [string] }) | Select-Object -Last 1
}

#endregion

#region Main

$moduleName = 'WslDiskSpace'
$moduleFileNames = @("$moduleName.psd1", "$moduleName.psm1")
$editions = @(Get-PowerShellEdition)

if ($Uninstall) {
    foreach ($edition in $editions) {
        $moduleDirectory = Join-Path $edition.ModulesPath $moduleName
        if (Test-Path -LiteralPath $moduleDirectory) {
            Remove-Item -LiteralPath $moduleDirectory -Recurse -Force
            Write-Host "Removed from $($edition.Name): $moduleDirectory"
        }
    }
    return
}

foreach ($moduleFileName in $moduleFileNames) {
    if (-not (Test-Path -LiteralPath (Join-Path $PSScriptRoot $moduleFileName))) {
        throw "$moduleFileName was not found next to Install.ps1."
    }
}

Write-Host 'Installing the module' -ForegroundColor Cyan
$sourceDirectory = [System.IO.Path]::GetFullPath($PSScriptRoot).TrimEnd([System.IO.Path]::DirectorySeparatorChar)
foreach ($edition in $editions) {
    $moduleDirectory = Join-Path $edition.ModulesPath $moduleName
    # When Install.ps1 is started from the installed module folder itself, the clean copy
    # would delete its own source files.
    $isSourceDirectory = [string]::Equals(
        [System.IO.Path]::GetFullPath($moduleDirectory).TrimEnd([System.IO.Path]::DirectorySeparatorChar),
        $sourceDirectory,
        [System.StringComparison]::OrdinalIgnoreCase)

    if (-not $isSourceDirectory) {
        # A clean copy, so no files of an older version linger.
        if (Test-Path -LiteralPath $moduleDirectory) {
            Remove-Item -LiteralPath $moduleDirectory -Recurse -Force
        }
        $null = New-Item -ItemType Directory -Path $moduleDirectory -Force
        foreach ($moduleFileName in $moduleFileNames) {
            Copy-Item -LiteralPath (Join-Path $PSScriptRoot $moduleFileName) -Destination $moduleDirectory
        }
    }
    # Downloaded files carry a "from the internet" mark, which RemoteSigned refuses to load.
    Get-ChildItem -LiteralPath $moduleDirectory -File | Unblock-File
    Write-Host "  $($edition.Name): $moduleDirectory"
}

$blockingPolicies = @('Restricted', 'AllSigned')
$blockedEditions = @($editions | Where-Object {
    $blockingPolicies -contains (Invoke-EditionCommand -Edition $_ -Command '(Get-ExecutionPolicy).ToString()')
})
if ($blockedEditions.Count -gt 0) {
    Write-Host ''
    Write-Warning "The execution policy blocks locally installed modules in: $(($blockedEditions | ForEach-Object Name) -join ', ')."
    $confirmation = Read-Host 'Set it to RemoteSigned for the current user (the usual setting on developer machines)? [y/N]'
    if ($confirmation -match '^(y|yes|j|ja)$') {
        foreach ($edition in $blockedEditions) {
            $null = Invoke-EditionCommand -Edition $edition -Command 'Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned -Force'
        }
    }
}

Write-Host ''
Write-Host 'Checking the installation' -ForegroundColor Cyan
foreach ($edition in $editions) {
    $manifestPath = Join-Path (Join-Path $edition.ModulesPath $moduleName) "$moduleName.psd1"
    $escapedManifestPath = $manifestPath -replace "'", "''"
    $importResult = Invoke-EditionCommand -Edition $edition `
        -Command "try { Import-Module -Name '$escapedManifestPath' -ErrorAction Stop; 'ready' } catch { `$_.Exception.Message }"

    if ($importResult -eq 'ready') {
        Write-Host "  $($edition.Name): ready" -ForegroundColor Green
    }
    else {
        Write-Warning "$($edition.Name): the module cannot be loaded. $importResult"
    }
}

Write-Host ''
Write-Host 'Open a new terminal, type Optimize-Ws and press Tab.'
Write-Host 'Use a normal terminal: the compaction asks for administrator rights itself.'

#endregion
