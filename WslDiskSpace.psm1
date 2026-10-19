# WslDiskSpace: frees disk space inside WSL 2 distributions and compacts their virtual disks.
# The only public command is Optimize-WslDiskSpace; all other functions are internal.

$dockerDataDiskName = 'docker-desktop-data'

# Full paths: Process.Start would also search the current directory for a bare name.
$systemDirectory = Join-Path $env:SystemRoot 'System32'
$wslPath = Join-Path $systemDirectory 'wsl.exe'
$diskpartPath = Join-Path $systemDirectory 'diskpart.exe'
$sudoPath = Join-Path $systemDirectory 'sudo.exe'
$windowsPowerShellPath = Join-Path $systemDirectory 'WindowsPowerShell\v1.0\powershell.exe'
# Not the user's %TEMP%, so non-elevated processes cannot change a diskpart script before it runs.
$diskpartScriptDirectory = Join-Path $env:SystemRoot 'Temp'

# Docker is pinned to the local daemon, so a remote context or DOCKER_HOST can never be pruned by accident.
$dockerEnvironmentReset = 'unset DOCKER_HOST DOCKER_CONTEXT'
# .Client.APIVersion is the negotiated version, so it is lower with an older client or daemon.
$dockerEngineQuery = "$dockerEnvironmentReset; command -v docker >/dev/null && " +
    "docker --context default version --format '{{.Client.APIVersion}}' && " +
    "docker --context default info --format '{{.ID}}|{{.OperatingSystem}}'"

# autoremove waits for the dpkg lock, e.g. held by unattended-upgrades right after the start.
# apt-get clean cannot wait for its locks, so it runs last and on its own.
$packageCleanupCommand = 'export DEBIAN_FRONTEND=noninteractive; apt-get -o DPkg::Lock::Timeout=120 autoremove --yes; ' +
    'status=$?; apt-get clean || status=$?; exit $status'
$trimCommand = 'fstrim -v / 2>/dev/null || echo fstrim not supported, skipping.'

#region Live output

function ConvertTo-CommandLineArgument {
    # Quotes an argument following the Windows command line rules (CommandLineToArgvW).
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Argument)

    if ($Argument -and $Argument -notmatch '[\s"]') { return $Argument }

    # Backslashes are only special in front of a double quote or the closing quote.
    # \z instead of $, which also matches in front of a final line feed.
    $escapedArgument = $Argument -replace '(\\*)"', '$1$1\"' -replace '(\\+)\z', '$1$1'
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

    # Not Write-Host: spinner frames must not end up in transcripts or redirected output.
    $Host.UI.Write("`r" + $statusLine.PadRight($Renderer.RenderedLength))
    $Renderer.RenderedLength = $statusLine.Length
}

function Clear-RendererStatus {
    param([Parameter(Mandatory)] [pscustomobject] $Renderer)

    if ($Renderer.RenderedLength -eq 0) { return }
    $Host.UI.Write("`r" + (' ' * $Renderer.RenderedLength) + "`r")
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

function New-NativeStartInfo {
    # A hidden console of its own: wsl.exe switches a shared console to raw input, which hands Ctrl+C
    # to Linux, and it would read input meant for Read-Host.
    param(
        [Parameter(Mandatory)] [string] $FilePath,
        [Parameter(Mandatory)] [string[]] $ArgumentList,
        [Parameter(Mandatory)] [System.Text.Encoding] $OutputEncoding
    )

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new($FilePath)
    $startInfo.Arguments = @($ArgumentList | ForEach-Object { ConvertTo-CommandLineArgument -Argument $_ }) -join ' '
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.StandardOutputEncoding = $OutputEncoding
    $startInfo.StandardErrorEncoding = $OutputEncoding
    $startInfo
}

function Invoke-NativeCommand {
    # PowerShell's own line splitting is avoided on purpose: it treats a lone CR as a line break,
    # which turns every progress update into a new line.
    # Ctrl+C does not reach the command. Without -StopOnInterrupt it is awaited: stopping wsl.exe could interrupt dpkg.
    param(
        [Parameter(Mandatory)] [string] $FilePath,
        [Parameter(Mandatory)] [string[]] $ArgumentList,
        [System.Text.Encoding] $StandardOutputEncoding = [Console]::OutputEncoding,
        [switch] $StopOnInterrupt
    )

    $startInfo = New-NativeStartInfo -FilePath $FilePath -ArgumentList $ArgumentList -OutputEncoding $StandardOutputEncoding
    $renderer = New-OutputRenderer
    $buffer = [char[]]::new(4096)
    $process = [System.Diagnostics.Process]::Start($startInfo)
    $process.StandardInput.Close()
    # Read in parallel, so a command that fills the error pipe cannot block.
    $errorTask = $process.StandardError.ReadToEndAsync()
    if ($renderer.IsInteractive) { Set-CursorVisibility -Visible $false }
    $isCompleted = $false
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

        $errorText = $errorTask.Result
        if ($errorText) {
            Add-RendererText -Renderer $renderer -Text $errorText
            if ($renderer.CurrentSegment.Length -gt 0) { Complete-RendererLine -Renderer $renderer }
        }

        $process.WaitForExit()
        $isCompleted = $true
        return $process.ExitCode
    }
    finally {
        Clear-RendererStatus -Renderer $renderer
        if (-not $isCompleted -and -not $process.HasExited) {
            if ($StopOnInterrupt) {
                try { $process.Kill() }
                catch { <# It exited in the meantime. #> }
            }
            else {
                Write-Host '    Waiting for the running command to finish...'
                # Unread output would block the command as soon as the pipe is full.
                try {
                    if ($readTask) { $null = $readTask.Wait() }
                    $null = $process.StandardOutput.ReadToEnd()
                }
                catch { <# The rest of the output is not shown anyway. #> }
                $process.WaitForExit()
            }
        }
        if ($renderer.IsInteractive) { Set-CursorVisibility -Visible $true }
        $process.Dispose()
    }
}

function Get-NativeCommandResult {
    param(
        [Parameter(Mandatory)] [string] $FilePath,
        [Parameter(Mandatory)] [string[]] $ArgumentList,
        [System.Text.Encoding] $OutputEncoding = [System.Text.UTF8Encoding]::new($false),
        [int] $TimeoutSeconds = 0
    )

    $startInfo = New-NativeStartInfo -FilePath $FilePath -ArgumentList $ArgumentList -OutputEncoding $OutputEncoding
    $process = [System.Diagnostics.Process]::Start($startInfo)
    try {
        $process.StandardInput.Close()
        $outputTask = $process.StandardOutput.ReadToEndAsync()
        $errorTask = $process.StandardError.ReadToEndAsync()
        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        # Short waits, so Ctrl+C can stop this script in between.
        while (-not $process.WaitForExit(100)) {
            if ($TimeoutSeconds -gt 0 -and $stopwatch.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
                try { $process.Kill() }
                catch { <# It exited in the meantime. #> }
                $process.WaitForExit()
                return [pscustomobject]@{ ExitCode = $null; Output = ''; ErrorOutput = ''; TimedOut = $true }
            }
        }
        $process.WaitForExit()
        [pscustomobject]@{ ExitCode = $process.ExitCode; Output = $outputTask.Result; ErrorOutput = $errorTask.Result; TimedOut = $false }
    }
    finally {
        if (-not $process.HasExited) {
            try { $process.Kill() }
            catch { <# It exited in the meantime. #> }
        }
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

function Format-NameList {
    param([string[]] $Name)

    $names = @($Name | Where-Object { $_ })
    if ($names.Count -eq 0) { return '(none)' }
    $names -join ', '
}

function New-ErrorRecord {
    param(
        [Parameter(Mandatory)] [string] $Message,
        [Parameter(Mandatory)] [string] $ErrorId
    )

    [System.Management.Automation.ErrorRecord]::new(
        [System.Exception]::new($Message),
        $ErrorId,
        [System.Management.Automation.ErrorCategory]::NotSpecified,
        $null)
}

function Test-IsWow64Process {
    [Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess
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
    (Get-NativeCommandResult -FilePath $wslPath -ArgumentList $wslArguments).ExitCode -eq 0
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
    $exitCode = Invoke-NativeCommand -FilePath $wslPath -ArgumentList $wslArguments -StandardOutputEncoding ([System.Text.UTF8Encoding]::new($false))

    if ($exitCode -ne 0) {
        Write-Warning "Command exited with code $exitCode in '$DistributionName'."
        $script:hasFailures = $true
    }
}

function Get-DockerEngine {
    param([Parameter(Mandatory)] [string] $DistributionName)

    $wslArguments = New-WslArgumentList -DistributionName $DistributionName -ShellCommand $dockerEngineQuery -AsRoot
    $result = Get-NativeCommandResult -FilePath $wslPath -ArgumentList $wslArguments
    if ($result.ExitCode -ne 0) { return }

    # wsl.exe may print notices of its own before the output.
    $outputLines = @($result.Output -split "`r?`n")
    $apiVersion = $outputLines | Where-Object { $_ -match '^\d+\.\d+$' } | Select-Object -Last 1
    $engineLine = $outputLines | Where-Object { $_ -like '*|*' } | Select-Object -Last 1
    if (-not $apiVersion -or -not $engineLine) { return }

    $engineId, $operatingSystem = $engineLine -split '\|', 2
    [pscustomobject]@{
        DistributionName = $DistributionName
        Id               = $engineId
        OperatingSystem  = $operatingSystem
        ApiVersion       = $apiVersion
    }
}

function Get-DockerEngineLabel {
    param([Parameter(Mandatory)] [pscustomobject] $Engine)

    if ($Engine.OperatingSystem -eq 'Docker Desktop') {
        return "Docker Desktop (via $($Engine.DistributionName))"
    }
    $Engine.DistributionName
}

function Get-DockerPruneArgument {
    # Before Docker Engine 23.0 (API 1.42), --volumes also deletes unused named volumes.
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $ApiVersion)

    $parsedVersion = $null
    if ([version]::TryParse($ApiVersion, [ref]$parsedVersion) -and $parsedVersion -ge [version]'1.42') {
        return '--all --volumes --force'
    }
    '--all --force'
}

function Read-Confirmation {
    # $null when no answer can be read: Read-Host throws under -NonInteractive and returns
    # nothing at the end of redirected input.
    param([Parameter(Mandatory)] [string] $Prompt)

    try { $answer = Read-Host -Prompt $Prompt }
    catch { return $null }
    if ($null -eq $answer) { return $null }
    $answer -match '^(y|yes|j|ja)$'
}

function Stop-DockerDesktop {
    $dockerDesktopProcessNames = @('Docker Desktop', 'com.docker.backend', 'com.docker.build')
    # Only this Windows session: an elevated run must not stop Docker Desktop of other signed-in users.
    $currentSessionId = (Get-Process -Id $PID).SessionId

    if (-not (Get-Process -Name $dockerDesktopProcessNames -ErrorAction SilentlyContinue | Where-Object SessionId -eq $currentSessionId)) {
        Write-Host '  Docker Desktop is not running.'
        return
    }

    $dockerCommand = Get-Command -Name 'docker.exe' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($dockerCommand) {
        Write-Host '  Stopping Docker Desktop, this can take a minute...'
        # Graceful shutdown, available since Docker Desktop 4.37. It has no time limit of its own.
        $stopResult = Get-NativeCommandResult -FilePath $dockerCommand.Source -ArgumentList @('desktop', 'stop') -TimeoutSeconds 120
        if ($stopResult.TimedOut) {
            Write-Warning 'docker desktop stop did not finish within 2 minutes, so Docker Desktop is stopped forcibly.'
        }
    }
    Get-Process -Name $dockerDesktopProcessNames -ErrorAction SilentlyContinue |
        Where-Object SessionId -eq $currentSessionId |
        Stop-Process -Force -ErrorAction SilentlyContinue
    Write-Host '  Docker Desktop stopped. Start it again manually when needed.'
}

function Wait-DockerDesktopTrim {
    # Docker Desktop trims its data disk about 10 seconds after a prune; stopped earlier, the space stays allocated.
    if (-not $script:dockerDesktopPruneTimer) { return }

    $remainingMilliseconds = 15000 - $script:dockerDesktopPruneTimer.ElapsedMilliseconds
    if ($remainingMilliseconds -le 0) { return }
    Write-Host '  Waiting for Docker Desktop to trim its data disk...'
    Start-Sleep -Milliseconds $remainingMilliseconds
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

function Get-ShortName {
    param([Parameter(Mandatory)] [string] $Path)

    $shortNameReader = 'WslDiskSpace.ShortNameReader' -as [type]
    if (-not $shortNameReader) {
        Add-Type -ErrorAction Stop -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace WslDiskSpace {
    public static class ShortNameReader {
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct FindData {
            public uint FileAttributes;
            public System.Runtime.InteropServices.ComTypes.FILETIME CreationTime;
            public System.Runtime.InteropServices.ComTypes.FILETIME LastAccessTime;
            public System.Runtime.InteropServices.ComTypes.FILETIME LastWriteTime;
            public uint FileSizeHigh;
            public uint FileSizeLow;
            public uint Reserved0;
            public uint Reserved1;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string FileName;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 14)] public string AlternateFileName;
        }

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr FindFirstFileW(string fileName, out FindData findData);

        [DllImport("kernel32.dll")]
        private static extern bool FindClose(IntPtr findHandle);

        public static string Read(string path) {
            FindData findData;
            IntPtr findHandle = FindFirstFileW(path, out findData);
            if (findHandle == new IntPtr(-1)) {
                return null;
            }
            FindClose(findHandle);
            return findData.AlternateFileName;
        }
    }
}
'@
        $shortNameReader = 'WslDiskSpace.ShortNameReader' -as [type]
    }

    $shortName = $shortNameReader::Read($Path)
    if ($shortName) { $shortName }
}

function Get-DiskpartCompatiblePath {
    # The diskpart script file is written as ASCII to avoid code page issues, so path components with
    # non-ASCII characters (e.g. umlauts in the user name) are replaced by their 8.3 short names.
    # Not GetShortPathName: it keeps names like 'Michal' with a stroked l, which have a short name too.
    param([Parameter(Mandatory)] [string] $FilePath)

    # Case-sensitive: -notmatch takes U+0130 for ASCII and, under a Turkish culture, 'I' for non-ASCII.
    if ($FilePath -cnotmatch '[^\x00-\x7F]') { return $FilePath }

    $pathRoot = [System.IO.Path]::GetPathRoot($FilePath)
    $longPath = $pathRoot
    $compatiblePath = $pathRoot
    foreach ($component in $FilePath.Substring($pathRoot.Length).Split([char[]]@('\'), [System.StringSplitOptions]::RemoveEmptyEntries)) {
        $longPath = [System.IO.Path]::Combine($longPath, $component)
        if ($component -cmatch '[^\x00-\x7F]') {
            try { $component = Get-ShortName -Path $longPath }
            catch { return $null }
            if (-not $component) { return $null }
        }
        $compatiblePath = [System.IO.Path]::Combine($compatiblePath, $component)
    }

    if ($compatiblePath -cmatch '[^\x00-\x7F]') { return $null }
    $compatiblePath
}

function Get-OemEncoding {
    # diskpart writes redirected output in the OEM code page of the system, whatever the console uses.
    try {
        $oemCodePage = Get-ItemPropertyValue -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Nls\CodePage' -Name 'OEMCP' -ErrorAction Stop
        [System.Text.Encoding]::GetEncoding([int]$oemCodePage)
    }
    catch {
        [Console]::OutputEncoding
    }
}

function Invoke-DiskpartScript {
    param(
        [Parameter(Mandatory)] [string[]] $ScriptLines,
        [switch] $Quiet
    )

    $scriptFilePath = Join-Path $diskpartScriptDirectory "wsl-compaction-$([guid]::NewGuid()).txt"
    Set-Content -LiteralPath $scriptFilePath -Value $ScriptLines -Encoding Ascii
    try {
        if ($Quiet) {
            return (Get-NativeCommandResult -FilePath $diskpartPath -ArgumentList @('/s', $scriptFilePath)).ExitCode
        }
        # Interrupting a compaction is safe; Invoke-DiskpartCompaction then detaches the disk.
        return Invoke-NativeCommand -FilePath $diskpartPath -ArgumentList @('/s', $scriptFilePath) -StandardOutputEncoding (Get-OemEncoding) -StopOnInterrupt
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
        Write-Warning 'Path contains non-ASCII characters and no 8.3 short name was found; diskpart cannot handle it.'
        return $false
    }

    $isCompleted = $false
    try {
        $exitCode = Invoke-DiskpartScript -ScriptLines @(
            $selectCommand
            'attach vdisk readonly'
            'compact vdisk'
            'detach vdisk'
        )
        $isCompleted = $true
    }
    finally {
        if (-not $isCompleted) {
            Dismount-VirtualDisk -VirtualDiskPath $VirtualDiskPath
            Write-Warning 'The compaction was interrupted; the virtual disk has been detached.'
        }
    }

    if ($exitCode -ne 0) {
        # diskpart stops at the first error, so make sure the disk is not left attached.
        Dismount-VirtualDisk -VirtualDiskPath $VirtualDiskPath
        return $false
    }
    return $true
}

function Test-VhdxFixedSize {
    # Parses the VHDX metadata as specified in MS-VHDX. Anything unexpected counts as not fixed.
    param([Parameter(Mandatory)] [string] $Path)

    $metadataRegionId = [guid]'8B7CA206-4790-4B9A-B8FE-575F050F886E'
    $fileParametersId = [guid]'CAA16737-FA36-4D43-B3B6-33F0AA44E76B'
    $regionTableOffset = 192KB

    try {
        $fileStream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    }
    catch {
        return $false
    }
    try {
        $reader = [System.IO.BinaryReader]::new($fileStream)
        if ([System.Text.Encoding]::ASCII.GetString($reader.ReadBytes(8)) -ne 'vhdxfile') { return $false }

        $fileStream.Position = $regionTableOffset
        if ([System.Text.Encoding]::ASCII.GetString($reader.ReadBytes(4)) -ne 'regi') { return $false }
        $fileStream.Position = $regionTableOffset + 8
        $regionCount = [Math]::Min($reader.ReadUInt32(), 2047)
        $metadataRegionOffset = $null
        for ($regionIndex = 0; $regionIndex -lt $regionCount; $regionIndex++) {
            $fileStream.Position = $regionTableOffset + 16 + 32 * $regionIndex
            if ([guid]::new($reader.ReadBytes(16)) -eq $metadataRegionId) {
                $metadataRegionOffset = [long]$reader.ReadUInt64()
                break
            }
        }
        if ($null -eq $metadataRegionOffset) { return $false }

        $fileStream.Position = $metadataRegionOffset
        if ([System.Text.Encoding]::ASCII.GetString($reader.ReadBytes(8)) -ne 'metadata') { return $false }
        $fileStream.Position = $metadataRegionOffset + 10
        $entryCount = $reader.ReadUInt16()
        for ($entryIndex = 0; $entryIndex -lt $entryCount; $entryIndex++) {
            $fileStream.Position = $metadataRegionOffset + 32 + 32 * $entryIndex
            if ([guid]::new($reader.ReadBytes(16)) -eq $fileParametersId) {
                $fileStream.Position = $metadataRegionOffset + [long]$reader.ReadUInt32() + 4
                # Bit 0: LeaveBlocksAllocated.
                return (($reader.ReadUInt32() -band 1) -ne 0)
            }
        }
        return $false
    }
    catch {
        return $false
    }
    finally {
        $fileStream.Dispose()
    }
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
    elseif (Test-VhdxFixedSize -Path $VirtualDisk.Path) {
        Write-Host '  The virtual disk has a fixed size, there is nothing to compact.'
        $status = 'Skipped (fixed size)'
    }
    else {
        # Recovers from an earlier run that was interrupted while the disk was attached.
        Dismount-VirtualDisk -VirtualDiskPath $VirtualDisk.Path

        $isUnlocked = Wait-FileUnlocked -FilePath $VirtualDisk.Path -TimeoutSeconds 10
        if (-not $isUnlocked) {
            # WSL clients such as VS Code start a distribution again right after the shutdown.
            Write-Host '  The virtual disk is in use, shutting WSL down once more.'
            $null = Get-NativeCommandResult -FilePath $wslPath -ArgumentList @('--shutdown')
            $isUnlocked = Wait-FileUnlocked -FilePath $VirtualDisk.Path
        }

        if (-not $isUnlocked) {
            Write-Warning ('The virtual disk is still in use. Close VS Code windows, terminals and Explorer windows ' +
                'connected to WSL, and run Optimize-WslDiskSpace again.')
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

function Test-HasFilteredAdministratorToken {
    $administratorsSid = 'S-1-5-32-544'
    @([System.Security.Principal.WindowsIdentity]::GetCurrent().Claims | Where-Object {
        $_.Type -eq [System.Security.Claims.ClaimTypes]::DenyOnlySid -and $_.Value -eq $administratorsSid
    }).Count -gt 0
}

function Test-InlineSudoEnabled {
    # Windows sudo (Windows 11 24H2 and later) in inline mode runs the elevated command in the current
    # window. 'Enabled': 0 disabled, 1 new window, 2 input disabled, 3 inline; the policy value caps it.
    # sudo refuses standard users, whose administrator is a different account.
    if (-not (Test-HasFilteredAdministratorToken)) { return $false }
    if (-not (Test-Path -LiteralPath $sudoPath)) { return $false }
    $sudoSetting = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Sudo' -ErrorAction SilentlyContinue
    $sudoPolicy = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Sudo' -ErrorAction SilentlyContinue
    $isAllowedByPolicy = $null -eq $sudoPolicy -or $null -eq $sudoPolicy.Enabled -or $sudoPolicy.Enabled -ge 3
    return ($null -ne $sudoSetting -and $sudoSetting.Enabled -eq 3 -and $isAllowedByPolicy)
}

function ConvertTo-StringLiteral {
    # Single-quoted PowerShell string literal. CodeGeneration also escapes typographic quotes,
    # which PowerShell treats as quotes as well (e.g. a curly apostrophe in a user name).
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Value)

    "'" + [System.Management.Automation.Language.CodeGeneration]::EscapeSingleQuotedStringContent($Value) + "'"
}

function Get-ElevatedPowerShellPath {
    # A Microsoft Store pwsh.exe (WindowsApps) cannot be started by a different administrator account.
    param(
        [string] $Edition = $PSVersionTable.PSEdition,
        [string] $PowerShellHome = $PSHOME
    )

    if ($Edition -eq 'Core' -and $PowerShellHome -notlike '*\WindowsApps\*') {
        return Join-Path $PowerShellHome 'pwsh.exe'
    }
    $windowsPowerShellPath
}

function Invoke-ElevatedCompaction {
    # The disks are passed in explicitly, so this also works when the administrator is a different
    # account that can read this module's folder.
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
    $powerShellExecutable = Get-ElevatedPowerShellPath
    # -OutputFormat Text: PowerShell 7 would otherwise write error records as CLIXML to a redirected stderr.
    $powerShellArguments = @('-NoProfile', '-NoLogo', '-ExecutionPolicy', 'Bypass', '-OutputFormat', 'Text', '-EncodedCommand', $encodedCommand)

    Write-Section 'Compacting with administrator rights'
    if ($useInlineSudo) {
        Write-Host '  Asking for administrator rights (UAC); the compaction then runs in this window.'
    }
    else {
        Write-Host '  Asking for administrator rights (UAC); the compaction then runs in a separate window.'
    }

    # The caller's location may be a mapped drive, which does not exist in the elevated session.
    try {
        if ($useInlineSudo) {
            # Start-Process leaves the console unredirected, so the live output keeps working.
            $sudoArguments = @($powerShellExecutable) + $powerShellArguments | ForEach-Object { ConvertTo-CommandLineArgument -Argument $_ }
            Start-Process -FilePath $sudoPath -ArgumentList ($sudoArguments -join ' ') -WorkingDirectory $systemDirectory -NoNewWindow -Wait -ErrorAction Stop
        }
        else {
            $quotedArguments = $powerShellArguments | ForEach-Object { ConvertTo-CommandLineArgument -Argument $_ }
            $workerProcess = Start-Process -FilePath $powerShellExecutable -ArgumentList ($quotedArguments -join ' ') -WorkingDirectory $systemDirectory -Verb RunAs -PassThru -ErrorAction Stop
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
    Wait-DockerDesktopTrim
    Stop-DockerDesktop
    $exitCode = Invoke-NativeCommand -FilePath $wslPath -ArgumentList @('--shutdown') -StandardOutputEncoding ([System.Text.UTF8Encoding]::new($false))
    if ($exitCode -ne 0) {
        Write-Warning "wsl --shutdown failed with exit code $exitCode, skipping compaction."
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
          1. Cleanup inside each distribution except Docker Desktop's own: apt-get autoremove
             and clean, and docker system prune --all against the engine that docker reaches
             there, never a remote one. With Docker Desktop's WSL integration that is Docker
             Desktop's engine, which is pruned once. Volumes are pruned only on Docker
             Engine 23.0 and later, which keeps named volumes.
          2. fstrim on the root file system, so freed blocks are handed back to
             the virtual disk and can actually be reclaimed by the compaction.
          3. Stop Docker Desktop and shut down WSL, releasing all .vhdx files.
          4. Compact the virtual disk of every distribution and Docker Desktop's data disk
             with diskpart and report how much space was reclaimed. Sparse, compressed,
             encrypted and fixed-size disks are skipped.

        Only phase 4 needs administrator rights; without them, it asks for them (UAC).

    .PARAMETER DistributionName
        Limit cleanup and compaction to these distributions; tab completion lists
        the installed ones. Docker Desktop's data disk is addressed as 'docker-desktop-data'.
        Unknown names make the command end with an error.

    .PARAMETER SkipPackageCleanup
        Do not run apt-get autoremove / clean.

    .PARAMETER SkipDockerPrune
        Do not run docker system prune.

    .PARAMETER SkipCompaction
        Only run the package cleanup and the Docker prune; skip fstrim, the WSL shutdown
        and the compaction.

    .PARAMETER Force
        Skip the confirmation prompt before pruning Docker data. Without -Force, a run that
        gets no answer (-NonInteractive, or input that ends before an answer) ends with an error.

    .EXAMPLE
        Optimize-WslDiskSpace

    .EXAMPLE
        Optimize-WslDiskSpace -DistributionName Ubuntu, docker-desktop-data -Force

    .EXAMPLE
        Optimize-WslDiskSpace -SkipCompaction

    .NOTES
        - Start it from a normal terminal. The cleanup runs as you; only the compaction
          asks for administrator rights (UAC). With Windows sudo in inline mode, and if your
          own account is an administrator, it runs in the same window, otherwise in a
          separate window that closes when done and stays open if a disk failed.
        - Close VS Code windows and terminals connected to WSL first: they start a
          distribution again right after the shutdown. A disk in use is retried once after
          another shutdown.
        - In a scheduled task, use "Run only when user is logged on", "Run with highest
          privileges" and -Force, because nobody can answer a UAC prompt or the confirmation.
          A standard user whose administrator is a different account cannot run it unattended.
        - WSL is always shut down completely, even if only some disks are compacted.
        - Docker Desktop is stopped but not restarted.
        - Ends with an error if any step failed, so a scheduled
          'pwsh -Command Optimize-WslDiskSpace -Force' exits with code 1.
        - Ctrl+C stops the run once the running Linux command has finished. Ctrl+C in the
          window that runs the compaction cancels it and detaches its disk.
        - Progress output (e.g. diskpart's percentage) is redrawn in place next to
          a spinner. When standard output is redirected, only completed lines are written.
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

    # An inherited 'Stop' would end the whole run at the first failing step.
    $ErrorActionPreference = 'Continue'
    $script:hasFailures = $false
    $script:dockerDesktopPruneTimer = $null
    # Makes wsl.exe write its own messages as UTF-8 instead of UTF-16 (restored afterwards).
    $previousWslUtf8Value = $env:WSL_UTF8
    $env:WSL_UTF8 = '1'

    try {
        if (Test-IsWow64Process) {
            throw 'Run Optimize-WslDiskSpace in 64-bit PowerShell, not in PowerShell (x86).'
        }
        if (-not (Test-Path -LiteralPath $wslPath -PathType Leaf)) {
            throw 'wsl.exe was not found. Is WSL installed?'
        }

        $isFiltered = $PSBoundParameters.ContainsKey('DistributionName')
        if ($isFiltered) {
            # Also accepts 'Ubuntu,Debian' as a single string, e.g. from a scheduled task.
            $DistributionName = @($DistributionName -split ',' | ForEach-Object Trim | Where-Object { $_ })
            if ($DistributionName.Count -eq 0) {
                throw '-DistributionName contains no distribution name.'
            }
        }

        $allDistributions = @(Get-WslDistribution)
        $distributions = $allDistributions
        if ($isFiltered) {
            $knownNames = @($allDistributions | ForEach-Object Name) + $dockerDataDiskName
            foreach ($requestedName in $DistributionName) {
                if ($knownNames -notcontains $requestedName) {
                    Write-Warning "Unknown distribution '$requestedName' is ignored."
                    $script:hasFailures = $true
                }
            }
            $distributions = @($allDistributions | Where-Object { $DistributionName -contains $_.Name })
        }
        # Docker Desktop's internal distributions are managed by Docker itself.
        $cleanupDistributions = @($distributions | Where-Object { $_.Name -notlike 'docker-desktop*' })

        $virtualDisks = @()
        if (-not $SkipCompaction) {
            # All distributions, so a moved Docker data disk is found next to docker-desktop.
            $virtualDisks = @(Get-VirtualDiskTarget -Distributions $allDistributions)
            if ($isFiltered) {
                $virtualDisks = @($virtualDisks | Where-Object { $DistributionName -contains $_.Name })
            }
        }

        Write-Section 'WSL distributions'
        Write-Host "  Clean up: $(Format-NameList -Name ($cleanupDistributions | ForEach-Object Name))"
        if ($SkipCompaction) {
            Write-Host '  Compact:  (skipped)'
        }
        else {
            Write-Host "  Compact:  $(Format-NameList -Name ($virtualDisks | ForEach-Object Name))"
        }

        $dockerEngines = @()
        if (-not $SkipDockerPrune) {
            $reachableEngines = @($cleanupDistributions | ForEach-Object { Get-DockerEngine -DistributionName $_.Name })
            # Only Docker Desktop's engine is shared: a native engine's ID is copied along with a cloned distribution.
            $engineIds = [System.Collections.Generic.HashSet[string]]::new()
            $dockerEngines = @($reachableEngines | Where-Object { $_.OperatingSystem -ne 'Docker Desktop' -or $engineIds.Add($_.Id) })
        }

        if ($dockerEngines.Count -gt 0 -and -not $Force) {
            Write-Host ''
            Write-Warning ("docker system prune will run for: $(@($dockerEngines | ForEach-Object { Get-DockerEngineLabel -Engine $_ }) -join ', '). " +
                'It removes ALL stopped containers, unused images, networks and build cache, ' +
                'and on Docker Engine 23.0 and later also anonymous volumes.')
            $confirmation = Read-Confirmation -Prompt 'Continue? [y/N]'
            if ($null -eq $confirmation) {
                $PSCmdlet.ThrowTerminatingError((New-ErrorRecord -ErrorId 'ConfirmationUnavailable' -Message (
                    'The prune could not be confirmed because this session cannot ask. ' +
                    'Use -Force to prune without asking, or -SkipDockerPrune.')))
            }
            if (-not $confirmation) {
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
                    Write-Host '  apt-get autoremove; apt-get clean'
                    Invoke-DistributionCommand -DistributionName $distribution.Name -ShellCommand $packageCleanupCommand -AsRoot
                }
                else {
                    Write-Host '  apt-get not available, skipping package cleanup.'
                }
            }

            if (-not $SkipDockerPrune) {
                $dockerEngine = $dockerEngines | Where-Object DistributionName -eq $distribution.Name | Select-Object -First 1
                $reachedEngine = $reachableEngines | Where-Object DistributionName -eq $distribution.Name | Select-Object -First 1
                if ($dockerEngine) {
                    $pruneArguments = Get-DockerPruneArgument -ApiVersion $dockerEngine.ApiVersion
                    Write-Host "  docker system prune $pruneArguments"
                    Invoke-DistributionCommand -DistributionName $distribution.Name -AsRoot `
                        -ShellCommand "$dockerEnvironmentReset; docker --context default system prune $pruneArguments"
                    if ($dockerEngine.OperatingSystem -eq 'Docker Desktop') {
                        $script:dockerDesktopPruneTimer = [System.Diagnostics.Stopwatch]::StartNew()
                    }
                }
                elseif ($reachedEngine) {
                    $prunedEngine = $dockerEngines | Where-Object Id -eq $reachedEngine.Id | Select-Object -First 1
                    Write-Host "  Same Docker engine as in '$($prunedEngine.DistributionName)', not pruned again."
                }
                else {
                    Write-Host '  Docker not installed or daemon not reachable, skipping prune.'
                }
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
        elseif ($virtualDisks.Count -eq 0) {
            Write-Warning 'No virtual disks found to compact. WSL and Docker Desktop are left running.'
        }
        else {
            Invoke-CompactionPhase -VirtualDisks $virtualDisks
        }
    }
    finally {
        $env:WSL_UTF8 = $previousWslUtf8Value
    }

    if ($script:hasFailures) {
        # A terminating error, because Write-Error does not reliably mark the call as failed:
        # this way a scheduled 'pwsh -Command Optimize-WslDiskSpace' exits with code 1.
        $PSCmdlet.ThrowTerminatingError((New-ErrorRecord -ErrorId 'OptimizeWslDiskSpaceFailed' -Message 'One or more steps failed, see the warnings above.'))
    }
}

#endregion

Export-ModuleMember -Function 'Optimize-WslDiskSpace'
