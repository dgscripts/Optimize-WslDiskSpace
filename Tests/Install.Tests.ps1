# Pester 5.1 or later. Run from the repository root: Invoke-Pester -Path .\Tests
# Only the functions of Install.ps1 are loaded: running its script body would install the module.

BeforeAll {
    $tokens = $null
    $parseErrors = $null
    $scriptAst = [System.Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $PSScriptRoot '..\Install.ps1'), [ref]$tokens, [ref]$parseErrors)
    foreach ($functionAst in $scriptAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
        . ([scriptblock]::Create($functionAst.Extent.Text))
    }

    function New-TestCheckout {
        param([string] $Path)

        $null = New-Item -ItemType Directory -Path (Join-Path $Path '.git') -Force
        foreach ($fileName in 'WslDiskSpace.psd1', 'WslDiskSpace.psm1', 'Install.ps1') {
            Set-Content -LiteralPath (Join-Path $Path $fileName) -Value "# $fileName"
        }
        Get-Item -LiteralPath $Path
    }

    $script:moduleFileNames = @('WslDiskSpace.psd1', 'WslDiskSpace.psm1')
    $script:edition = [pscustomobject]@{
        Name           = 'Windows PowerShell'
        ExecutablePath = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
        ModulesPath    = 'C:\Docs\WindowsPowerShell\Modules'
    }
}

Describe 'Test-IsSourceCheckout' {
    It 'recognizes a folder with <Marker> as a checkout' -ForEach @(
        @{ Marker = 'Install.ps1' }
        @{ Marker = '.git' }
    ) {
        $checkout = New-Item -ItemType Directory -Path (Join-Path $TestDrive "checkout-$Marker") -Force
        $null = New-Item -ItemType File -Path (Join-Path $checkout.FullName $Marker) -Force

        Test-IsSourceCheckout -Path $checkout.FullName | Should -BeTrue
    }

    It 'does not take an installed copy for a checkout' {
        $installed = New-Item -ItemType Directory -Path (Join-Path $TestDrive 'installed') -Force
        Set-Content -LiteralPath (Join-Path $installed.FullName 'WslDiskSpace.psd1') -Value '@{}'

        Test-IsSourceCheckout -Path $installed.FullName | Should -BeFalse
    }
}

Describe 'Install-ModuleFolder' {
    It 'copies the module files into a new folder' {
        $checkout = New-TestCheckout -Path (Join-Path $TestDrive 'source-new')
        $target = Join-Path $TestDrive 'documents-new\WindowsPowerShell\Modules\WslDiskSpace'

        Install-ModuleFolder -SourceDirectory $checkout.FullName -TargetDirectory $target -FileNames $script:moduleFileNames |
            Should -BeExactly 'Installed'
        @(Get-ChildItem -LiteralPath $target -Name | Sort-Object) | Should -Be $script:moduleFileNames
    }

    It 'replaces an earlier installation with a clean copy' {
        $checkout = New-TestCheckout -Path (Join-Path $TestDrive 'source-update')
        $target = New-Item -ItemType Directory -Path (Join-Path $TestDrive 'documents-update\WindowsPowerShell\Modules\WslDiskSpace') -Force
        Set-Content -LiteralPath (Join-Path $target.FullName 'Removed.ps1') -Value '# from an older version'

        Install-ModuleFolder -SourceDirectory $checkout.FullName -TargetDirectory $target.FullName -FileNames $script:moduleFileNames |
            Should -BeExactly 'Installed'
        @(Get-ChildItem -LiteralPath $target.FullName -Name | Sort-Object) | Should -Be $script:moduleFileNames
    }

    It 'leaves a checkout alone that the module folder leads to through a junction' {
        # Regression: behind a junction, mapped drive or UNC path the clean copy deleted the checkout.
        $checkout = New-TestCheckout -Path (Join-Path $TestDrive 'source-junction')
        $modules = New-Item -ItemType Directory -Path (Join-Path $TestDrive 'documents-junction\WindowsPowerShell\Modules') -Force
        $target = Join-Path $modules.FullName 'WslDiskSpace'
        $null = New-Item -ItemType Junction -Path $target -Target $checkout.FullName

        Install-ModuleFolder -SourceDirectory $checkout.FullName -TargetDirectory $target -FileNames $script:moduleFileNames |
            Should -BeExactly 'SourceCheckout'
        Test-Path -LiteralPath (Join-Path $checkout.FullName '.git') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $checkout.FullName 'Install.ps1') | Should -BeTrue
    }

    It 'keeps a checkout that lies in a subfolder of the module folder' {
        # Regression: the clean copy removed the whole module folder, a checkout inside it included.
        $target = New-Item -ItemType Directory -Path (Join-Path $TestDrive 'documents-nested\WindowsPowerShell\Modules\WslDiskSpace') -Force
        $checkout = New-TestCheckout -Path (Join-Path $target.FullName 'Optimize-WslDiskSpace')

        Install-ModuleFolder -SourceDirectory $checkout.FullName -TargetDirectory $target.FullName -FileNames $script:moduleFileNames |
            Should -BeExactly 'Installed'
        Test-Path -LiteralPath (Join-Path $checkout.FullName '.git') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $target.FullName 'WslDiskSpace.psm1') | Should -BeTrue
    }

    It 'updates a module folder that another process uses as its working directory' {
        # Regression: that process kept the folder from being deleted, and the update left it empty.
        $checkout = New-TestCheckout -Path (Join-Path $TestDrive 'source-locked')
        $target = New-Item -ItemType Directory -Path (Join-Path $TestDrive 'documents-locked\WindowsPowerShell\Modules\WslDiskSpace') -Force
        Set-Content -LiteralPath (Join-Path $target.FullName 'WslDiskSpace.psm1') -Value '# old'
        $process = Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\PING.EXE') -ArgumentList '-n 30 127.0.0.1' `
            -WorkingDirectory $target.FullName -WindowStyle Hidden -PassThru
        try {
            Install-ModuleFolder -SourceDirectory $checkout.FullName -TargetDirectory $target.FullName -FileNames $script:moduleFileNames |
                Should -BeExactly 'Installed'
            Get-Content -LiteralPath (Join-Path $target.FullName 'WslDiskSpace.psm1') | Should -BeExactly '# WslDiskSpace.psm1'
        }
        finally {
            Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
            $process.WaitForExit()
        }
    }

    It 'fails instead of reporting success when a file cannot be copied' {
        # Regression: a failed copy still listed the folder as installed.
        $source = New-Item -ItemType Directory -Path (Join-Path $TestDrive 'source-incomplete') -Force
        Set-Content -LiteralPath (Join-Path $source.FullName 'WslDiskSpace.psd1') -Value '@{}'
        $target = Join-Path $TestDrive 'documents-incomplete\WindowsPowerShell\Modules\WslDiskSpace'

        { Install-ModuleFolder -SourceDirectory $source.FullName -TargetDirectory $target -FileNames $script:moduleFileNames } |
            Should -Throw -ErrorId 'PathNotFound,Microsoft.PowerShell.Commands.CopyItemCommand'
    }
}

Describe 'Uninstall-ModuleFolder' {
    It 'removes an installed copy' {
        $installed = New-Item -ItemType Directory -Path (Join-Path $TestDrive 'remove\WslDiskSpace') -Force
        Set-Content -LiteralPath (Join-Path $installed.FullName 'WslDiskSpace.psd1') -Value '@{}'

        Uninstall-ModuleFolder -TargetDirectory $installed.FullName | Should -BeExactly 'Removed'
        Test-Path -LiteralPath $installed.FullName | Should -BeFalse
    }

    It 'reports a folder that does not exist' {
        Uninstall-ModuleFolder -TargetDirectory (Join-Path $TestDrive 'missing\WslDiskSpace') | Should -BeExactly 'NotInstalled'
    }

    It 'does not remove a checkout' {
        $checkout = New-TestCheckout -Path (Join-Path $TestDrive 'keep\WslDiskSpace')

        Uninstall-ModuleFolder -TargetDirectory $checkout.FullName | Should -BeExactly 'SourceCheckout'
        Test-Path -LiteralPath (Join-Path $checkout.FullName '.git') | Should -BeTrue
    }
}

Describe 'Get-PowerShell7Path' {
    It 'uses pwsh.exe from PATH' {
        Mock -CommandName Get-Command -ParameterFilter { $Name -eq 'pwsh.exe' } -MockWith {
            [pscustomobject]@{ Name = 'pwsh.exe'; Source = 'C:\Tools\pwsh\pwsh.exe' }
        }

        Get-PowerShell7Path -Edition 'Desktop' | Should -BeExactly 'C:\Tools\pwsh\pwsh.exe'
    }

    It 'finds PowerShell 7 in its default folder when it is not on PATH' {
        # Regression: without the PATH entry the installer skipped PowerShell 7 without a word.
        $defaultPath = Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'
        Mock -CommandName Get-Command -ParameterFilter { $Name -eq 'pwsh.exe' } -MockWith { }
        Mock -CommandName Test-Path -ParameterFilter { $LiteralPath -eq $defaultPath } -MockWith { $true }

        Get-PowerShell7Path -Edition 'Desktop' | Should -BeExactly $defaultPath
    }

    It 'reports nothing when PowerShell 7 is not installed' {
        Mock -CommandName Get-Command -ParameterFilter { $Name -eq 'pwsh.exe' } -MockWith { }
        Mock -CommandName Test-Path -ParameterFilter { $LiteralPath -like '*\pwsh.exe' } -MockWith { $false }

        Get-PowerShell7Path -Edition 'Desktop' | Should -BeNullOrEmpty
    }
}

Describe 'Get-PowerShellEdition' {
    It 'names the module folders of both editions, also when PowerShell 7 is not installed' {
        # Regression: -Uninstall left the PowerShell 7 copy behind when pwsh.exe was not found.
        Mock -CommandName Get-PowerShell7Path -MockWith { }

        $editions = @(Get-PowerShellEdition -DocumentsPath 'C:\Docs')

        $editions.ModulesPath | Should -Be @('C:\Docs\WindowsPowerShell\Modules', 'C:\Docs\PowerShell\Modules')
        $editions[0].ExecutablePath | Should -BeLike '*\WindowsPowerShell\v1.0\powershell.exe'
        $editions[1].ExecutablePath | Should -BeNullOrEmpty
    }

    It 'stops when the Documents folder cannot be determined' {
        # Regression: without a Documents path the installer did nothing and still reported success.
        Mock -CommandName Get-PowerShell7Path -MockWith { }

        { Get-PowerShellEdition -DocumentsPath '' } | Should -Throw '*Documents*'
    }
}

Describe 'Get-ExecutionPolicyBlock' {
    It 'reports nothing when the execution policy allows the module' {
        Mock -CommandName Invoke-EditionCommand -MockWith { 'Undefined|Undefined|RemoteSigned' }

        Get-ExecutionPolicyBlock -Edition $script:edition | Should -BeNullOrEmpty
    }

    It 'reports a blocking execution policy that the user can change' {
        Mock -CommandName Invoke-EditionCommand -MockWith { 'Undefined|Undefined|Restricted' }

        $block = Get-ExecutionPolicyBlock -Edition $script:edition

        $block.Policy | Should -BeExactly 'Restricted'
        $block.IsGroupPolicy | Should -BeFalse
    }

    It 'reports a blocking execution policy that Group Policy sets (<Scope>)' -ForEach @(
        @{ Scope = 'MachinePolicy'; Policies = 'AllSigned|Undefined|AllSigned' }
        @{ Scope = 'UserPolicy'; Policies = 'Undefined|AllSigned|AllSigned' }
    ) {
        # Regression: the installer offered a change that Group Policy overrides, and hid why it had no effect.
        Mock -CommandName Invoke-EditionCommand -MockWith { $Policies }

        $block = Get-ExecutionPolicyBlock -Edition $script:edition

        $block.Policy | Should -BeExactly 'AllSigned'
        $block.IsGroupPolicy | Should -BeTrue
    }
}

Describe 'Test-ModuleInstallation' {
    BeforeAll {
        $script:moduleDirectory = 'C:\Docs\WindowsPowerShell\Modules\WslDiskSpace'
    }

    It 'accepts a module that a new session loads from the installed folder' {
        Mock -CommandName Invoke-EditionCommand -MockWith { 'C:\DOCS\WindowsPowerShell\Modules\WslDiskSpace\' }

        Test-ModuleInstallation -Edition $script:edition -ModuleName 'WslDiskSpace' -ModuleDirectory $script:moduleDirectory |
            Should -BeNullOrEmpty
        Should -Invoke -CommandName Invoke-EditionCommand -Times 1 -Exactly -ParameterFilter { $Command -like '*Import-Module -Name WslDiskSpace *' }
    }

    It 'reports another copy that a new session loads instead' {
        # Regression: the check imported the module by its path, which works even where a new session cannot find it.
        Mock -CommandName Invoke-EditionCommand -MockWith { 'D:\Other\WslDiskSpace' }

        Test-ModuleInstallation -Edition $script:edition -ModuleName 'WslDiskSpace' -ModuleDirectory $script:moduleDirectory |
            Should -BeLike '*D:\Other\WslDiskSpace*'
    }

    It 'reports why the module cannot be loaded' {
        Mock -CommandName Invoke-EditionCommand -MockWith { 'ERROR: running scripts is disabled on this system' }

        Test-ModuleInstallation -Edition $script:edition -ModuleName 'WslDiskSpace' -ModuleDirectory $script:moduleDirectory |
            Should -BeLike '*running scripts is disabled*'
    }

    It 'reports a check that produced no output' {
        Mock -CommandName Invoke-EditionCommand -MockWith { }

        Test-ModuleInstallation -Edition $script:edition -ModuleName 'WslDiskSpace' -ModuleDirectory $script:moduleDirectory |
            Should -Not -BeNullOrEmpty
    }
}
