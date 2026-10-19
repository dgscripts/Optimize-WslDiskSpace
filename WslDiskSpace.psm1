# WslDiskSpace: frees disk space inside WSL 2 distributions and compacts their virtual disks.
# The only public command is Optimize-WslDiskSpace; all other functions are internal.

$dockerDataDiskName = 'docker-desktop-data'

# Docker is pinned to the local daemon, so a remote context or DOCKER_HOST can never be pruned by accident.
$dockerEnvironmentReset = 'unset DOCKER_HOST DOCKER_CONTEXT'
$dockerAvailabilityCheck = "$dockerEnvironmentReset; command -v docker >/dev/null && docker --context default info >/dev/null"
$dockerPruneCommand = "$dockerEnvironmentReset; docker --context default system prune --all --volumes --force"

# The lock timeout covers unattended-upgrades holding the dpkg lock right after the distribution starts.
$packageCleanupCommand = 'export DEBIAN_FRONTEND=noninteractive; apt-get clean && apt-get -o DPkg::Lock::Timeout=120 autoremove --yes'
$trimCommand = 'fstrim -v / 2>/dev/null || echo fstrim not supported, skipping.'

#region Live output

function ConvertTo-CommandLineArgument {
    # Quotes an argument following the Windows command line rules (CommandLineToArgvW).
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Argument)

    if ($Argument -and $Argument -notmatch '[\s"]') { return $Argument }

    # Backslashes are only special in front of a double quote or the closing quote.
    $escapedArgument = $Argument -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1'
    "`"$escapedArgument`""
}

function Set-CursorVisibility {
    param([Parameter(Mandatory)] [bool] $Visible)

    try { [Console]::CursorVisible = $Visible }
    catch { <# Not supported by every host; the spinner works without it. #> }
}

function New-OutputRenderer {
    $consoleWidth = 0
    if (-not [Console]::IsOutputRedirected) {
        try { $consoleWidth = [Console]::WindowWidth }
        catch { <# No console attached; fall back to plain line output. #> }
    }

    $spinnerFrames = if ($env:WT_SESSION -or $env:TERM_PROGRAM -eq 'vscode') {
        # Braille frames, built from code points so the script file stays ASCII
        # (Windows PowerShell 5.1 reads files without BOM in the ANSI code page).
        @(0x280B, 0x2819, 0x2839, 0x2838, 0x283C, 0x2834, 0x2826, 0x2827, 0x2807, 0x280F |
            ForEach-Object { [string][char]$_ })
    }
    else {
        @('|', '/', '-', '\')
    }

    [pscustomobject]@{
        IsInteractive            = $consoleWidth -gt 0
        ConsoleWidth             = $consoleWidth
        SpinnerFrames            = $spinnerFrames
        Stopwatch                = [System.Diagnostics.Stopwatch]::StartNew()
        RenderedLength           = 0
        CurrentSegment           = [System.Text.StringBuilder]::new()
        LastProgressText         = ''
        HasPendingCarriageReturn = $false
    }
}

function Write-RendererStatus {
    # Draws "<spinner> <current progress text>" over the current console row.
    param([Parameter(Mandatory)] [pscustomobject] $Renderer)

    if (-not $Renderer.IsInteractive) { return }

    # The window may have been resized since the last frame.
    try { $Renderer.ConsoleWidth = [Console]::WindowWidth }
    catch { <# Keep the last known width. #> }

    $statusText = if ($Renderer.CurrentSegment.Length -gt 0) { $Renderer.CurrentSegment.ToString() } else { $Renderer.LastProgressText }
    $frameIndex = [int]([Math]::Floor($Renderer.Stopwatch.ElapsedMilliseconds / 100) % $Renderer.SpinnerFrames.Count)
    $statusLine = "  $($Renderer.SpinnerFrames[$frameIndex]) $($statusText.Trim())"

    # Longer lines would wrap, and a carriage return only rewinds the last row.
    $maximumLength = [Math]::Max(0, $Renderer.ConsoleWidth - 1)
    if ($statusLine.Length -gt $maximumLength) { $statusLine = $statusLine.Substring(0, $maximumLength) }

    Write-Host ("`r" + $statusLine.PadRight($Renderer.RenderedLength)) -NoNewline
    $Renderer.RenderedLength = $statusLine.Length
}

function Clear-RendererStatus {
    param([Parameter(Mandatory)] [pscustomobject] $Renderer)

    if ($Renderer.RenderedLength -eq 0) { return }
    Write-Host ("`r" + (' ' * $Renderer.RenderedLength) + "`r") -NoNewline
    $Renderer.RenderedLength = 0
}

function Complete-RendererLine {
    param([Parameter(Mandatory)] [pscustomobject] $Renderer)

    $line = $Renderer.CurrentSegment.ToString()
    [void]$Renderer.CurrentSegment.Clear()

    # Fallback for tools that end progress updates ("80 Prozent bearbeitet",
    # "80 percent completed") with a regular line break: keep them in the status line.
    if ($line -match '^\s*\d{1,3}\s*(%|percent|Prozent)') {
        $Renderer.LastProgressText = $line
        return
    }

    Clear-RendererStatus -Renderer $Renderer
    Write-Host ('    ' + $line)
    $Renderer.LastProgressText = ''
}

function Add-RendererText {
    # CR LF and LF complete a line. A lone CR marks a progress update that the
    # following text overwrites, so it is only ever shown in the status line.
    param(
        [Parameter(Mandatory)] [pscustomobject] $Renderer,
        [Parameter(Mandatory)] [string] $Text
    )

    $lineBreakCharacters = [char[]]"`r`n"
    $position = 0
    while ($position -lt $Text.Length) {
        if ($Renderer.HasPendingCarriageReturn) {
            $Renderer.HasPendingCarriageReturn = $false
            if ($Text[$position] -eq "`n") {
                Complete-RendererLine -Renderer $Renderer
                $position++
                continue
            }
            $Renderer.LastProgressText = $Renderer.CurrentSegment.ToString()
            [void]$Renderer.CurrentSegment.Clear()
        }

        $lineBreakIndex = $Text.IndexOfAny($lineBreakCharacters, $position)
        if ($lineBreakIndex -lt 0) {
            [void]$Renderer.CurrentSegment.Append($Text, $position, $Text.Length - $position)
            return
        }

        [void]$Renderer.CurrentSegment.Append($Text, $position, $lineBreakIndex - $position)
        if ($Text[$lineBreakIndex] -eq "`r") {
            $Renderer.HasPendingCarriageReturn = $true
        }
        else {
            Complete-RendererLine -Renderer $Renderer
        }
        $position = $lineBreakIndex + 1
    }
}

function Invoke-NativeCommand {
    # Runs a native command and streams its raw output through the renderer.
    # PowerShell's own line splitting is avoided on purpose: it treats a lone CR
    # as a line break, which turns every progress update into a new line.
    # Returns the exit code.
    param(
        [Parameter(Mandatory)] [string] $FilePath,
        [Parameter(Mandatory)] [string[]] $ArgumentList,
        [System.Text.Encoding] $StandardOutputEncoding = [Console]::OutputEncoding
    )

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new($FilePath)
    $startInfo.Arguments = @($ArgumentList | ForEach-Object { ConvertTo-CommandLineArgument -Argument $_ }) -join ' '
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.StandardOutputEncoding = $StandardOutputEncoding

    $renderer = New-OutputRenderer
    $buffer = [char[]]::new(4096)
    $process = [System.Diagnostics.Process]::Start($startInfo)
    if ($renderer.IsInteractive) { Set-CursorVisibility -Visible $false }
    try {
        while ($true) {
            $readTask = $process.StandardOutput.ReadAsync($buffer, 0, $buffer.Length)
            while (-not $readTask.Wait(100)) {
                # Keeps the spinner moving while the command is silent.
                Write-RendererStatus -Renderer $renderer
            }
            if ($readTask.Result -eq 0) { break }

            Add-RendererText -Renderer $renderer -Text ([string]::new($buffer, 0, $readTask.Result))
            Write-RendererStatus -Renderer $renderer
        }

        if ($renderer.CurrentSegment.Length -gt 0) { Complete-RendererLine -Renderer $renderer }
        $process.WaitForExit()
        return $process.ExitCode
    }
    finally {
        Clear-RendererStatus -Renderer $renderer
        if ($renderer.IsInteractive) { Set-CursorVisibility -Visible $true }
        $process.Dispose()
    }
}

#endregion

#region Helpers

function Write-Section {
    param([Parameter(Mandatory)] [string] $Title)

    Write-Host ''
    Write-Host "=== $Title ===" -ForegroundColor Cyan
}

function Format-ByteSize {
    param([Parameter(Mandatory)] [long] $ByteCount)

    '{0:N2} GB' -f ($ByteCount / 1GB)
}

function Test-IsAdministrator {
    $currentPrincipal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-WslDistribution {
    # Reading the registry avoids the UTF-16 output quirks of 'wsl --list'.
    $lxssRegistryPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss'
    if (-not (Test-Path -Path $lxssRegistryPath)) { return }

    foreach ($registryKey in Get-ChildItem -Path $lxssRegistryPath) {
        $registryValues = Get-ItemProperty -LiteralPath $registryKey.PSPath
        if (-not $registryValues.DistributionName -or -not $registryValues.BasePath) { continue }

        $basePath = $registryValues.BasePath -replace '^\\\\\?\\', ''
        $virtualDiskFileName = if ($registryValues.VhdFileName) { $registryValues.VhdFileName } else { 'ext4.vhdx' }

        [pscustomobject]@{
            Name            = $registryValues.DistributionName
            VirtualDiskPath = [System.IO.Path]::Combine($basePath, $virtualDiskFileName)
        }
    }
}

function Get-VirtualDiskTarget {
    param([object[]] $Distributions)

    $candidates = @(
        foreach ($distribution in $Distributions) {
            [pscustomobject]@{ Name = $distribution.Name; Path = $distribution.VirtualDiskPath }
            if ($distribution.Name -eq 'docker-desktop') {
                # The data disk lies next to the docker-desktop distribution (<location>\main and
                # <location>\disk), also when Docker's "Disk image location" setting was changed.
                $dockerLocation = Split-Path -Parent (Split-Path -Parent $distribution.VirtualDiskPath)
                [pscustomobject]@{ Name = $dockerDataDiskName; Path = Join-Path $dockerLocation 'disk\docker_data.vhdx' }
            }
        }
        # Docker Desktop 4.30+ keeps images and volumes on a disk that is not a registered distribution.
        [pscustomobject]@{ Name = $dockerDataDiskName; Path = Join-Path $env:LOCALAPPDATA 'Docker\wsl\disk\docker_data.vhdx' }
        # Location used by older Docker Desktop versions.
        [pscustomobject]@{ Name = $dockerDataDiskName; Path = Join-Path $env:LOCALAPPDATA 'Docker\wsl\data\ext4.vhdx' }
    )

    $knownPaths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($candidate in $candidates) {
        if (-not (Test-Path -LiteralPath $candidate.Path -PathType Leaf)) { continue }
        if ($knownPaths.Add([System.IO.Path]::GetFullPath($candidate.Path))) { $candidate }
    }
}

function New-WslArgumentList {
    param(
        [Parameter(Mandatory)] [string] $DistributionName,
        [Parameter(Mandatory)] [string] $ShellCommand,
        [switch] $AsRoot
    )

    $argumentList = @('--distribution', $DistributionName)
    if ($AsRoot) { $argumentList += @('--user', 'root') }
    $argumentList + @('--exec', 'sh', '-c', $ShellCommand)
}

function Test-DistributionCommand {
    param(
        [Parameter(Mandatory)] [string] $DistributionName,
        [Parameter(Mandatory)] [string] $ShellCommand,
        [switch] $AsRoot
    )

    $wslArguments = New-WslArgumentList -DistributionName $DistributionName -ShellCommand $ShellCommand -AsRoot:$AsRoot
    & wsl.exe @wslArguments *> $null
    $LASTEXITCODE -eq 0
}

function Invoke-DistributionCommand {
    param(
        [Parameter(Mandatory)] [string] $DistributionName,
        [Parameter(Mandatory)] [string] $ShellCommand,
        [switch] $AsRoot
    )

    # stderr is merged inside the distribution, so error messages keep their position in the output.
    $wslArguments = New-WslArgumentList -DistributionName $DistributionName -ShellCommand "exec 2>&1; $ShellCommand" -AsRoot:$AsRoot
    # Linux tools write UTF-8.
    $exitCode = Invoke-NativeCommand -FilePath 'wsl.exe' -ArgumentList $wslArguments -StandardOutputEncoding ([System.Text.UTF8Encoding]::new($false))

    if ($exitCode -ne 0) {
        Write-Warning "Command exited with code $exitCode in '$DistributionName'."
        $script:hasFailures = $true
    }
}

function Stop-DockerDesktop {
    $dockerDesktopProcessNames = @('Docker Desktop', 'com.docker.backend', 'com.docker.build')
    # Only this Windows session: an elevated run must not stop Docker Desktop of other signed-in users.
    $currentSessionId = (Get-Process -Id $PID).SessionId

    if (-not (Get-Process -Name $dockerDesktopProcessNames -ErrorAction SilentlyContinue | Where-Object SessionId -eq $currentSessionId)) {
        Write-Host '  Docker Desktop is not running.'
        return
    }

    if (Get-Command -Name 'docker.exe' -ErrorAction SilentlyContinue) {
        # Graceful shutdown, available since Docker Desktop 4.37.
        & docker.exe desktop stop *> $null
    }
    Get-Process -Name $dockerDesktopProcessNames -ErrorAction SilentlyContinue |
        Where-Object SessionId -eq $currentSessionId |
        Stop-Process -Force -ErrorAction SilentlyContinue
    Write-Host '  Docker Desktop stopped. Start it again manually when needed.'
}

function Wait-FileUnlocked {
    param(
        [Parameter(Mandatory)] [string] $FilePath,
        [int] $TimeoutSeconds = 30
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        try {
            $fileStream = [System.IO.File]::Open(
                $FilePath,
                [System.IO.FileMode]::Open,
                [System.IO.FileAccess]::Read,
                [System.IO.FileShare]::None)
            $fileStream.Dispose()
            return $true
        }
        catch {
            Start-Sleep -Seconds 1
        }
    } while ((Get-Date) -lt $deadline)

    return $false
}

function Get-DiskpartCompatiblePath {
    # The diskpart script file is written as ASCII to avoid code page issues,
    # so paths with non-ASCII characters (e.g. umlauts in the user name) are
    # replaced by their 8.3 short form when one exists.
    param([Parameter(Mandatory)] [string] $FilePath)

    if ($FilePath -notmatch '[^\x00-\x7F]') { return $FilePath }

    try {
        $fileSystemObject = New-Object -ComObject 'Scripting.FileSystemObject'
        $shortPath = $fileSystemObject.GetFile($FilePath).ShortPath
    }
    catch {
        return $null
    }

    if ($shortPath -match '[^\x00-\x7F]') { return $null }
    return $shortPath
}

function Invoke-DiskpartScript {
    param(
        [Parameter(Mandatory)] [string[]] $ScriptLines,
        [switch] $Quiet
    )

    # Not the user's %TEMP%: an elevated diskpart must not run a script file
    # that non-elevated processes are able to modify.
    $scriptFilePath = Join-Path $env:SystemRoot "Temp\wsl-compaction-$([guid]::NewGuid()).txt"
    Set-Content -LiteralPath $scriptFilePath -Value $ScriptLines -Encoding Ascii
    try {
        if ($Quiet) {
            & diskpart.exe /s $scriptFilePath *> $null
            return $LASTEXITCODE
        }
        return Invoke-NativeCommand -FilePath 'diskpart.exe' -ArgumentList @('/s', $scriptFilePath)
    }
    finally {
        Remove-Item -LiteralPath $scriptFilePath -ErrorAction SilentlyContinue
    }
}

function New-DiskpartSelectCommand {
    # Returns the diskpart line that selects the virtual disk, or $null if diskpart cannot address the path.
    param([Parameter(Mandatory)] [string] $VirtualDiskPath)

    $diskpartCompatiblePath = Get-DiskpartCompatiblePath -FilePath $VirtualDiskPath
    if (-not $diskpartCompatiblePath) { return $null }
    "select vdisk file=`"$diskpartCompatiblePath`""
}

function Dismount-VirtualDisk {
    # Detaches the disk if it is still attached on the host. diskpart attachments outlive the
    # diskpart process, so an interrupted compaction would otherwise keep the distribution blocked.
    param([Parameter(Mandatory)] [string] $VirtualDiskPath)

    $selectCommand = New-DiskpartSelectCommand -VirtualDiskPath $VirtualDiskPath
    if ($selectCommand) {
        $null = Invoke-DiskpartScript -ScriptLines @($selectCommand, 'detach vdisk noerr') -Quiet
    }
}

function Invoke-DiskpartCompaction {
    param([Parameter(Mandatory)] [string] $VirtualDiskPath)

    $selectCommand = New-DiskpartSelectCommand -VirtualDiskPath $VirtualDiskPath
    if (-not $selectCommand) {
        Write-Warning 'Path contains non-ASCII characters and has no 8.3 short name; diskpart cannot handle it.'
        return $false
    }

    $exitCode = Invoke-DiskpartScript -ScriptLines @(
        $selectCommand
        'attach vdisk readonly'
        'compact vdisk'
        'detach vdisk'
    )

    if ($exitCode -ne 0) {
        # diskpart stops at the first error, so make sure the disk is not left attached.
        Dismount-VirtualDisk -VirtualDiskPath $VirtualDiskPath
        return $false
    }
    return $true
}

function Optimize-VirtualDisk {
    # Compacts one virtual disk and returns its result for the summary. Needs administrator rights.
    param([Parameter(Mandatory)] [pscustomobject] $VirtualDisk)

    Write-Section "Compacting '$($VirtualDisk.Name)'"
    Write-Host "  $($VirtualDisk.Path)"

    $unsupportedFileAttributes = [System.IO.FileAttributes]::SparseFile -bor
        [System.IO.FileAttributes]::Compressed -bor
        [System.IO.FileAttributes]::Encrypted
    $virtualDiskFile = Get-Item -LiteralPath $VirtualDisk.Path
    $sizeBeforeBytes = $virtualDiskFile.Length
    $isFailure = $false

    if (($virtualDiskFile.Attributes -band $unsupportedFileAttributes) -ne 0) {
        Write-Warning "diskpart cannot compact sparse, compressed or encrypted files ($($virtualDiskFile.Attributes))."
        $status = 'Skipped (unsupported)'
    }
    else {
        # Recovers from an earlier run that was interrupted while the disk was attached.
        Dismount-VirtualDisk -VirtualDiskPath $VirtualDisk.Path

        if (-not (Wait-FileUnlocked -FilePath $VirtualDisk.Path)) {
            Write-Warning 'The virtual disk is still in use.'
            $status = 'Skipped (in use)'
            $isFailure = $true
        }
        elseif (Invoke-DiskpartCompaction -VirtualDiskPath $VirtualDisk.Path) {
            $status = 'Compacted'
        }
        else {
            $status = 'Failed'
            $isFailure = $true
        }
    }

    $sizeAfterBytes = (Get-Item -LiteralPath $VirtualDisk.Path).Length
    [pscustomobject]@{
        Distribution    = $VirtualDisk.Name
        Status          = $status
        IsFailure       = $isFailure
        SizeBeforeBytes = $sizeBeforeBytes
        SizeAfterBytes  = $sizeAfterBytes
        FreedBytes      = $sizeBeforeBytes - $sizeAfterBytes
    }
}

function Write-CompactionSummary {
    param([Parameter(Mandatory)] [object[]] $CompactionResults)

    Write-Section 'Summary'
    $CompactionResults | Format-Table -AutoSize -Property Distribution, Status,
        @{ Name = 'Before'; Expression = { Format-ByteSize $_.SizeBeforeBytes }; Alignment = 'Right' },
        @{ Name = 'After';  Expression = { Format-ByteSize $_.SizeAfterBytes };  Alignment = 'Right' },
        @{ Name = 'Freed';  Expression = { Format-ByteSize $_.FreedBytes };      Alignment = 'Right' } |
        Out-Host

    $totalFreedBytes = ($CompactionResults | Measure-Object -Property FreedBytes -Sum).Sum
    Write-Host "Total reclaimed: $(Format-ByteSize $totalFreedBytes)" -ForegroundColor Green
}

function Test-InlineSudoEnabled {
    # Windows sudo (Windows 11 24H2 and later) in inline mode runs the elevated command in the
    # current window. Registry value 'Enabled': 0 disabled, 1 new window, 2 input disabled, 3 inline.
    if (-not (Test-Path -LiteralPath (Join-Path $env:SystemRoot 'System32\sudo.exe'))) { return $false }
    $sudoSettings = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Sudo' -ErrorAction SilentlyContinue
    return ($null -ne $sudoSettings -and $sudoSettings.Enabled -eq 3)
}

function ConvertTo-StringLiteral {
    # Single-quoted PowerShell string literal. CodeGeneration also escapes typographic quotes,
    # which PowerShell treats as quotes as well (e.g. a curly apostrophe in a user name).
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Value)

    "'" + [System.Management.Automation.Language.CodeGeneration]::EscapeSingleQuotedStringContent($Value) + "'"
}

function Invoke-ElevatedCompaction {
    # Runs the compaction in an elevated PowerShell (UAC prompt) and returns its results. The disks
    # are passed in explicitly, so this also works when the administrator is a different account.
    param([Parameter(Mandatory)] [object[]] $VirtualDisks)

    $useInlineSudo = Test-InlineSudoEnabled
    $separateWindowLiteral = if ($useInlineSudo) { '$false' } else { '$true' }
    $resultFilePath = Join-Path ([System.IO.Path]::GetTempPath()) "wsl-compaction-$([guid]::NewGuid()).json"
    $manifestPath = Join-Path $PSScriptRoot 'WslDiskSpace.psd1'
    $virtualDisksJson = ConvertTo-Json -InputObject @($VirtualDisks | Select-Object -Property Name, Path) -Compress

    # Everything is passed on the command line, which cannot be changed after the UAC prompt.
    $workerCommand = @(
        "`$ErrorActionPreference = 'Continue'"
        'try {'
        "    Import-Module -Name $(ConvertTo-StringLiteral $manifestPath) -ErrorAction Stop"
        "    & (Get-Module -Name 'WslDiskSpace') {"
        '        param($virtualDisksJson, $resultFilePath, $separateWindow)'
        '        Invoke-CompactionWorker -VirtualDisksJson $virtualDisksJson -ResultFilePath $resultFilePath -SeparateWindow:$separateWindow'
        "    } $(ConvertTo-StringLiteral $virtualDisksJson) $(ConvertTo-StringLiteral $resultFilePath) $separateWindowLiteral"
        '}'
        'catch {'
        '    Write-Host $_ -ForegroundColor Red'
        "    if ($separateWindowLiteral) { `$null = Read-Host 'Press Enter to close this window' }"
        '}'
    ) -join "`n"
    $encodedCommand = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($workerCommand))
    $powerShellExecutable = Join-Path $PSHOME $(if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh.exe' } else { 'powershell.exe' })
    # -OutputFormat Text: with redirected output, an encoded command would otherwise write CLIXML.
    $powerShellArguments = @('-NoProfile', '-NoLogo', '-ExecutionPolicy', 'Bypass', '-OutputFormat', 'Text', '-EncodedCommand', $encodedCommand)

    Write-Section 'Compacting with administrator rights'
    if ($useInlineSudo) {
        Write-Host '  Asking for administrator rights (UAC); the compaction then runs in this window.'
    }
    else {
        Write-Host '  Asking for administrator rights (UAC); the compaction then runs in a separate window.'
    }

    try {
        if ($useInlineSudo) {
            # Start-Process leaves the console unredirected, so the live output keeps working.
            $sudoArguments = @($powerShellExecutable) + $powerShellArguments | ForEach-Object { ConvertTo-CommandLineArgument -Argument $_ }
            Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\sudo.exe') -ArgumentList ($sudoArguments -join ' ') -NoNewWindow -Wait -ErrorAction Stop
        }
        else {
            $quotedArguments = $powerShellArguments | ForEach-Object { ConvertTo-CommandLineArgument -Argument $_ }
            $workerProcess = Start-Process -FilePath $powerShellExecutable -ArgumentList ($quotedArguments -join ' ') -Verb RunAs -PassThru -ErrorAction Stop
            if ($workerProcess) { $workerProcess.WaitForExit() }
        }
    }
    catch {
        Write-Warning "The elevated compaction could not be started: $($_.Exception.Message)"
    }

    if (-not (Test-Path -LiteralPath $resultFilePath)) {
        Write-Warning ('The elevated compaction reported no results. If a distribution does not start ' +
            'anymore, run Optimize-WslDiskSpace again to detach its disk.')
        $script:hasFailures = $true
        return
    }

    try {
        $resultDocument = Get-Content -LiteralPath $resultFilePath -Raw -Encoding UTF8 | ConvertFrom-Json
        @($resultDocument.Results)
    }
    finally {
        Remove-Item -LiteralPath $resultFilePath -ErrorAction SilentlyContinue
    }
}

function Invoke-CompactionWorker {
    # Entry point of the elevated PowerShell started by Invoke-ElevatedCompaction.
    param(
        [Parameter(Mandatory)] [string] $VirtualDisksJson,
        [Parameter(Mandatory)] [string] $ResultFilePath,
        [switch] $SeparateWindow
    )

    if ($SeparateWindow) {
        try { $Host.UI.RawUI.WindowTitle = 'Optimize-WslDiskSpace (Administrator)' }
        catch { <# Not every host has a window title. #> }
    }

    # Piping unrolls the array, which Windows PowerShell's ConvertFrom-Json returns as one object.
    $virtualDisks = @((ConvertFrom-Json -InputObject $VirtualDisksJson) | ForEach-Object { $_ })
    $compactionResults = @(foreach ($virtualDisk in $virtualDisks) { Optimize-VirtualDisk -VirtualDisk $virtualDisk })
    ConvertTo-Json -InputObject @{ Results = $compactionResults } -Depth 3 |
        Set-Content -LiteralPath $ResultFilePath -Encoding UTF8

    if ($SeparateWindow -and @($compactionResults | Where-Object IsFailure).Count -gt 0) {
        $null = Read-Host 'At least one disk failed, see above. Press Enter to close this window'
    }
}

function Invoke-CompactionPhase {
    param([Parameter(Mandatory)] [object[]] $VirtualDisks)

    Write-Section 'Stopping Docker Desktop and WSL'
    Stop-DockerDesktop
    & wsl.exe --shutdown | Out-Host
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "wsl --shutdown failed with exit code $LASTEXITCODE, skipping compaction."
        $script:hasFailures = $true
        return
    }
    Write-Host '  WSL has been shut down.'

    $compactionResults = @(
        if (Test-IsAdministrator) {
            foreach ($virtualDisk in $VirtualDisks) { Optimize-VirtualDisk -VirtualDisk $virtualDisk }
        }
        else {
            Invoke-ElevatedCompaction -VirtualDisks $VirtualDisks
        }
    )
    if ($compactionResults.Count -eq 0) { return }

    if (@($compactionResults | Where-Object IsFailure).Count -gt 0) {
        $script:hasFailures = $true
    }
    Write-CompactionSummary -CompactionResults $compactionResults
}

#endregion

#region Public command

function Get-DistributionNameCompletion {
    # Completion results for -DistributionName: installed distributions and Docker's data disk.
    param([string] $PartialName)

    $distributions = @(Get-WslDistribution)
    $availableNames = @($distributions | ForEach-Object Name) + @(Get-VirtualDiskTarget -Distributions $distributions | ForEach-Object Name)
    $availableNames | Sort-Object -Unique | Where-Object { $_ -like "$PartialName*" } | ForEach-Object {
        [System.Management.Automation.CompletionResult]::new($_, $_, 'ParameterValue', $_)
    }
}

function Optimize-WslDiskSpace {
    <#
    .SYNOPSIS
        Frees disk space inside all WSL 2 distributions and compacts their virtual disks.

    .DESCRIPTION
        The command runs in four phases:
          1. Cleanup inside each distribution: apt-get clean / autoremove and
             docker system prune --all --volumes (always against the local daemon).
          2. fstrim on the root file system, so freed blocks are handed back to
             the virtual disk and can actually be reclaimed by the compaction.
          3. Stop Docker Desktop and shut down WSL, releasing all .vhdx files.
          4. Compact every ext4.vhdx (including Docker Desktop's data disk) with
             diskpart and report how much space was reclaimed.

        Only phase 4 needs administrator rights; without them, it asks for them (UAC).

    .PARAMETER DistributionName
        Limit cleanup and compaction to these distributions; tab completion lists
        the installed ones. Docker Desktop's data disk is addressed as 'docker-desktop-data'.

    .PARAMETER SkipPackageCleanup
        Do not run apt-get clean / autoremove.

    .PARAMETER SkipDockerPrune
        Do not run docker system prune.

    .PARAMETER SkipCompaction
        Only clean up inside the distributions; do not shut down WSL or compact disks.

    .PARAMETER Force
        Skip the confirmation prompt before pruning Docker data.

    .EXAMPLE
        Optimize-WslDiskSpace

    .EXAMPLE
        Optimize-WslDiskSpace -DistributionName Ubuntu, docker-desktop-data -Force

    .EXAMPLE
        Optimize-WslDiskSpace -SkipCompaction

    .NOTES
        - Start it from a normal terminal. The cleanup runs as you; only the compaction
          asks for administrator rights (UAC). With Windows sudo in inline mode it runs
          in the same window, otherwise in a separate window that closes when done and
          stays open if a disk failed.
        - In a scheduled task, enable "Run with highest privileges", because no UAC
          prompt can be shown there.
        - WSL is always shut down completely, even if only some disks are compacted.
        - Docker Desktop is stopped but not restarted.
        - Ends with an error if any step failed, so a scheduled
          'pwsh -Command Optimize-WslDiskSpace -Force' exits with code 1.
        - Progress output (e.g. diskpart's percentage) is redrawn in place next to
          a spinner. When the output is redirected, only completed lines are written.
    #>
    [CmdletBinding()]
    param(
        # Attribute script blocks are not bound to the module, so the lookup is run inside it explicitly.
        [ArgumentCompleter({
            param($commandName, $parameterName, $wordToComplete)
            $module = Get-Module -Name 'WslDiskSpace' | Select-Object -First 1
            & $module { param($partialName) Get-DistributionNameCompletion -PartialName $partialName } $wordToComplete
        })]
        [string[]] $DistributionName,
        [switch] $SkipPackageCleanup,
        [switch] $SkipDockerPrune,
        [switch] $SkipCompaction,
        [switch] $Force
    )

    # Native command failures are handled via exit codes. An inherited 'Stop' preference
    # would otherwise abort on harmless stderr output in Windows PowerShell 5.1.
    $ErrorActionPreference = 'Continue'
    $script:hasFailures = $false
    # Makes wsl.exe write its own messages as UTF-8 instead of UTF-16 (restored afterwards).
    $previousWslUtf8Value = $env:WSL_UTF8
    $env:WSL_UTF8 = '1'

    try {
        if (-not (Get-Command -Name 'wsl.exe' -ErrorAction SilentlyContinue)) {
            throw 'wsl.exe was not found. Is WSL installed?'
        }

        if ($DistributionName) {
            # Also accepts 'Ubuntu,Debian' as a single string, e.g. from a scheduled task.
            $DistributionName = @($DistributionName -split ',' | ForEach-Object Trim | Where-Object { $_ })
        }

        $allDistributions = @(Get-WslDistribution)
        $distributions = $allDistributions
        if ($DistributionName) {
            $knownNames = @($allDistributions | ForEach-Object Name) + $dockerDataDiskName
            foreach ($requestedName in $DistributionName) {
                if ($knownNames -notcontains $requestedName) {
                    Write-Warning "Unknown distribution '$requestedName' is ignored."
                }
            }
            $distributions = @($allDistributions | Where-Object { $DistributionName -contains $_.Name })
        }
        # Docker Desktop's internal distributions are managed by Docker itself.
        $cleanupDistributions = @($distributions | Where-Object { $_.Name -notlike 'docker-desktop*' })

        Write-Section 'WSL distributions'
        if ($distributions.Count -eq 0) {
            Write-Host '  (none)'
        }
        foreach ($distribution in $distributions) {
            Write-Host "  $($distribution.Name)"
        }

        $dockerDistributionNames = @()
        if (-not $SkipDockerPrune) {
            $dockerDistributionNames = @($cleanupDistributions |
                Where-Object { Test-DistributionCommand -DistributionName $_.Name -ShellCommand $dockerAvailabilityCheck -AsRoot } |
                ForEach-Object Name)
        }

        if ($dockerDistributionNames.Count -gt 0 -and -not $Force) {
            Write-Host ''
            Write-Warning ("docker system prune --all --volumes will run in: $($dockerDistributionNames -join ', '). " +
                'It removes ALL stopped containers, unused images, networks, build cache and anonymous volumes.')
            $confirmation = Read-Host 'Continue? [y/N]'
            if ($confirmation -notmatch '^(y|yes|j|ja)$') {
                Write-Host 'Aborted. Use -SkipDockerPrune to clean up without pruning Docker.'
                return
            }
        }

        # Phase 1 + 2: cleanup inside the distributions
        foreach ($distribution in $cleanupDistributions) {
            Write-Section "Cleaning up '$($distribution.Name)'"

            if (-not (Test-DistributionCommand -DistributionName $distribution.Name -ShellCommand 'true')) {
                Write-Warning 'The distribution could not be started, skipping.'
                $script:hasFailures = $true
                continue
            }

            if (-not $SkipPackageCleanup) {
                if (Test-DistributionCommand -DistributionName $distribution.Name -ShellCommand 'command -v apt-get' -AsRoot) {
                    Write-Host '  apt-get clean && apt-get autoremove'
                    Invoke-DistributionCommand -DistributionName $distribution.Name -ShellCommand $packageCleanupCommand -AsRoot
                }
                else {
                    Write-Host '  apt-get not available, skipping package cleanup.'
                }
            }

            if ($dockerDistributionNames -contains $distribution.Name) {
                Write-Host '  docker system prune --all --volumes'
                Invoke-DistributionCommand -DistributionName $distribution.Name -ShellCommand $dockerPruneCommand -AsRoot
            }
            elseif (-not $SkipDockerPrune) {
                Write-Host '  Docker not installed or daemon not reachable, skipping prune.'
            }

            if (-not $SkipCompaction) {
                Write-Host '  fstrim /'
                Invoke-DistributionCommand -DistributionName $distribution.Name -ShellCommand $trimCommand -AsRoot
            }
        }

        # Phase 3 + 4: release and compact the virtual disks
        if ($SkipCompaction) {
            Write-Section 'Done (compaction skipped)'
        }
        else {
            # All distributions, so a moved Docker data disk is found next to docker-desktop.
            $virtualDisks = @(Get-VirtualDiskTarget -Distributions $allDistributions)
            if ($DistributionName) {
                $virtualDisks = @($virtualDisks | Where-Object { $DistributionName -contains $_.Name })
            }

            if ($virtualDisks.Count -eq 0) {
                Write-Warning 'No virtual disks found to compact. WSL and Docker Desktop are left running.'
            }
            else {
                Invoke-CompactionPhase -VirtualDisks $virtualDisks
            }
        }
    }
    finally {
        $env:WSL_UTF8 = $previousWslUtf8Value
    }

    if ($script:hasFailures) {
        # A terminating error, because Write-Error does not reliably mark the call as failed:
        # this way a scheduled 'pwsh -Command Optimize-WslDiskSpace' exits with code 1.
        $PSCmdlet.ThrowTerminatingError([System.Management.Automation.ErrorRecord]::new(
            [System.Exception]::new('One or more steps failed, see the warnings above.'),
            'OptimizeWslDiskSpaceFailed',
            [System.Management.Automation.ErrorCategory]::NotSpecified,
            $null))
    }
}

#endregion

Export-ModuleMember -Function 'Optimize-WslDiskSpace'
