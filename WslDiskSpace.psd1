@{
    RootModule           = 'WslDiskSpace.psm1'
    ModuleVersion        = '1.1.0'
    GUID                 = '50a48844-4b0a-4a26-86e7-ad69a1ad8363'
    Author               = 'Daniel Gross'
    Copyright            = '(c) 2026 Daniel Gross. Licensed under the MIT License.'
    Description          = 'Frees disk space inside WSL 2 distributions and compacts their virtual disks.'
    PowerShellVersion    = '5.1'
    CompatiblePSEditions = @('Desktop', 'Core')
    FunctionsToExport    = @('Optimize-WslDiskSpace')
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @()
    PrivateData          = @{
        PSData = @{
            LicenseUri = 'https://github.com/dgscripts/Optimize-WslDiskSpace/blob/main/LICENSE'
            ProjectUri = 'https://github.com/dgscripts/Optimize-WslDiskSpace'
        }
    }
}
