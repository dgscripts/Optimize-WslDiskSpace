# Optimize-WslDiskSpace

Give the disk space that WSL 2 and Docker Desktop no longer need back to Windows.

WSL 2 keeps every Linux distribution in a virtual disk (`ext4.vhdx`) that grows while you work but, by default, never shrinks: deleting files inside Linux frees space for Linux, not for Windows. Docker Desktop keeps its images, containers and volumes in a virtual disk of its own. `Optimize-WslDiskSpace` deletes package caches, unneeded packages and unused Docker data inside your distributions, shuts WSL down, compacts the virtual disks and shows how much space Windows got back:

```text
=== Summary ===

Distribution        Status      Before    After    Freed
------------        ------      ------    -----    -----
Ubuntu-24.04        Compacted 41.03 GB 22.98 GB 18.05 GB
docker-desktop      Compacted  0.24 GB  0.17 GB  0.07 GB
docker-desktop-data Compacted 68.51 GB 31.22 GB 37.29 GB


Total reclaimed: 55.41 GB
```

## What it does

1. **Cleans up inside each distribution**, as root (through `wsl --user root`, so without a password prompt):
   - `apt-get clean` and `apt-get autoremove`, where `apt-get` is available,
   - `docker system prune --all --volumes`, where `docker` reaches a running daemon. It always uses the local daemon and ignores `DOCKER_HOST` and Docker contexts, so a remote Docker host is never pruned. With Docker Desktop's WSL integration, the local daemon is Docker Desktop's engine, so Docker Desktop's data is pruned too if Docker Desktop is running.
2. **Trims the file system** with `fstrim /`, so the blocks freed in step 1 are handed back to the virtual disk.
3. **Stops Docker Desktop and shuts WSL down** (`wsl --shutdown`), which releases the virtual disks.
4. **Compacts the virtual disks** of all distributions, including Docker Desktop's data disk, with `diskpart` and prints the summary shown above. This is usually the slowest step; diskpart shows its progress in percent.

Docker Desktop's own distributions are left alone in steps 1 and 2; their disks are only compacted. Sparse, compressed or encrypted disks are not compacted, because `diskpart` cannot compact them; the summary lists them as `Skipped (unsupported)`.

Because the compaction uses `diskpart`, it doesn't need the Hyper-V module that `Optimize-VHD` requires, so it also works on Windows Home. Unlike `wsl --manage <name> --compact` in recent WSL versions, it also compacts Docker Desktop's data disk, which is not a registered distribution.

## Requirements

- Windows 10 or 11 with WSL 2
- Windows PowerShell 5.1 or PowerShell 7
- Administrator rights for the compaction; the command asks for them itself (UAC)
- Optional: Docker Desktop with the WSL 2 backend

## Installation

```powershell
git clone https://github.com/dgscripts/Optimize-WslDiskSpace.git
cd Optimize-WslDiskSpace
powershell -ExecutionPolicy Bypass -File .\Install.ps1
```

The installer copies the module into your user module folder of Windows PowerShell (`Documents\WindowsPowerShell\Modules\WslDiskSpace`) and, if installed, PowerShell 7 (`Documents\PowerShell\Modules\WslDiskSpace`). Every new PowerShell session then has `Optimize-WslDiskSpace`, with tab completion for your distribution names. If the execution policy would block the module, the installer offers to set it to `RemoteSigned` for the current user. Run it from a terminal as shown: *Run with PowerShell* in Explorer's context menu can be blocked by the execution policy and closes the window before you can read the result.

To update, run `git pull` and the installer again. To remove the module:

```powershell
powershell -ExecutionPolicy Bypass -File .\Install.ps1 -Uninstall
```

This leaves the execution policy as it is. `Set-ExecutionPolicy -Scope CurrentUser Undefined` removes the setting again; Windows PowerShell and PowerShell 7 keep it separately.

## Before you run it

- **There is no dry run.** The only prompt comes before Docker data is pruned: it lists the distributions concerned, and if you decline, nothing is changed. If no Docker daemon is reachable, for example because Docker Desktop is not running, there is no prompt at all.
- **`docker system prune --all --volumes` deletes Docker data:** all stopped containers, then every image, network and anonymous volume that no running container uses, and the build cache. Named volumes are kept, except with Docker Engine versions older than 23.0 (for example the `docker.io` package of Debian 12), which delete unused named volumes as well. Pruned images are downloaded or built again when you next need them. Use `-SkipDockerPrune` to keep all Docker data.
- **WSL shuts down completely**, even with `-DistributionName`: every running distribution, open shell, VS Code remote session and container stops. Close VS Code windows and terminal tabs connected to WSL first, because they start their distribution again right away, and its disk can then not be compacted. Run the command in PowerShell on Windows, not in a WSL shell.
- **Docker Desktop is stopped and not restarted.** Start it again when you need it.
- **`apt-get autoremove` does not ask** before it removes packages that were installed as dependencies and are no longer needed. Use `-SkipPackageCleanup` to avoid it.

## Usage

Run it in PowerShell on Windows. A normal, non-elevated window is enough:

```powershell
Optimize-WslDiskSpace
```

```powershell
# Only Ubuntu and Docker Desktop's data disk, without the confirmation prompt
Optimize-WslDiskSpace -DistributionName Ubuntu, docker-desktop-data -Force

# Clean up inside the distributions, but keep WSL running
Optimize-WslDiskSpace -SkipCompaction

# Keep packages and Docker data, only trim and compact
Optimize-WslDiskSpace -SkipPackageCleanup -SkipDockerPrune
```

| Parameter | Effect |
| --- | --- |
| `-DistributionName` | Limits cleanup and compaction to these distributions. Tab completion lists the installed ones; Docker Desktop's data disk is called `docker-desktop-data`. |
| `-SkipPackageCleanup` | Skips `apt-get clean` and `apt-get autoremove`. |
| `-SkipDockerPrune` | Skips `docker system prune`. |
| `-SkipCompaction` | Only cleans up inside the distributions: no `fstrim`, no WSL shutdown, no compaction. |
| `-Force` | Skips the confirmation prompt before `docker system prune`. |

`Get-Help Optimize-WslDiskSpace -Full` shows the complete help.

### Administrator rights

The cleanup needs no administrator rights. The compaction does, and the command asks for them itself. The UAC prompt appears after the cleanup, when WSL and Docker Desktop have already been stopped, so stay at the computer; if you decline it, nothing is compacted.

- If Windows `sudo` is enabled in inline mode (Windows 11 24H2 and later: Settings > System > Advanced, or `sudo config --enable normal` in an elevated terminal), the compaction runs in the same window.
- Otherwise it runs in a separate window, which closes when it is done and stays open if a disk failed.
- In an elevated terminal, there is no UAC prompt.

The summary is always shown in the window where you started the command.

### Scheduled task

When a scheduled task runs, nobody is there to answer a UAC prompt or the confirmation prompt, so the task needs "Run with highest privileges" (your account must be an administrator) and `-Force`. If any step fails, the command ends with exit code 1, which Task Scheduler shows as the last run result. Pick a time when you don't use WSL: the run shuts it down and stops Docker Desktop.

In an elevated PowerShell:

```powershell
$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-NoProfile -Command Optimize-WslDiskSpace -Force'
$trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Friday -At 12:30
$trigger.StartBoundary = ([datetime]$trigger.StartBoundary).ToString('s')
$principal = New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
Register-ScheduledTask -TaskName 'Optimize-WslDiskSpace' -Action $action -Trigger $trigger -Principal $principal -Settings $settings
```

The task runs only while you are logged on. `New-ScheduledTaskTrigger` stores the start time in UTC; without the `StartBoundary` line, the task would run an hour earlier or later during half of the year. The settings keep Task Scheduler from skipping the run on battery power, or stopping it in the middle of a compaction when you unplug a laptop.

## Troubleshooting

- **A distribution or Docker Desktop does not start after an interrupted run:** its disk is probably still attached. Run `Optimize-WslDiskSpace -DistributionName <name> -SkipPackageCleanup -SkipDockerPrune`; Docker Desktop's data disk is `docker-desktop-data`. The command detaches the disk before compacting it. For a distribution, this run warns that it could not be started and ends with an error; both are expected here.
- **"The virtual disk is still in use":** something opened the `.vhdx` file again after the shutdown. Most often, a WSL client started the distribution again: VS Code connected to WSL, a terminal tab, or Explorer on `\\wsl.localhost`. Backup tools, antivirus scans and a restarted Docker Desktop can do the same. Close them and run the command again.
- **"Path contains non-ASCII characters and has no 8.3 short name":** `diskpart` cannot handle paths with characters such as umlauts, so the command falls back to the 8.3 short path, which this volume does not provide. Move the disk to a path with ASCII characters only: a distribution with `wsl --manage <name> --move <path>`, Docker Desktop's disks with its "Disk image location" setting.
- **"The 'Optimize-WslDiskSpace' command was found in the module 'WslDiskSpace', but the module could not be loaded":** usually the execution policy blocks the module; `Import-Module WslDiskSpace` shows the reason. Run the installer again and accept the offer to set `RemoteSigned`, or run `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned` in the PowerShell edition that is affected.

## License

[MIT](LICENSE)
