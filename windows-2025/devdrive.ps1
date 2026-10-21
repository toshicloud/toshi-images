# Prepares the Dev Drive (ReFS "work" volume on D:) for GitHub Actions runner data.
# The control plane mints Windows runners with the JIT work folder D:\_work, so jobs work
# on the Dev Drive directly. No junction from C:\actions-runner\_work: Git resolves one, and
# actions/checkout v6+ then never matches its includeIf.gitdir credentials on private repos.

param([switch]$Wait)

$StatusPath = 'C:\ProgramData\toshi\devdrive.status'
$ToshiProgramData = 'C:\ProgramData\toshi'
$WorkLabel = 'work'
$WorkLetter = 'D'
$WorkRoot = 'D:\_work'

function Write-SerialLog {
    param([Parameter(Mandatory = $true)][string]$Line)
    $port = $null
    try {
        $port = New-Object System.IO.Ports.SerialPort('COM1', 115200)
        $port.Open()
        $port.WriteLine($Line)
    } finally {
        if ($null -ne $port) {
            if ($port.IsOpen) { $port.Close() }
            $port.Dispose()
        }
    }
}

function Write-DevDriveLog {
    param([Parameter(Mandatory = $true)][string]$Line)
    try {
        Write-SerialLog "TOSHI-DEVDRIVE: $Line"
    } catch {
        # VM without COM1 must not fail.
    }
}

function Write-StatusLine {
    param([Parameter(Mandatory = $true)][string]$Line)
    Set-Content -LiteralPath $StatusPath -Value $Line -Encoding Ascii -Force
}

function Get-WorkVolume {
    return Get-Volume -ErrorAction SilentlyContinue | Where-Object {
        $_.FileSystemLabel -eq $WorkLabel
    } | Select-Object -First 1
}

function Get-LowestRawDataDisk {
    return Get-Disk -ErrorAction SilentlyContinue | Where-Object {
        -not $_.IsBoot -and -not $_.IsSystem -and $_.PartitionStyle -eq 'RAW'
    } | Sort-Object Number | Select-Object -First 1
}

function Set-DataDisksOnline {
    $disks = Get-Disk -ErrorAction SilentlyContinue | Where-Object {
        -not $_.IsBoot -and -not $_.IsSystem
    }
    foreach ($disk in $disks) {
        if ($disk.IsOffline) {
            Set-Disk -Number $disk.Number -IsOffline $false -ErrorAction Stop
        }
        if ($disk.IsReadOnly) {
            Set-Disk -Number $disk.Number -IsReadOnly $false -ErrorAction Stop
        }
    }
}

function Ensure-WorkVolumeDriveLetter {
    param([Parameter(Mandatory = $true)]$Volume)
    if ($Volume.DriveLetter -eq $WorkLetter) {
        return
    }
    if ($Volume.DriveLetter) {
        Set-Partition -DriveLetter $Volume.DriveLetter -NewDriveLetter $WorkLetter -ErrorAction Stop
        return
    }
    $partition = Get-Partition -ErrorAction SilentlyContinue | Where-Object {
        $_.AccessPaths -contains $Volume.UniqueId
    } | Select-Object -First 1
    if ($null -eq $partition) {
        throw "cannot find the partition for the work volume to assign letter $WorkLetter"
    }
    Set-Partition -DiskNumber $partition.DiskNumber -PartitionNumber $partition.PartitionNumber -NewDriveLetter $WorkLetter -ErrorAction Stop
}

function Test-DriveLetterInUse {
    param([Parameter(Mandatory = $true)][string]$Letter)
    $vol = Get-Volume -ErrorAction SilentlyContinue | Where-Object {
        $_.DriveLetter -eq $Letter
    } | Select-Object -First 1
    return ($null -ne $vol)
}

function Initialize-WorkDevDrive {
    param(
        [Parameter(Mandatory = $true)][int]$DiskNumber,
        [ref]$FormatMilliseconds
    )
    if (Test-DriveLetterInUse -Letter $WorkLetter) {
        throw "Drive letter $WorkLetter is already in use; cannot format Dev Drive on disk $DiskNumber"
    }
    $formatWatch = [System.Diagnostics.Stopwatch]::StartNew()
    Initialize-Disk -Number $DiskNumber -PartitionStyle GPT -ErrorAction Stop
    New-Partition -DiskNumber $DiskNumber -UseMaximumSize -DriveLetter $WorkLetter -ErrorAction Stop
    Format-Volume -DriveLetter $WorkLetter -DevDrive -FileSystem ReFS -NewFileSystemLabel $WorkLabel `
        -Confirm:$false -Force -ErrorAction Stop | Out-Null
    $formatWatch.Stop()
    $FormatMilliseconds.Value = $formatWatch.ElapsedMilliseconds
}

function Initialize-RunnerWorkFolder {
    New-Item -ItemType Directory -Path $WorkRoot -Force -ErrorAction Stop | Out-Null
    & icacls.exe $WorkRoot /grant "runner:(OI)(CI)M"
    if ($LASTEXITCODE -ne 0) {
        throw "icacls failed for $WorkRoot (exit $LASTEXITCODE)"
    }
}

function Write-DevDriveDiagnostics {
    param(
        [Parameter(Mandatory = $true)][string]$State,
        [AllowNull()][Nullable[int64]]$FormatMs,
        [Parameter(Mandatory = $true)][int64]$TotalMs
    )
    Write-DevDriveLog "state $State"
    if ($null -ne $FormatMs) {
        Write-DevDriveLog "format-ms $FormatMs"
    }
    Write-DevDriveLog "total-ms $TotalMs"
    try {
        $volText = Get-Volume -DriveLetter $WorkLetter -ErrorAction Stop |
            Format-List DriveLetter, FileSystemLabel, FileSystem, FileSystemType, Size, HealthStatus |
            Out-String -Width 4096
        foreach ($line in ($volText -split "`r?`n")) {
            if ($line.Trim().Length -gt 0) {
                Write-DevDriveLog $line.Trim()
            }
        }
    } catch {
        Write-DevDriveLog "volume-D-unavailable"
    }
    try {
        $fsutilOut = & fsutil.exe devdrv query "${WorkLetter}:" 2>&1
        foreach ($line in ($fsutilOut | Out-String -Width 4096) -split "`r?`n") {
            if ($line.Trim().Length -gt 0) {
                Write-DevDriveLog $line.Trim()
            }
        }
    } catch {
        Write-DevDriveLog "fsutil-devdrv-unavailable"
    }
    try {
        $slmgrOut = & cscript.exe //nologo "$env:SystemRoot\System32\slmgr.vbs" /xpr 2>&1
        foreach ($line in ($slmgrOut | Out-String -Width 4096) -split "`r?`n") {
            if ($line.Trim().Length -gt 0) {
                Write-DevDriveLog $line.Trim()
            }
        }
    } catch {
        Write-DevDriveLog "slmgr-unavailable"
    }
}

function Write-FailedStatus {
    param([Parameter(Mandatory = $true)][string]$Message)
    $oneLine = ($Message -replace "[\r\n]+", ' ').Trim()
    if ($oneLine.Length -eq 0) {
        $oneLine = 'unknown error'
    }
    try {
        New-Item -ItemType Directory -Path $ToshiProgramData -Force -ErrorAction Stop | Out-Null
        Write-StatusLine -Line "failed: $oneLine"
    } catch {
        # Best effort; caller still exits 0.
    }
}

if ($Wait) {
    # Windows PowerShell 5.1 runs on .NET Framework, which has no TickCount64.
    $boot = (Get-CimInstance -ClassName Win32_OperatingSystem).LastBootUpTime
    $deadline = (Get-Date).AddSeconds(120)
    while ((Get-Date) -lt $deadline) {
        if (Test-Path -LiteralPath $StatusPath) {
            $statusItem = Get-Item -LiteralPath $StatusPath -Force
            if ($statusItem.LastWriteTime -gt $boot) {
                break
            }
        }
        Start-Sleep -Milliseconds 250
    }
    exit 0
}

$state = $null
$formatMs = $null
$totalWatch = $null

try {
    New-Item -ItemType Directory -Path $ToshiProgramData -Force -ErrorAction Stop | Out-Null
    $totalWatch = [System.Diagnostics.Stopwatch]::StartNew()

    Set-DataDisksOnline

    $workVol = Get-WorkVolume
    if ($null -ne $workVol) {
        Ensure-WorkVolumeDriveLetter -Volume $workVol
        $state = 'existing'
    } else {
        $rawDisk = Get-LowestRawDataDisk
        if ($null -ne $rawDisk) {
            $formatMsTemp = 0
            Initialize-WorkDevDrive -DiskNumber $rawDisk.Number -FormatMilliseconds ([ref]$formatMsTemp)
            $formatMs = $formatMsTemp
            $state = 'ready'
        } else {
            $state = 'none'
        }
    }

    if ($state -eq 'ready' -or $state -eq 'existing') {
        New-Item -ItemType Directory -Path 'D:\Dev' -Force | Out-Null
        Initialize-RunnerWorkFolder
    }

    $totalWatch.Stop()
    Write-StatusLine -Line $state
    Write-DevDriveDiagnostics -State $state -FormatMs $formatMs -TotalMs $totalWatch.ElapsedMilliseconds
} catch {
    if ($null -ne $totalWatch -and $totalWatch.IsRunning) {
        $totalWatch.Stop()
    }
    Write-FailedStatus -Message $_.Exception.Message
}

exit 0
