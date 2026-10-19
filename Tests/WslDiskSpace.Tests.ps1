# Pester 5.1 or later. Run from the repository root: Invoke-Pester -Path .\Tests
# Never let a test run wsl.exe, diskpart.exe, docker.exe or sudo.exe: an accidental 'wsl --shutdown' ends
# every WSL session. The module's tool paths point to a missing folder, the helpers that start
# processes are mocked, and the tools themselves are blocked by name. Tests tagged 'WSL' run in
# $env:WSLDISKSPACE_TEST_DISTRIBUTION, if it is set.

BeforeAll {
    Get-Module -Name WslDiskSpace | Remove-Module -Force
    Import-Module -Name (Join-Path $PSScriptRoot '..\WslDiskSpace.psd1') -Force -ErrorAction Stop
    $script:defaultPaths = InModuleScope WslDiskSpace {
        @{ Wsl = $wslPath; Diskpart = $diskpartPath; Sudo = $sudoPath; ScriptDirectory = $diskpartScriptDirectory }
    }
    InModuleScope WslDiskSpace {
        $script:wslPath = 'C:\WslDiskSpaceTests\wsl.exe'
        $script:diskpartPath = 'C:\WslDiskSpaceTests\diskpart.exe'
        $script:sudoPath = 'C:\WslDiskSpaceTests\sudo.exe'
        $script:diskpartScriptDirectory = [System.IO.Path]::GetTempPath()
    }
    foreach ($tool in 'wsl.exe', 'diskpart.exe', 'sudo.exe', 'docker.exe') {
        if (Get-Command -Name $tool -CommandType Application -ErrorAction Ignore) {
            Mock -ModuleName WslDiskSpace -CommandName $tool -MockWith { throw 'A test tried to run a real tool.' }
        }
    }
}

AfterAll {
    Get-Module -Name WslDiskSpace | Remove-Module -Force
}

Describe 'tool paths' {
    It 'runs the tools from the system directory and keeps diskpart scripts in the system Temp folder' {
        $systemDirectory = Join-Path $env:SystemRoot 'System32'

        $script:defaultPaths.Wsl | Should -BeExactly (Join-Path $systemDirectory 'wsl.exe')
        $script:defaultPaths.Diskpart | Should -BeExactly (Join-Path $systemDirectory 'diskpart.exe')
        $script:defaultPaths.Sudo | Should -BeExactly (Join-Path $systemDirectory 'sudo.exe')
        $script:defaultPaths.ScriptDirectory | Should -BeExactly (Join-Path $env:SystemRoot 'Temp')
    }
}

Describe 'ConvertTo-CommandLineArgument' {
    BeforeAll {
        if (-not ('WslDiskSpaceTests.CommandLine' -as [type])) {
            Add-Type -Namespace WslDiskSpaceTests -Name CommandLine -MemberDefinition @'
[DllImport("shell32.dll", SetLastError = true)]
private static extern IntPtr CommandLineToArgvW([MarshalAs(UnmanagedType.LPWStr)] string commandLine, out int argumentCount);

[DllImport("kernel32.dll")]
private static extern IntPtr LocalFree(IntPtr memory);

public static string[] Split(string commandLine) {
    int argumentCount;
    IntPtr argumentPointers = CommandLineToArgvW(commandLine, out argumentCount);
    try {
        string[] arguments = new string[argumentCount];
        for (int index = 0; index < argumentCount; index++) {
            arguments[index] = Marshal.PtrToStringUni(Marshal.ReadIntPtr(argumentPointers, index * IntPtr.Size));
        }
        return arguments;
    }
    finally {
        LocalFree(argumentPointers);
    }
}
'@
        }
    }

    It 'round-trips <Name> through CommandLineToArgvW' -ForEach @(
        @{ Name = 'a plain word'; Argument = 'plain' }
        @{ Name = 'an empty string'; Argument = '' }
        @{ Name = 'spaces'; Argument = 'a b  c' }
        @{ Name = 'quotes'; Argument = 'say "hi"' }
        @{ Name = 'backslashes before a quote'; Argument = 'a\\"b' }
        @{ Name = 'a trailing backslash'; Argument = 'C:\Program Files\x\' }
        @{ Name = 'a shell command'; Argument = 'unset A; command -v docker >/dev/null && echo ok' }
        # Regression: '$' also matched in front of a final line feed, so the backslash before it was doubled.
        @{ Name = 'a backslash before a final line feed'; Argument = "a\`n" }
    ) {
        $quotedArgument = InModuleScope WslDiskSpace -Parameters @{ Argument = $Argument } {
            param($Argument)
            ConvertTo-CommandLineArgument -Argument $Argument
        }

        [WslDiskSpaceTests.CommandLine]::Split("program.exe $quotedArgument")[1] | Should -BeExactly $Argument
    }
}

Describe 'output renderer' {
    It 'draws the spinner line on the host only' {
        # Regression: Write-Host put every spinner frame into transcripts and *> logs.
        $records = InModuleScope WslDiskSpace {
            $renderer = New-OutputRenderer
            $renderer.IsInteractive = $true
            $renderer.ConsoleWidth = 80
            [void]$renderer.CurrentSegment.Append('42 percent completed')
            & {
                Write-RendererStatus -Renderer $renderer
                Clear-RendererStatus -Renderer $renderer
            } *>&1
        }

        $records | Should -BeNullOrEmpty
    }

    It 'writes completed lines and keeps progress updates that end with a lone CR out of them' {
        $records = InModuleScope WslDiskSpace {
            $renderer = New-OutputRenderer
            $renderer.IsInteractive = $false
            & { Add-RendererText -Renderer $renderer -Text "first`r`n10 percent`r20 percent`rsecond`n" } 6>&1
        }

        @($records | ForEach-Object { "$_" }) | Should -Be @('    first', '    second')
    }
}

Describe 'native process helpers' {
    BeforeAll {
        # Started from WSL, the working directory is a UNC path, and cmd.exe warns about it on stderr.
        $script:previousDirectory = [Environment]::CurrentDirectory
        [Environment]::CurrentDirectory = $env:SystemRoot
    }

    AfterAll {
        [Environment]::CurrentDirectory = $script:previousDirectory
    }

    It 'gives a command a hidden console of its own and redirects all of its streams' {
        # Regression: wsl.exe shared the console, so Ctrl+C reached Linux and piped answers were consumed.
        $startInfo = InModuleScope WslDiskSpace {
            New-NativeStartInfo -FilePath 'tool.exe' -ArgumentList @('/x', 'a b') -OutputEncoding ([System.Text.Encoding]::UTF8)
        }

        $startInfo.UseShellExecute | Should -BeFalse
        $startInfo.CreateNoWindow | Should -BeTrue
        $startInfo.RedirectStandardInput | Should -BeTrue
        $startInfo.RedirectStandardOutput | Should -BeTrue
        $startInfo.RedirectStandardError | Should -BeTrue
        $startInfo.Arguments | Should -BeExactly '/x "a b"'
    }

    It 'shows the error output of a command after its regular output and returns its exit code' {
        $output = InModuleScope WslDiskSpace {
            & { Invoke-NativeCommand -FilePath $env:ComSpec -ArgumentList @('/d', '/c', 'echo out& echo err 1>&2& exit 3') } 6>&1
        }

        @($output | Where-Object { $_ -is [int] }) | Should -Be @(3)
        @($output | Where-Object { $_ -is [System.Management.Automation.InformationRecord] } | ForEach-Object { "$_".Trim() }) |
            Should -Be @('out', 'err')
    }

    It 'returns the exit code and output of a command' {
        $result = InModuleScope WslDiskSpace {
            Get-NativeCommandResult -FilePath $env:ComSpec -ArgumentList @('/d', '/c', 'echo hello& exit 4')
        }

        $result.ExitCode | Should -Be 4
        $result.Output.Trim() | Should -BeExactly 'hello'
        $result.TimedOut | Should -BeFalse
    }

    It 'stops a command that exceeds its time limit' {
        $pingPath = Join-Path $env:SystemRoot 'System32\PING.EXE'
        $result = InModuleScope WslDiskSpace -Parameters @{ PingPath = $pingPath } {
            param($PingPath)
            Get-NativeCommandResult -FilePath $PingPath -ArgumentList @('-n', '30', '127.0.0.1') -TimeoutSeconds 1
        }

        $result.TimedOut | Should -BeTrue
        $result.ExitCode | Should -BeNullOrEmpty
    }

    It 'still reads the output of a command that it waits for after Ctrl+C' {
        # Regression: after Ctrl+C nobody read the output, so a talkative command blocked and the wait never ended.
        $tag = [guid]::NewGuid().ToString('N')
        $powerShell = [powershell]::Create()
        try {
            $null = $powerShell.AddScript({
                param($Manifest, $Tag)
                Import-Module -Name $Manifest
                & (Get-Module -Name 'WslDiskSpace') {
                    param($Tag)
                    $script:wslPath = 'C:\WslDiskSpaceTests\wsl.exe'
                    $script:diskpartPath = 'C:\WslDiskSpaceTests\diskpart.exe'
                    $script:sudoPath = 'C:\WslDiskSpaceTests\sudo.exe'
                    Invoke-NativeCommand -FilePath $env:ComSpec -ArgumentList @('/d', '/c', "ping -n 3 127.0.0.1 >nul & for /l %i in (1,1,300) do @echo $Tag $Tag $Tag")
                } $Tag
            }).AddArgument((Join-Path $PSScriptRoot '..\WslDiskSpace.psd1')).AddArgument($tag)
            $null = $powerShell.BeginInvoke()
            Start-Sleep -Milliseconds 1000
            $stop = $powerShell.BeginStop($null, $null)

            $stop.AsyncWaitHandle.WaitOne(15000) | Should -BeTrue
        }
        finally {
            Get-CimInstance -ClassName Win32_Process -Filter "Name = 'cmd.exe'" | Where-Object CommandLine -like "*$tag*" |
                ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
            $powerShell.Dispose()
        }
    }
}

Describe 'distribution commands' {
    It 'probes a distribution through a detached wsl.exe' {
        # Regression: '& wsl.exe' shared the console and read input that was piped in for the prompt.
        Mock -ModuleName WslDiskSpace -CommandName Get-NativeCommandResult -MockWith {
            [pscustomobject]@{ ExitCode = 0; Output = ''; ErrorOutput = ''; TimedOut = $false }
        }

        InModuleScope WslDiskSpace { Test-DistributionCommand -DistributionName 'Ubuntu' -ShellCommand 'true' } | Should -BeTrue
        Should -Invoke -ModuleName WslDiskSpace -CommandName Get-NativeCommandResult -Times 1 -Exactly -ParameterFilter {
            $FilePath -eq 'C:\WslDiskSpaceTests\wsl.exe' -and ($ArgumentList -join ' ') -eq '--distribution Ubuntu --exec sh -c true'
        }
    }

    It 'runs a command as root with UTF-8 output' {
        Mock -ModuleName WslDiskSpace -CommandName Invoke-NativeCommand -MockWith { 0 }

        InModuleScope WslDiskSpace { Invoke-DistributionCommand -DistributionName 'Ubuntu' -ShellCommand 'fstrim /' -AsRoot }
        Should -Invoke -ModuleName WslDiskSpace -CommandName Invoke-NativeCommand -Times 1 -Exactly -ParameterFilter {
            $FilePath -eq 'C:\WslDiskSpaceTests\wsl.exe' -and
            ($ArgumentList -join ' ') -eq '--distribution Ubuntu --user root --exec sh -c exec 2>&1; fstrim /' -and
            $StandardOutputEncoding.WebName -eq 'utf-8'
        }
    }
}

Describe 'Docker engines' {
    BeforeAll {
        Mock -ModuleName WslDiskSpace -CommandName Get-NativeCommandResult -MockWith { throw "Unexpected native command: $FilePath" }
    }

    It 'reports the engine that docker reaches inside a distribution' {
        Mock -ModuleName WslDiskSpace -CommandName Get-NativeCommandResult -MockWith {
            [pscustomobject]@{ ExitCode = 0; Output = "1.51`nENGINE-ID|Docker Desktop`n"; ErrorOutput = ''; TimedOut = $false }
        }

        $engine = InModuleScope WslDiskSpace { Get-DockerEngine -DistributionName 'Ubuntu' }

        $engine.DistributionName | Should -BeExactly 'Ubuntu'
        $engine.Id | Should -BeExactly 'ENGINE-ID'
        $engine.OperatingSystem | Should -BeExactly 'Docker Desktop'
        $engine.ApiVersion | Should -BeExactly '1.51'
        Should -Invoke -ModuleName WslDiskSpace -CommandName Get-NativeCommandResult -Times 1 -Exactly -ParameterFilter {
            $FilePath -eq 'C:\WslDiskSpaceTests\wsl.exe' -and
            ($ArgumentList -join ' ') -like '--distribution Ubuntu --user root --exec sh -c *' -and
            $ArgumentList[-1] -like 'unset DOCKER_HOST DOCKER_CONTEXT;*--context default*'
        }
    }

    It 'ignores messages that wsl.exe prints before the output' {
        Mock -ModuleName WslDiskSpace -CommandName Get-NativeCommandResult -MockWith {
            [pscustomobject]@{ ExitCode = 0; Output = "wsl: some notice`n1.41`nOLD-ENGINE|Debian GNU/Linux 12 (bookworm)`n"; ErrorOutput = ''; TimedOut = $false }
        }

        $engine = InModuleScope WslDiskSpace { Get-DockerEngine -DistributionName 'Debian' }

        $engine.ApiVersion | Should -BeExactly '1.41'
        $engine.Id | Should -BeExactly 'OLD-ENGINE'
    }

    It 'reports nothing when no Docker daemon is reachable' {
        Mock -ModuleName WslDiskSpace -CommandName Get-NativeCommandResult -MockWith {
            [pscustomobject]@{ ExitCode = 1; Output = ''; ErrorOutput = 'Cannot connect to the Docker daemon'; TimedOut = $false }
        }

        InModuleScope WslDiskSpace { Get-DockerEngine -DistributionName 'Ubuntu' } | Should -BeNullOrEmpty
    }

    It 'prunes volumes with API version <ApiVersion> (Docker Engine 23.0 and later)' -ForEach @(
        @{ ApiVersion = '1.42' }
        @{ ApiVersion = '1.51' }
    ) {
        InModuleScope WslDiskSpace -Parameters @{ ApiVersion = $ApiVersion } {
            param($ApiVersion)
            Get-DockerPruneArgument -ApiVersion $ApiVersion
        } | Should -BeExactly '--all --volumes --force'
    }

    It 'keeps volumes with API version "<ApiVersion>", where --volumes would also delete named volumes' -ForEach @(
        @{ ApiVersion = '1.41' }
        @{ ApiVersion = '' }
        @{ ApiVersion = 'unknown' }
    ) {
        # Regression: Docker Engine older than 23.0 deleted unused named volumes, e.g. of a stopped database.
        InModuleScope WslDiskSpace -Parameters @{ ApiVersion = $ApiVersion } {
            param($ApiVersion)
            Get-DockerPruneArgument -ApiVersion $ApiVersion
        } | Should -BeExactly '--all --force'
    }

    It 'names Docker Desktop together with the distribution it is reached through' {
        InModuleScope WslDiskSpace {
            Get-DockerEngineLabel -Engine ([pscustomobject]@{ DistributionName = 'Ubuntu'; OperatingSystem = 'Docker Desktop' })
        } | Should -BeExactly 'Docker Desktop (via Ubuntu)'
        InModuleScope WslDiskSpace {
            Get-DockerEngineLabel -Engine ([pscustomobject]@{ DistributionName = 'Debian'; OperatingSystem = 'Debian GNU/Linux 12 (bookworm)' })
        } | Should -BeExactly 'Debian'
    }
}

Describe 'Optimize-WslDiskSpace' {
    BeforeAll {
        Mock -ModuleName WslDiskSpace -CommandName Invoke-NativeCommand -MockWith { throw "Unexpected native command: $FilePath" }
        Mock -ModuleName WslDiskSpace -CommandName Get-NativeCommandResult -MockWith { throw "Unexpected native command: $FilePath" }
        Mock -ModuleName WslDiskSpace -CommandName Start-Process -MockWith { throw 'Unexpected Start-Process' }
        Mock -ModuleName WslDiskSpace -CommandName Stop-Process -MockWith { throw 'Unexpected Stop-Process' }
    }

    BeforeEach {
        Mock -ModuleName WslDiskSpace -CommandName Test-Path -ParameterFilter { $LiteralPath -like '*\wsl.exe' } -MockWith { $true }
        Mock -ModuleName WslDiskSpace -CommandName Get-WslDistribution -MockWith {
            [pscustomobject]@{ Name = 'Ubuntu'; VirtualDiskPath = 'C:\Fake\Ubuntu\ext4.vhdx' }
            [pscustomobject]@{ Name = 'Debian'; VirtualDiskPath = 'C:\Fake\Debian\ext4.vhdx' }
            [pscustomobject]@{ Name = 'docker-desktop'; VirtualDiskPath = 'C:\Fake\Docker\main\ext4.vhdx' }
        }
        Mock -ModuleName WslDiskSpace -CommandName Get-VirtualDiskTarget -MockWith {
            [pscustomobject]@{ Name = 'Ubuntu'; Path = 'C:\Fake\Ubuntu\ext4.vhdx' }
            [pscustomobject]@{ Name = 'Debian'; Path = 'C:\Fake\Debian\ext4.vhdx' }
            [pscustomobject]@{ Name = 'docker-desktop'; Path = 'C:\Fake\Docker\main\ext4.vhdx' }
            [pscustomobject]@{ Name = 'docker-desktop-data'; Path = 'C:\Fake\Docker\disk\docker_data.vhdx' }
        }
        Mock -ModuleName WslDiskSpace -CommandName Test-DistributionCommand -MockWith { $true }
        Mock -ModuleName WslDiskSpace -CommandName Get-DockerEngine -MockWith {
            if ($DistributionName -eq 'Ubuntu') {
                [pscustomobject]@{ DistributionName = 'Ubuntu'; Id = 'NATIVE-UBUNTU'; OperatingSystem = 'Ubuntu 24.04 LTS'; ApiVersion = '1.51' }
            }
        }
        Mock -ModuleName WslDiskSpace -CommandName Invoke-DistributionCommand -MockWith { }
        Mock -ModuleName WslDiskSpace -CommandName Invoke-CompactionPhase -MockWith { }
        Mock -ModuleName WslDiskSpace -CommandName Read-Host -MockWith { throw 'Unexpected prompt' }
        Mock -ModuleName WslDiskSpace -CommandName Write-Host -MockWith { }
        Mock -ModuleName WslDiskSpace -CommandName Write-Warning -MockWith { }
    }

    Context 'confirmation before the Docker prune' {
        It 'stops with an error instead of pruning when no answer can be read' {
            # Regression: at the end of redirected input Read-Host returns nothing, and that counted as yes.
            Mock -ModuleName WslDiskSpace -CommandName Read-Host -MockWith { }

            { Optimize-WslDiskSpace -SkipCompaction } | Should -Throw '*-Force*'
            Should -Invoke -ModuleName WslDiskSpace -CommandName Invoke-DistributionCommand -Times 0 -Exactly
        }

        It 'stops with an error when it cannot prompt at all' {
            # Regression: under -NonInteractive the failed prompt ended the run silently with exit code 0.
            Mock -ModuleName WslDiskSpace -CommandName Read-Host -MockWith {
                throw [System.Management.Automation.PSInvalidOperationException]::new('PowerShell is in NonInteractive mode.')
            }

            { Optimize-WslDiskSpace -SkipCompaction } | Should -Throw '*-Force*'
            Should -Invoke -ModuleName WslDiskSpace -CommandName Invoke-DistributionCommand -Times 0 -Exactly
        }

        It 'changes nothing when the answer is no' {
            Mock -ModuleName WslDiskSpace -CommandName Read-Host -MockWith { 'n' }

            Optimize-WslDiskSpace -SkipCompaction

            Should -Invoke -ModuleName WslDiskSpace -CommandName Invoke-DistributionCommand -Times 0 -Exactly
        }

        It 'prunes after the answer yes' {
            Mock -ModuleName WslDiskSpace -CommandName Read-Host -MockWith { 'y' }

            Optimize-WslDiskSpace -SkipCompaction

            Should -Invoke -ModuleName WslDiskSpace -CommandName Invoke-DistributionCommand -Times 1 -Exactly -ParameterFilter {
                $DistributionName -eq 'Ubuntu' -and
                $ShellCommand -eq 'unset DOCKER_HOST DOCKER_CONTEXT; docker --context default system prune --all --volumes --force'
            }
        }

        It 'names the Docker engines in the prompt, Docker Desktop included' {
            Mock -ModuleName WslDiskSpace -CommandName Get-DockerEngine -MockWith {
                [pscustomobject]@{ DistributionName = $DistributionName; Id = 'DOCKER-DESKTOP'; OperatingSystem = 'Docker Desktop'; ApiVersion = '1.51' }
            }
            Mock -ModuleName WslDiskSpace -CommandName Read-Host -MockWith { 'n' }

            Optimize-WslDiskSpace -SkipCompaction

            Should -Invoke -ModuleName WslDiskSpace -CommandName Write-Warning -ParameterFilter { $Message -like '*Docker Desktop (via Ubuntu)*' }
        }
    }

    Context 'Docker prune' {
        It 'prunes an engine only once when several distributions reach it' {
            # Regression: with Docker Desktop's WSL integration every integrated distribution pruned the same engine.
            Mock -ModuleName WslDiskSpace -CommandName Get-DockerEngine -MockWith {
                [pscustomobject]@{ DistributionName = $DistributionName; Id = 'DOCKER-DESKTOP'; OperatingSystem = 'Docker Desktop'; ApiVersion = '1.51' }
            }

            Optimize-WslDiskSpace -SkipCompaction -Force

            Should -Invoke -ModuleName WslDiskSpace -CommandName Invoke-DistributionCommand -Times 1 -Exactly -ParameterFilter {
                $ShellCommand -like '*system prune*'
            }
        }

        It 'prunes the native engines of cloned distributions separately, although they report the same ID' {
            # Regression: a native engine's ID lives in the distribution's files, so a clone shares it and was not pruned.
            Mock -ModuleName WslDiskSpace -CommandName Get-DockerEngine -MockWith {
                if ($DistributionName -ne 'docker-desktop') {
                    [pscustomobject]@{ DistributionName = $DistributionName; Id = 'CLONED-ENGINE'; OperatingSystem = 'Ubuntu 24.04 LTS'; ApiVersion = '1.51' }
                }
            }

            Optimize-WslDiskSpace -SkipCompaction -Force

            Should -Invoke -ModuleName WslDiskSpace -CommandName Invoke-DistributionCommand -Times 2 -Exactly -ParameterFilter {
                $ShellCommand -like '*system prune*'
            }
        }

        It 'keeps volumes on a Docker Engine older than 23.0' {
            Mock -ModuleName WslDiskSpace -CommandName Get-DockerEngine -MockWith {
                if ($DistributionName -eq 'Ubuntu') {
                    [pscustomobject]@{ DistributionName = 'Ubuntu'; Id = 'OLD-ENGINE'; OperatingSystem = 'Ubuntu 22.04 LTS'; ApiVersion = '1.41' }
                }
            }

            Optimize-WslDiskSpace -SkipCompaction -Force

            Should -Invoke -ModuleName WslDiskSpace -CommandName Invoke-DistributionCommand -Times 1 -Exactly -ParameterFilter {
                $ShellCommand -like '*system prune*' -and $ShellCommand -notlike '*--volumes*'
            }
        }

        It 'remembers a prune of Docker Desktop, so that its data disk can be trimmed before it is stopped' {
            Mock -ModuleName WslDiskSpace -CommandName Get-DockerEngine -MockWith {
                if ($DistributionName -eq 'Ubuntu') {
                    [pscustomobject]@{ DistributionName = 'Ubuntu'; Id = 'DOCKER-DESKTOP'; OperatingSystem = 'Docker Desktop'; ApiVersion = '1.51' }
                }
            }

            Optimize-WslDiskSpace -SkipPackageCleanup -Force

            InModuleScope WslDiskSpace { $script:dockerDesktopPruneTimer } | Should -Not -BeNullOrEmpty
        }

        It 'does not wait for a trim after a prune of a native engine' {
            Optimize-WslDiskSpace -SkipPackageCleanup -Force

            InModuleScope WslDiskSpace { $script:dockerDesktopPruneTimer } | Should -BeNullOrEmpty
        }
    }

    Context 'environment' {
        It 'refuses to run in 32-bit PowerShell on 64-bit Windows' {
            # Regression: System32 is redirected there, so wsl.exe was reported as not installed.
            Mock -ModuleName WslDiskSpace -CommandName Test-IsWow64Process -MockWith { $true }

            { Optimize-WslDiskSpace -SkipCompaction -Force } | Should -Throw '*64-bit*'
            Should -Invoke -ModuleName WslDiskSpace -CommandName Invoke-DistributionCommand -Times 0 -Exactly
        }
    }

    Context 'selection' {
        It 'rejects -DistributionName without a distribution name (<Label>)' -ForEach @(
            @{ Label = 'blank'; Value = ' , ' }
            @{ Label = 'empty'; Value = '' }
            @{ Label = 'null'; Value = $null }
        ) {
            # Regression: an empty or blank value selected every distribution.
            { Optimize-WslDiskSpace -DistributionName $Value -SkipCompaction -Force } | Should -Throw '*no distribution name*'
            Should -Invoke -ModuleName WslDiskSpace -CommandName Invoke-DistributionCommand -Times 0 -Exactly
        }

        It 'ends with an error when a distribution name is unknown' {
            # Regression: a typo only printed a warning, and a scheduled run reported success.
            { Optimize-WslDiskSpace -DistributionName 'Ubunto' -SkipCompaction -Force } | Should -Throw '*failed*'
        }

        It 'lists what it cleans up and what it compacts' {
            Optimize-WslDiskSpace -SkipDockerPrune -SkipPackageCleanup

            Should -Invoke -ModuleName WslDiskSpace -CommandName Write-Host -ParameterFilter { "$Object" -eq '  Clean up: Ubuntu, Debian' }
            Should -Invoke -ModuleName WslDiskSpace -CommandName Write-Host -ParameterFilter {
                "$Object" -eq '  Compact:  Ubuntu, Debian, docker-desktop, docker-desktop-data'
            }
        }

        It 'compacts only the selected disks' {
            Optimize-WslDiskSpace -DistributionName 'docker-desktop-data' -SkipDockerPrune

            Should -Invoke -ModuleName WslDiskSpace -CommandName Invoke-CompactionPhase -Times 1 -Exactly -ParameterFilter {
                @($VirtualDisks).Count -eq 1 -and $VirtualDisks[0].Name -eq 'docker-desktop-data'
            }
        }
    }
}

Describe 'Test-InlineSudoEnabled' {
    BeforeEach {
        Mock -ModuleName WslDiskSpace -CommandName Test-Path -ParameterFilter { $LiteralPath -like '*sudo.exe' } -MockWith { $true }
        Mock -ModuleName WslDiskSpace -CommandName Get-ItemProperty -ParameterFilter { $Path -like '*\CurrentVersion\Sudo' } -MockWith {
            [pscustomobject]@{ Enabled = 3 }
        }
        Mock -ModuleName WslDiskSpace -CommandName Get-ItemProperty -ParameterFilter { $Path -like '*\Policies\*' } -MockWith { }
        Mock -ModuleName WslDiskSpace -CommandName Test-HasFilteredAdministratorToken -MockWith { $true }
    }

    It 'uses inline sudo for an administrator in admin approval mode' {
        InModuleScope WslDiskSpace { Test-InlineSudoEnabled } | Should -BeTrue
    }

    It 'leaves the elevation to UAC when the administrator is a different account' {
        # Regression: sudo refuses standard users, so their compaction never ran.
        Mock -ModuleName WslDiskSpace -CommandName Test-HasFilteredAdministratorToken -MockWith { $false }

        InModuleScope WslDiskSpace { Test-InlineSudoEnabled } | Should -BeFalse
    }

    It 'leaves the elevation to UAC when Group Policy limits sudo' {
        Mock -ModuleName WslDiskSpace -CommandName Get-ItemProperty -ParameterFilter { $Path -like '*\Policies\*' } -MockWith {
            [pscustomobject]@{ Enabled = 1 }
        }

        InModuleScope WslDiskSpace { Test-InlineSudoEnabled } | Should -BeFalse
    }

    It 'ignores a policy key without a value' {
        Mock -ModuleName WslDiskSpace -CommandName Get-ItemProperty -ParameterFilter { $Path -like '*\Policies\*' } -MockWith {
            [pscustomobject]@{ }
        }

        InModuleScope WslDiskSpace { Test-InlineSudoEnabled } | Should -BeTrue
    }
}

Describe 'Get-ElevatedPowerShellPath' {
    It 'uses pwsh.exe of an installed PowerShell 7' {
        InModuleScope WslDiskSpace {
            Get-ElevatedPowerShellPath -Edition 'Core' -PowerShellHome 'C:\Program Files\PowerShell\7'
        } | Should -BeExactly 'C:\Program Files\PowerShell\7\pwsh.exe'
    }

    It 'uses Windows PowerShell instead of a Microsoft Store pwsh.exe' {
        # Regression: a Store pwsh.exe cannot be started by a different administrator account.
        InModuleScope WslDiskSpace {
            Get-ElevatedPowerShellPath -Edition 'Core' -PowerShellHome 'C:\Program Files\WindowsApps\Microsoft.PowerShell_7.5.4.0_x64__8wekyb3d8bbwe'
        } | Should -BeLike '*\WindowsPowerShell\v1.0\powershell.exe'
    }

    It 'uses Windows PowerShell when it runs in Windows PowerShell' {
        InModuleScope WslDiskSpace {
            Get-ElevatedPowerShellPath -Edition 'Desktop' -PowerShellHome 'C:\Windows\System32\WindowsPowerShell\v1.0'
        } | Should -BeLike '*\WindowsPowerShell\v1.0\powershell.exe'
    }
}

Describe 'Invoke-ElevatedCompaction' {
    BeforeEach {
        Mock -ModuleName WslDiskSpace -CommandName Start-Process -MockWith { }
        Mock -ModuleName WslDiskSpace -CommandName Test-Path -ParameterFilter { $LiteralPath -like '*wsl-compaction-*.json' } -MockWith { $false }
        Mock -ModuleName WslDiskSpace -CommandName Write-Host -MockWith { }
        Mock -ModuleName WslDiskSpace -CommandName Write-Warning -MockWith { }
    }

    # Regression: the elevated process inherited the caller's location, e.g. a mapped drive it cannot see.
    It 'starts the separate elevated window in the system directory' {
        Mock -ModuleName WslDiskSpace -CommandName Test-InlineSudoEnabled -MockWith { $false }
        Mock -ModuleName WslDiskSpace -CommandName Get-ElevatedPowerShellPath -MockWith { 'C:\WslDiskSpaceTests\powershell.exe' }

        InModuleScope WslDiskSpace { Invoke-ElevatedCompaction -VirtualDisks @([pscustomobject]@{ Name = 'Ubuntu'; Path = 'C:\Fake\Ubuntu\ext4.vhdx' }) }

        Should -Invoke -ModuleName WslDiskSpace -CommandName Start-Process -Times 1 -Exactly -ParameterFilter {
            $FilePath -eq 'C:\WslDiskSpaceTests\powershell.exe' -and $Verb -eq 'RunAs' -and
            $WorkingDirectory -eq (Join-Path $env:SystemRoot 'System32')
        }
    }

    It 'starts inline sudo in the system directory' {
        Mock -ModuleName WslDiskSpace -CommandName Test-InlineSudoEnabled -MockWith { $true }

        InModuleScope WslDiskSpace { Invoke-ElevatedCompaction -VirtualDisks @([pscustomobject]@{ Name = 'Ubuntu'; Path = 'C:\Fake\Ubuntu\ext4.vhdx' }) }

        Should -Invoke -ModuleName WslDiskSpace -CommandName Start-Process -Times 1 -Exactly -ParameterFilter {
            $FilePath -eq 'C:\WslDiskSpaceTests\sudo.exe' -and $WorkingDirectory -eq (Join-Path $env:SystemRoot 'System32')
        }
    }
}

Describe 'Get-DiskpartCompatiblePath' {
    It 'returns an ASCII path unchanged' {
        InModuleScope WslDiskSpace {
            Get-DiskpartCompatiblePath -FilePath 'C:\Users\dg\AppData\Local\wsl\{0b3f}\ext4.vhdx'
        } | Should -BeExactly 'C:\Users\dg\AppData\Local\wsl\{0b3f}\ext4.vhdx'
    }

    It 'treats <Name> as a non-ASCII character' -ForEach @(
        @{ Name = 'U+0130'; Character = [char]0x130 }
        @{ Name = 'the Kelvin sign'; Character = [char]0x212A }
    ) {
        # Regression: case-insensitive matching folded these characters into ASCII, and diskpart got '?' in the path.
        InModuleScope WslDiskSpace -Parameters @{ FilePath = "C:\Users\$($Character)x\ext4.vhdx" } {
            param($FilePath)
            Get-DiskpartCompatiblePath -FilePath $FilePath
        } | Should -BeNullOrEmpty
    }

    It 'uses the 8.3 short name that NTFS stored for <Name>' -ForEach @(
        @{ Name = 'a name with an umlaut'; FolderName = "J$([char]0xFC)rgen" }
        # Regression: GetShortPathName keeps names like these, which look like valid 8.3 names after best-fit mapping.
        @{ Name = 'a Polish name'; FolderName = "Micha$([char]0x142)" }
        @{ Name = 'a Turkish name'; FolderName = "$([char]0x130)smail" }
    ) {
        $longNameFolder = New-Item -ItemType Directory -Path (Join-Path $TestDrive 'Folder name longer than eight characters') -Force
        $fileSystem = New-Object -ComObject 'Scripting.FileSystemObject'
        if ($fileSystem.GetFolder($longNameFolder.FullName).ShortName -eq $longNameFolder.Name) {
            Set-ItResult -Skipped -Because 'the volume of the temp folder does not create 8.3 short names'
            return
        }
        $folder = New-Item -ItemType Directory -Path (Join-Path $TestDrive $FolderName) -Force
        $diskPath = Join-Path $folder.FullName 'ext4.vhdx'
        Set-Content -LiteralPath $diskPath -Value 'test'

        $compatiblePath = InModuleScope WslDiskSpace -Parameters @{ FilePath = $diskPath } {
            param($FilePath)
            Get-DiskpartCompatiblePath -FilePath $FilePath
        }

        $compatiblePath | Should -Not -BeNullOrEmpty
        $compatiblePath | Should -Not -MatchExactly '[^\x00-\x7F]'
        Test-Path -LiteralPath $compatiblePath -PathType Leaf | Should -BeTrue
    }
}

Describe 'Test-VhdxFixedSize' {
    BeforeAll {
        # Minimal VHDX layout from MS-VHDX: identifier, region table, metadata table, file parameters.
        function New-TestVhdx {
            param([string] $Path, [uint32] $FileParameterFlags)

            $metadataRegionOffset = 1MB
            $fileParametersOffset = 64KB
            $bytes = [byte[]]::new($metadataRegionOffset + $fileParametersOffset + 64)
            [System.Text.Encoding]::ASCII.GetBytes('vhdxfile').CopyTo($bytes, 0)

            $regionTableOffset = 192KB
            [System.Text.Encoding]::ASCII.GetBytes('regi').CopyTo($bytes, $regionTableOffset)
            [BitConverter]::GetBytes([uint32]2).CopyTo($bytes, $regionTableOffset + 8)
            [guid]::new('2DC27766-F623-4200-9D64-115E9BFD4A08').ToByteArray().CopyTo($bytes, $regionTableOffset + 16)
            [BitConverter]::GetBytes([uint64](2MB)).CopyTo($bytes, $regionTableOffset + 32)
            [BitConverter]::GetBytes([uint32](1MB)).CopyTo($bytes, $regionTableOffset + 40)
            [guid]::new('8B7CA206-4790-4B9A-B8FE-575F050F886E').ToByteArray().CopyTo($bytes, $regionTableOffset + 48)
            [BitConverter]::GetBytes([uint64]$metadataRegionOffset).CopyTo($bytes, $regionTableOffset + 64)
            [BitConverter]::GetBytes([uint32](1MB)).CopyTo($bytes, $regionTableOffset + 72)

            [System.Text.Encoding]::ASCII.GetBytes('metadata').CopyTo($bytes, $metadataRegionOffset)
            [BitConverter]::GetBytes([uint16]2).CopyTo($bytes, $metadataRegionOffset + 10)
            [guid]::new('2FA54224-CD1B-4876-B211-5DBED83BF4B8').ToByteArray().CopyTo($bytes, $metadataRegionOffset + 32)
            [BitConverter]::GetBytes([uint32]($fileParametersOffset + 16)).CopyTo($bytes, $metadataRegionOffset + 48)
            [BitConverter]::GetBytes([uint32]8).CopyTo($bytes, $metadataRegionOffset + 52)
            [guid]::new('CAA16737-FA36-4D43-B3B6-33F0AA44E76B').ToByteArray().CopyTo($bytes, $metadataRegionOffset + 64)
            [BitConverter]::GetBytes([uint32]$fileParametersOffset).CopyTo($bytes, $metadataRegionOffset + 80)
            [BitConverter]::GetBytes([uint32]8).CopyTo($bytes, $metadataRegionOffset + 84)
            [BitConverter]::GetBytes([uint32](32MB)).CopyTo($bytes, $metadataRegionOffset + $fileParametersOffset)
            [BitConverter]::GetBytes($FileParameterFlags).CopyTo($bytes, $metadataRegionOffset + $fileParametersOffset + 4)

            [System.IO.File]::WriteAllBytes($Path, $bytes)
        }

        function Test-TestVhdx {
            param([string] $Path)
            InModuleScope WslDiskSpace -Parameters @{ Path = $Path } {
                param($Path)
                Test-VhdxFixedSize -Path $Path
            }
        }
    }

    It 'recognizes a disk of fixed size' {
        $path = Join-Path $TestDrive 'fixed.vhdx'
        New-TestVhdx -Path $path -FileParameterFlags 1

        Test-TestVhdx -Path $path | Should -BeTrue
    }

    It 'recognizes a dynamically expanding disk as not fixed' {
        $path = Join-Path $TestDrive 'dynamic.vhdx'
        New-TestVhdx -Path $path -FileParameterFlags 0

        Test-TestVhdx -Path $path | Should -BeFalse
    }

    It 'recognizes a differencing disk as not fixed' {
        $path = Join-Path $TestDrive 'differencing.vhdx'
        New-TestVhdx -Path $path -FileParameterFlags 2

        Test-TestVhdx -Path $path | Should -BeFalse
    }

    It 'treats a file that is no VHDX as not fixed' {
        $path = Join-Path $TestDrive 'other.vhdx'
        [System.IO.File]::WriteAllBytes($path, [byte[]]::new(300KB))

        Test-TestVhdx -Path $path | Should -BeFalse
    }

    It 'treats a missing file as not fixed' {
        Test-TestVhdx -Path (Join-Path $TestDrive 'missing.vhdx') | Should -BeFalse
    }
}

Describe 'Optimize-VirtualDisk' {
    BeforeAll {
        Mock -ModuleName WslDiskSpace -CommandName Get-NativeCommandResult -MockWith { throw "Unexpected native command: $FilePath" }
        Mock -ModuleName WslDiskSpace -CommandName Invoke-NativeCommand -MockWith { throw "Unexpected native command: $FilePath" }
    }

    BeforeEach {
        Mock -ModuleName WslDiskSpace -CommandName Get-Item -MockWith {
            [pscustomobject]@{ Length = 10GB; Attributes = [System.IO.FileAttributes]::Archive }
        }
        Mock -ModuleName WslDiskSpace -CommandName Dismount-VirtualDisk -MockWith { }
        Mock -ModuleName WslDiskSpace -CommandName Test-VhdxFixedSize -MockWith { $false }
        Mock -ModuleName WslDiskSpace -CommandName Invoke-DiskpartCompaction -MockWith { $true }
        Mock -ModuleName WslDiskSpace -CommandName Write-Host -MockWith { }
        Mock -ModuleName WslDiskSpace -CommandName Write-Warning -MockWith { }
        $script:virtualDisk = [pscustomobject]@{ Name = 'Ubuntu'; Path = 'C:\Fake\Ubuntu\ext4.vhdx' }
    }

    It 'compacts a disk that is not in use' {
        Mock -ModuleName WslDiskSpace -CommandName Wait-FileUnlocked -MockWith { $true }

        $result = InModuleScope WslDiskSpace -Parameters @{ VirtualDisk = $script:virtualDisk } {
            param($VirtualDisk)
            Optimize-VirtualDisk -VirtualDisk $VirtualDisk
        }

        $result.Status | Should -BeExactly 'Compacted'
        $result.IsFailure | Should -BeFalse
    }

    It 'shuts WSL down once more when a WSL client started the distribution again, then compacts' {
        # Regression: VS Code started the distribution right after the shutdown, and its disk was skipped as in use.
        $script:unlockAttempts = 0
        Mock -ModuleName WslDiskSpace -CommandName Wait-FileUnlocked -MockWith {
            $script:unlockAttempts++
            $script:unlockAttempts -gt 1
        }
        Mock -ModuleName WslDiskSpace -CommandName Get-NativeCommandResult -ParameterFilter { $ArgumentList -contains '--shutdown' } -MockWith {
            [pscustomobject]@{ ExitCode = 0; Output = ''; ErrorOutput = ''; TimedOut = $false }
        }

        $result = InModuleScope WslDiskSpace -Parameters @{ VirtualDisk = $script:virtualDisk } {
            param($VirtualDisk)
            Optimize-VirtualDisk -VirtualDisk $VirtualDisk
        }

        $result.Status | Should -BeExactly 'Compacted'
        Should -Invoke -ModuleName WslDiskSpace -CommandName Get-NativeCommandResult -Times 1 -Exactly -ParameterFilter {
            $FilePath -eq 'C:\WslDiskSpaceTests\wsl.exe' -and $ArgumentList -contains '--shutdown'
        }
    }

    It 'reports a disk that stays in use as a failure' {
        Mock -ModuleName WslDiskSpace -CommandName Wait-FileUnlocked -MockWith { $false }
        Mock -ModuleName WslDiskSpace -CommandName Get-NativeCommandResult -ParameterFilter { $ArgumentList -contains '--shutdown' } -MockWith {
            [pscustomobject]@{ ExitCode = 0; Output = ''; ErrorOutput = ''; TimedOut = $false }
        }

        $result = InModuleScope WslDiskSpace -Parameters @{ VirtualDisk = $script:virtualDisk } {
            param($VirtualDisk)
            Optimize-VirtualDisk -VirtualDisk $VirtualDisk
        }

        $result.Status | Should -BeExactly 'Skipped (in use)'
        $result.IsFailure | Should -BeTrue
        Should -Invoke -ModuleName WslDiskSpace -CommandName Invoke-DiskpartCompaction -Times 0 -Exactly
    }

    It 'skips a disk of fixed size without counting it as a failure' {
        # Regression: diskpart cannot compact fixed disks, so every run ended with an error.
        Mock -ModuleName WslDiskSpace -CommandName Wait-FileUnlocked -MockWith { $true }
        Mock -ModuleName WslDiskSpace -CommandName Test-VhdxFixedSize -MockWith { $true }

        $result = InModuleScope WslDiskSpace -Parameters @{ VirtualDisk = $script:virtualDisk } {
            param($VirtualDisk)
            Optimize-VirtualDisk -VirtualDisk $VirtualDisk
        }

        $result.Status | Should -BeExactly 'Skipped (fixed size)'
        $result.IsFailure | Should -BeFalse
        Should -Invoke -ModuleName WslDiskSpace -CommandName Invoke-DiskpartCompaction -Times 0 -Exactly
    }
}

Describe 'diskpart' {
    BeforeAll {
        Mock -ModuleName WslDiskSpace -CommandName Get-NativeCommandResult -MockWith { throw "Unexpected native command: $FilePath" }
        Mock -ModuleName WslDiskSpace -CommandName Invoke-NativeCommand -MockWith { throw "Unexpected native command: $FilePath" }
    }

    It 'detaches the disk when the compaction is interrupted' {
        # Regression: an interrupted diskpart left the disk attached, and the distribution did not start.
        Mock -ModuleName WslDiskSpace -CommandName Invoke-DiskpartScript -MockWith { throw 'interrupted' }
        Mock -ModuleName WslDiskSpace -CommandName Dismount-VirtualDisk -MockWith { }
        Mock -ModuleName WslDiskSpace -CommandName Write-Warning -MockWith { }

        { InModuleScope WslDiskSpace { Invoke-DiskpartCompaction -VirtualDiskPath 'C:\Fake\Ubuntu\ext4.vhdx' } } | Should -Throw '*interrupted*'
        Should -Invoke -ModuleName WslDiskSpace -CommandName Dismount-VirtualDisk -Times 1 -Exactly
    }

    It 'runs diskpart from the system directory and decodes its output with the OEM code page' {
        # Regression: after 'chcp 65001' the console code page garbled diskpart's messages.
        Mock -ModuleName WslDiskSpace -CommandName Get-OemEncoding -MockWith { [System.Text.Encoding]::GetEncoding(850) }
        Mock -ModuleName WslDiskSpace -CommandName Invoke-NativeCommand -MockWith { 0 }

        InModuleScope WslDiskSpace { Invoke-DiskpartScript -ScriptLines @('rem test') } | Should -Be 0
        Should -Invoke -ModuleName WslDiskSpace -CommandName Invoke-NativeCommand -Times 1 -Exactly -ParameterFilter {
            $FilePath -eq 'C:\WslDiskSpaceTests\diskpart.exe' -and $StandardOutputEncoding.CodePage -eq 850
        }
    }

    It 'runs the quiet diskpart script from the system directory too' {
        Mock -ModuleName WslDiskSpace -CommandName Get-NativeCommandResult -MockWith {
            [pscustomobject]@{ ExitCode = 0; Output = ''; ErrorOutput = ''; TimedOut = $false }
        }

        InModuleScope WslDiskSpace { Invoke-DiskpartScript -ScriptLines @('rem test') -Quiet } | Should -Be 0
        Should -Invoke -ModuleName WslDiskSpace -CommandName Get-NativeCommandResult -Times 1 -Exactly -ParameterFilter {
            $FilePath -eq 'C:\WslDiskSpaceTests\diskpart.exe'
        }
    }

    It 'reads the OEM code page of the system, not the one of the console' {
        $oemCodePage = if ([Console]::OutputEncoding.CodePage -eq 437) { 850 } else { 437 }
        Mock -ModuleName WslDiskSpace -CommandName Get-ItemPropertyValue -ParameterFilter { $Name -eq 'OEMCP' } -MockWith { "$oemCodePage" }

        (InModuleScope WslDiskSpace { Get-OemEncoding }).CodePage | Should -Be $oemCodePage
    }
}

Describe 'Stop-DockerDesktop' {
    BeforeEach {
        Mock -ModuleName WslDiskSpace -CommandName Get-Process -MockWith { [pscustomobject]@{ Name = 'Docker Desktop'; SessionId = 1 } }
        Mock -ModuleName WslDiskSpace -CommandName Get-Command -ParameterFilter { $Name -eq 'docker.exe' } -MockWith {
            [pscustomobject]@{ Name = 'docker.exe'; Source = 'C:\WslDiskSpaceTests\docker.exe' }
        }
        Mock -ModuleName WslDiskSpace -CommandName Stop-Process -MockWith { }
        Mock -ModuleName WslDiskSpace -CommandName Write-Host -MockWith { }
        Mock -ModuleName WslDiskSpace -CommandName Write-Warning -MockWith { }
    }

    It 'gives up waiting for docker desktop stop after a while and stops Docker Desktop forcibly' {
        # Regression: 'docker desktop stop' has no time limit, so a hanging Docker Desktop hung the run.
        Mock -ModuleName WslDiskSpace -CommandName Get-NativeCommandResult -MockWith {
            [pscustomobject]@{ ExitCode = $null; Output = ''; ErrorOutput = ''; TimedOut = $true }
        }

        InModuleScope WslDiskSpace { Stop-DockerDesktop }

        Should -Invoke -ModuleName WslDiskSpace -CommandName Get-NativeCommandResult -Times 1 -Exactly -ParameterFilter {
            $FilePath -eq 'C:\WslDiskSpaceTests\docker.exe' -and ($ArgumentList -join ' ') -eq 'desktop stop' -and $TimeoutSeconds -gt 0
        }
        Should -Invoke -ModuleName WslDiskSpace -CommandName Write-Warning -Times 1 -Exactly
        Should -Invoke -ModuleName WslDiskSpace -CommandName Stop-Process
    }
}

Describe 'Wait-DockerDesktopTrim' {
    BeforeEach {
        Mock -ModuleName WslDiskSpace -CommandName Start-Sleep -MockWith { }
        Mock -ModuleName WslDiskSpace -CommandName Write-Host -MockWith { }
    }

    It 'waits until Docker Desktop had time to trim its data disk after a prune' {
        # Regression: Docker Desktop was stopped before its own fstrim ran, so the compaction reclaimed less.
        InModuleScope WslDiskSpace {
            $script:dockerDesktopPruneTimer = [System.Diagnostics.Stopwatch]::StartNew()
            Wait-DockerDesktopTrim
        }

        Should -Invoke -ModuleName WslDiskSpace -CommandName Start-Sleep -Times 1 -Exactly -ParameterFilter {
            $Milliseconds -gt 10000 -and $Milliseconds -le 15000
        }
    }

    It 'does not wait when Docker Desktop was not pruned' {
        InModuleScope WslDiskSpace {
            $script:dockerDesktopPruneTimer = $null
            Wait-DockerDesktopTrim
        }

        Should -Invoke -ModuleName WslDiskSpace -CommandName Start-Sleep -Times 0 -Exactly
    }
}

Describe 'Invoke-CompactionPhase' {
    BeforeAll {
        Mock -ModuleName WslDiskSpace -CommandName Get-NativeCommandResult -MockWith { throw "Unexpected native command: $FilePath" }
        Mock -ModuleName WslDiskSpace -CommandName Start-Process -MockWith { throw 'Unexpected Start-Process' }
    }

    BeforeEach {
        Mock -ModuleName WslDiskSpace -CommandName Wait-DockerDesktopTrim -MockWith { }
        Mock -ModuleName WslDiskSpace -CommandName Stop-DockerDesktop -MockWith { }
        Mock -ModuleName WslDiskSpace -CommandName Invoke-NativeCommand -MockWith { 0 }
        Mock -ModuleName WslDiskSpace -CommandName Test-IsAdministrator -MockWith { $true }
        Mock -ModuleName WslDiskSpace -CommandName Optimize-VirtualDisk -MockWith {
            [pscustomobject]@{ Distribution = 'Ubuntu'; Status = 'Compacted'; IsFailure = $false; SizeBeforeBytes = 2GB; SizeAfterBytes = 1GB; FreedBytes = 1GB }
        }
        Mock -ModuleName WslDiskSpace -CommandName Write-CompactionSummary -MockWith { }
        Mock -ModuleName WslDiskSpace -CommandName Write-Host -MockWith { }
        $script:virtualDisks = @([pscustomobject]@{ Name = 'Ubuntu'; Path = 'C:\Fake\Ubuntu\ext4.vhdx' })
    }

    It 'shuts WSL down and decodes its messages as UTF-8' {
        # Regression: with WSL_UTF8=1 wsl.exe writes UTF-8, but its messages were decoded with the console code page.
        InModuleScope WslDiskSpace -Parameters @{ VirtualDisks = $script:virtualDisks } {
            param($VirtualDisks)
            Invoke-CompactionPhase -VirtualDisks $VirtualDisks
        }

        Should -Invoke -ModuleName WslDiskSpace -CommandName Invoke-NativeCommand -Times 1 -Exactly -ParameterFilter {
            $FilePath -eq 'C:\WslDiskSpaceTests\wsl.exe' -and ($ArgumentList -join ' ') -eq '--shutdown' -and $StandardOutputEncoding.WebName -eq 'utf-8'
        }
    }

    It 'gives Docker Desktop time to trim its data disk before it is stopped' {
        $script:calls = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName WslDiskSpace -CommandName Wait-DockerDesktopTrim -MockWith { $script:calls.Add('trim') }
        Mock -ModuleName WslDiskSpace -CommandName Stop-DockerDesktop -MockWith { $script:calls.Add('stop') }

        InModuleScope WslDiskSpace -Parameters @{ VirtualDisks = $script:virtualDisks } {
            param($VirtualDisks)
            Invoke-CompactionPhase -VirtualDisks $VirtualDisks
        }

        @($script:calls) | Should -Be @('trim', 'stop')
    }
}

Describe 'shell commands' -Tag 'WSL' {
    BeforeAll {
        function Invoke-TestShell {
            param([string] $Command)

            $arguments = foreach ($argument in @('--distribution', $env:WSLDISKSPACE_TEST_DISTRIBUTION, '--user', 'root', '--exec', 'sh', '-c', $Command)) {
                InModuleScope WslDiskSpace -Parameters @{ Argument = $argument } {
                    param($Argument)
                    ConvertTo-CommandLineArgument -Argument $Argument
                }
            }
            $startInfo = [System.Diagnostics.ProcessStartInfo]::new((Join-Path $env:SystemRoot 'System32\wsl.exe'), ($arguments -join ' '))
            $startInfo.UseShellExecute = $false
            $startInfo.CreateNoWindow = $true
            $startInfo.RedirectStandardInput = $true
            $startInfo.RedirectStandardOutput = $true
            $startInfo.StandardOutputEncoding = [System.Text.UTF8Encoding]::new($false)
            $process = [System.Diagnostics.Process]::Start($startInfo)
            try {
                $process.StandardInput.Close()
                $output = $process.StandardOutput.ReadToEnd()
                $process.WaitForExit()
                [pscustomobject]@{ ExitCode = $process.ExitCode; Lines = @($output -split "`r?`n" | Where-Object { $_ }) }
            }
            finally {
                $process.Dispose()
            }
        }
    }

    It 'runs both apt-get commands and reports a failure of apt-get <Failing>' -Skip:(-not $env:WSLDISKSPACE_TEST_DISTRIBUTION) -ForEach @(
        @{ Failing = 'clean' }
        @{ Failing = 'autoremove' }
    ) {
        # Regression: apt-get clean failed at once on a held lock, and '&&' then skipped autoremove.
        $packageCleanupCommand = InModuleScope WslDiskSpace { $packageCleanupCommand }
        $fakeAptGet = 'printf ''%s\n'' ''#!/bin/sh'' ''echo "$*" >> "${0%/*}/calls"'' ''case " $* " in *" ' + $Failing +
            ' "*) exit 100;; esac'' ''exit 0'''
        # PATH holds only the fake: one that cannot be executed would otherwise fall through to the real apt-get.
        $command = 'directory=$(mktemp -d) && trap ''rm -rf "$directory"'' EXIT && ' +
            "$fakeAptGet > `"`$directory/apt-get`" && chmod +x `"`$directory/apt-get`" && " +
            "(PATH=`"`$directory`"; $packageCleanupCommand); status=`$?; " +
            'cat "$directory/calls"; exit $status'

        $result = Invoke-TestShell -Command $command

        $result.Lines | Should -Be @('-o DPkg::Lock::Timeout=120 autoremove --yes', 'clean')
        $result.ExitCode | Should -Be 100
    }

    It 'reads the API version and the identity of the Docker engine' -Skip:(-not $env:WSLDISKSPACE_TEST_DISTRIBUTION) {
        if ((Invoke-TestShell -Command 'unset DOCKER_HOST DOCKER_CONTEXT; docker --context default info >/dev/null 2>&1').ExitCode -ne 0) {
            Set-ItResult -Skipped -Because 'no Docker daemon is reachable in the test distribution'
            return
        }
        $dockerEngineQuery = InModuleScope WslDiskSpace { $dockerEngineQuery }

        $result = Invoke-TestShell -Command $dockerEngineQuery

        $result.ExitCode | Should -Be 0
        $result.Lines[0] | Should -Match '^\d+\.\d+$'
        $result.Lines[1] | Should -Match '^[^|]+\|.+$'
    }

    It 'reads the API version the client actually uses' -Skip:(-not $env:WSLDISKSPACE_TEST_DISTRIBUTION) {
        if ((Invoke-TestShell -Command 'unset DOCKER_HOST DOCKER_CONTEXT; docker --context default info >/dev/null 2>&1').ExitCode -ne 0) {
            Set-ItResult -Skipped -Because 'no Docker daemon is reachable in the test distribution'
            return
        }
        $dockerEngineQuery = InModuleScope WslDiskSpace { $dockerEngineQuery }

        # With an older client or daemon the negotiated version is lower; DOCKER_API_VERSION simulates that.
        $result = Invoke-TestShell -Command "export DOCKER_API_VERSION=1.41; $dockerEngineQuery"

        $result.ExitCode | Should -Be 0
        $result.Lines[0] | Should -BeExactly '1.41'
    }
}
