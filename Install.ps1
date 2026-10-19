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

    Run it from a terminal: "Run with PowerShell" in Explorer's context menu can
    be blocked by the execution policy and closes the window before the result
    can be read.

.PARAMETER Uninstall
    Removes the module again. The execution policy is left as it is.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Install.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Install.ps1 -Uninstall
#>
[CmdletBinding()]
param(
    [switch] $Uninstall
)

#region Helpers

function Get-PowerShell7Path {
    param([string] $Edition = $PSVersionTable.PSEdition)

    if ($Edition -eq 'Core') { return Join-Path $PSHOME 'pwsh.exe' }

    $pwshCommand = Get-Command -Name 'pwsh.exe' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($pwshCommand) { return $pwshCommand.Source }

    # E.g. an MSI installation without the PATH entry.
    $defaultPath = Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'
    if (Test-Path -LiteralPath $defaultPath -PathType Leaf) { return $defaultPath }
}

function Get-PowerShellEdition {
    # Both editions keep their user modules in separate folders under Documents (which may have been
    # moved, e.g. into OneDrive).
    param([string] $DocumentsPath = [Environment]::GetFolderPath('MyDocuments'))

    if (-not $DocumentsPath) { throw 'The Documents folder of this account could not be determined.' }

    [pscustomobject]@{
        Name           = 'Windows PowerShell'
        ExecutablePath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        ModulesPath    = Join-Path $DocumentsPath 'WindowsPowerShell\Modules'
    }
    [pscustomobject]@{
        Name           = 'PowerShell 7'
        ExecutablePath = Get-PowerShell7Path
        ModulesPath    = Join-Path $DocumentsPath 'PowerShell\Modules'
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

function Test-IsSourceCheckout {
    # By content: a junction, mapped drive or UNC path hides that two paths lead to the same folder.
    param([Parameter(Mandatory)] [string] $Path)

    (Test-Path -LiteralPath (Join-Path $Path 'Install.ps1')) -or (Test-Path -LiteralPath (Join-Path $Path '.git'))
}

function Install-ModuleFolder {
    # Removes the files of an older version, but not the folder: another process may use it as its
    # working directory, and it may hold a checkout in a subfolder.
    param(
        [Parameter(Mandatory)] [string] $SourceDirectory,
        [Parameter(Mandatory)] [string] $TargetDirectory,
        [Parameter(Mandatory)] [string[]] $FileNames
    )

    $status = 'SourceCheckout'
    if (-not (Test-IsSourceCheckout -Path $TargetDirectory)) {
        if (Test-Path -LiteralPath $TargetDirectory) {
            Get-ChildItem -LiteralPath $TargetDirectory -File -Force | Remove-Item -Force -ErrorAction Stop
        }
        $null = New-Item -ItemType Directory -Path $TargetDirectory -Force -ErrorAction Stop
        foreach ($fileName in $FileNames) {
            Copy-Item -LiteralPath (Join-Path $SourceDirectory $fileName) -Destination $TargetDirectory -ErrorAction Stop
        }
        $status = 'Installed'
    }

    # Downloaded files carry a "from the internet" mark, which RemoteSigned refuses to load.
    Get-ChildItem -LiteralPath $TargetDirectory -File | Unblock-File -ErrorAction Stop
    $status
}

function Uninstall-ModuleFolder {
    param([Parameter(Mandatory)] [string] $TargetDirectory)

    if (-not (Test-Path -LiteralPath $TargetDirectory)) { return 'NotInstalled' }
    if (Test-IsSourceCheckout -Path $TargetDirectory) { return 'SourceCheckout' }

    Get-ChildItem -LiteralPath $TargetDirectory -File -Force | Remove-Item -Force -ErrorAction Stop
    if (-not (Get-ChildItem -LiteralPath $TargetDirectory -Force)) {
        Remove-Item -LiteralPath $TargetDirectory -Force -ErrorAction SilentlyContinue
    }
    'Removed'
}

function Get-ExecutionPolicyBlock {
    # A policy set by Group Policy overrides any change the user makes.
    param([Parameter(Mandatory)] [pscustomobject] $Edition)

    $policies = Invoke-EditionCommand -Edition $Edition -Command (
        '@((Get-ExecutionPolicy -Scope MachinePolicy), (Get-ExecutionPolicy -Scope UserPolicy), (Get-ExecutionPolicy)) -join ''|''')
    if (-not $policies) { return }

    $machinePolicy, $userPolicy, $effectivePolicy = $policies -split '\|'
    if (@('Restricted', 'AllSigned') -notcontains $effectivePolicy) { return }

    [pscustomobject]@{
        Policy        = $effectivePolicy
        IsGroupPolicy = $machinePolicy -ne 'Undefined' -or $userPolicy -ne 'Undefined'
    }
}

function Test-ModuleInstallation {
    # By name, as a new terminal does: an import by path would also work outside PSModulePath.
    param(
        [Parameter(Mandatory)] [pscustomobject] $Edition,
        [Parameter(Mandatory)] [string] $ModuleName,
        [Parameter(Mandatory)] [string] $ModuleDirectory
    )

    $moduleBase = Invoke-EditionCommand -Edition $Edition -Command (
        "try { Import-Module -Name $ModuleName -ErrorAction Stop; (Get-Module -Name $ModuleName | Select-Object -First 1).ModuleBase } " +
        "catch { 'ERROR: ' + `$_.Exception.Message }")

    if (-not $moduleBase) { return 'the check produced no output.' }
    if ($moduleBase -like 'ERROR: *') { return "the module cannot be loaded. $($moduleBase.Substring(7))" }

    $expectedDirectory = [System.IO.Path]::GetFullPath($ModuleDirectory).TrimEnd('\')
    if ([string]::Equals($moduleBase.TrimEnd('\'), $expectedDirectory, [System.StringComparison]::OrdinalIgnoreCase)) { return }
    "a new session loads the module from $moduleBase instead. Is $(Split-Path -Parent $ModuleDirectory) missing in PSModulePath?"
}

#endregion

#region Main

$ErrorActionPreference = 'Continue'
$moduleName = 'WslDiskSpace'
$moduleFileNames = @("$moduleName.psd1", "$moduleName.psm1")
$editions = @(Get-PowerShellEdition)
$hasFailures = $false

if ($Uninstall) {
    foreach ($edition in $editions) {
        $moduleDirectory = Join-Path $edition.ModulesPath $moduleName
        try {
            switch (Uninstall-ModuleFolder -TargetDirectory $moduleDirectory) {
                'Removed' { Write-Host "Removed from $($edition.Name): $moduleDirectory" }
                'SourceCheckout' { Write-Warning "$($edition.Name): $moduleDirectory is a checkout of the source and was not removed." }
            }
        }
        catch {
            Write-Warning "$($edition.Name): $moduleDirectory could not be removed. $($_.Exception.Message)"
            $hasFailures = $true
        }
    }
    if ($hasFailures) { exit 1 }
    return
}

foreach ($moduleFileName in $moduleFileNames) {
    if (-not (Test-Path -LiteralPath (Join-Path $PSScriptRoot $moduleFileName))) {
        throw "$moduleFileName was not found next to Install.ps1."
    }
}

Write-Host 'Installing the module' -ForegroundColor Cyan
$installedEditions = @()
foreach ($edition in $editions) {
    if (-not $edition.ExecutablePath) {
        Write-Host "  $($edition.Name): pwsh.exe not found, skipped"
        continue
    }

    $moduleDirectory = Join-Path $edition.ModulesPath $moduleName
    try {
        if ((Install-ModuleFolder -SourceDirectory $PSScriptRoot -TargetDirectory $moduleDirectory -FileNames $moduleFileNames) -eq 'Installed') {
            Write-Host "  $($edition.Name): $moduleDirectory"
        }
        else {
            Write-Host "  $($edition.Name): $moduleDirectory (a checkout of the source, left unchanged)"
        }
        $installedEditions += $edition
    }
    catch {
        Write-Warning "$($edition.Name): the module could not be copied to $moduleDirectory. $($_.Exception.Message)"
        $hasFailures = $true
    }
}

$blockedEditions = @()
foreach ($edition in $installedEditions) {
    $policyBlock = Get-ExecutionPolicyBlock -Edition $edition
    if (-not $policyBlock) { continue }

    if ($policyBlock.IsGroupPolicy) {
        Write-Warning ("Group Policy sets the execution policy of $($edition.Name) to $($policyBlock.Policy), " +
            'which blocks this unsigned module there.')
    }
    else {
        $blockedEditions += $edition
    }
}
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
$readyCount = 0
foreach ($edition in $installedEditions) {
    $problem = Test-ModuleInstallation -Edition $edition -ModuleName $moduleName -ModuleDirectory (Join-Path $edition.ModulesPath $moduleName)
    if ($problem) {
        Write-Warning "$($edition.Name): $problem"
        $hasFailures = $true
    }
    else {
        Write-Host "  $($edition.Name): ready" -ForegroundColor Green
        $readyCount++
    }
}

if ($readyCount -gt 0) {
    Write-Host ''
    Write-Host 'Open a new terminal, type Optimize-Ws and press Tab.'
    Write-Host 'Use a normal terminal: the compaction asks for administrator rights itself.'
}
if ($hasFailures) { exit 1 }

#endregion
