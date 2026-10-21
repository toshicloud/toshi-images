#Requires -Version 5.1
# Runs on the temporary EC2 instance that windows-2025.pkr.hcl starts. A thin
# wrapper: it gives the local image's scripts (windows-2025: tools.ps1,
# runner-images.ps1, devdrive.ps1, uploaded unchanged to C:\toshi\config) what
# firstlogon.ps1 and the config CD give them in the local build.
#
#   plan      write tools.env and print the downloads; no network, no changes
#             (runs under PowerShell 7 on any system, for a check without AWS)
#   tools     download and verify the pinned installers, create the runner
#             account, apply the settings, run runner-images.ps1 and tools.ps1
#   devdrive  run devdrive.ps1 against a temporary virtual disk
#   settle    Windows Update off, wait until servicing is idle
#   seal      remove the build's files, reset EC2Launch, close WinRM, shut down
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('plan', 'tools', 'devdrive', 'settle', 'seal')]
    [string]$Step,
    [string]$ConfigRoot = $PSScriptRoot
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$ToshiDir = 'C:\toshi'
$BuildLog = "$ToshiDir\image-build.log"
$ToolsetsPath = "$ToshiDir\toolsets.txt"

# The local build writes its progress to the serial port; here it goes to
# Packer's output and, on the instance, to a log that stays in the image.
function Write-SerialLog {
    param([Parameter(Mandatory = $true)][string]$Line)
    Write-Host $Line
    if ($Step -eq 'plan') { return }
    Add-Content -LiteralPath $BuildLog -Value ("{0} {1}" -f (Get-Date).ToUniversalTime().ToString('o'), $Line)
    if ($Line -like 'TOOLSET *') {
        Add-Content -LiteralPath $ToolsetsPath -Value $Line
    }
}

function Invoke-TryStep {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][scriptblock]$Action
    )
    Write-SerialLog "TOSHI-IMAGE-BUILD: $Name"
    try {
        & $Action
    } catch {
        Write-SerialLog "TOSHI-IMAGE-BUILD: WARN $Name $($_.Exception.Message)"
    }
}

# versions.env holds plain KEY=value lines, some quoted.
function Read-KeyValueFile {
    param([Parameter(Mandatory = $true)][string]$Path)
    $map = @{}
    foreach ($line in Get-Content -LiteralPath $Path) {
        if ($line -notmatch '^([A-Z0-9_]+)=(.*)$') { continue }
        $key = $Matches[1]
        $value = $Matches[2].Trim()
        if ($value.Length -ge 2 -and $value[0] -eq $value[$value.Length - 1] -and ($value[0] -eq "'" -or $value[0] -eq '"')) {
            $value = $value.Substring(1, $value.Length - 2)
        }
        $map[$key] = $value
    }
    return $map
}

# One entry per installer of tools.ps1: every <KEY>_CACHE of versions.env,
# with its URL and the checksum SHA256SUMS holds for the file name.
function Get-InstallerPlan {
    $versions = Read-KeyValueFile -Path (Join-Path $ConfigRoot 'versions.env')
    $sums = @{}
    foreach ($line in Get-Content -LiteralPath (Join-Path $ConfigRoot 'SHA256SUMS')) {
        if ($line -match '^([0-9a-f]{64})\s+(\S+)$') { $sums[$Matches[2]] = $Matches[1] }
    }
    $installers = @()
    foreach ($key in ($versions.Keys | Where-Object { $_ -like '*_CACHE' } | Sort-Object)) {
        $tool = $key.Substring(0, $key.Length - '_CACHE'.Length)
        $file = $versions[$key]
        $url = $versions["${tool}_URL"]
        if (-not $url) { throw "versions.env has no ${tool}_URL" }
        if (-not $sums.ContainsKey($file)) { throw "SHA256SUMS has no line for $file" }
        $installers += [pscustomobject]@{ Tool = $tool; File = $file; Url = $url; Sha256 = $sums[$file] }
    }
    return [pscustomobject]@{ Versions = $versions; Installers = $installers }
}

# The tools.env build.sh writes to the config CD: installer file names by
# key, and the versions tools.ps1 needs.
function Write-ToolsEnv {
    param([Parameter(Mandatory = $true)]$Plan)
    $lines = @($Plan.Installers | ForEach-Object { "{0}={1}" -f $_.Tool, $_.File })
    $lines += "RUST_TOOLCHAIN=$($Plan.Versions['RUST_DEFAULT_TOOLCHAIN'])"
    $lines += "RUST_EXTRA_TOOLCHAINS=$($Plan.Versions['RUST_EXTRA_TOOLCHAINS'])"
    $lines += "WIX_VERSION=$($Plan.Versions['WIX_VERSION'])"
    Set-Content -LiteralPath (Join-Path $ConfigRoot 'tools.env') -Value $lines -Encoding Ascii
}

function Get-Installers {
    param([Parameter(Mandatory = $true)]$Plan)
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    foreach ($item in $Plan.Installers) {
        $path = Join-Path $ConfigRoot $item.File
        Write-SerialLog "TOSHI-IMAGE-BUILD: fetch $($item.File)"
        $attempt = 0
        while ($true) {
            $attempt++
            try {
                Invoke-WebRequest -Uri $item.Url -OutFile $path -UseBasicParsing
                break
            } catch {
                if ($attempt -ge 3) { throw "download of $($item.File) failed: $($_.Exception.Message)" }
                Start-Sleep -Seconds (10 * $attempt)
            }
        }
        $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($hash -ne $item.Sha256) {
            throw "checksum mismatch for $($item.File): got $hash, want $($item.Sha256)"
        }
    }
}

# The local image gets its runner account and automatic logon from
# autounattend.xml. No Sysprep runs on this image, so both stay in the AMI.
# The password is random, made here, and never leaves the instance.
function New-RunnerAccount {
    if (Get-LocalUser -Name 'runner' -ErrorAction SilentlyContinue) { return }
    $bytes = New-Object byte[] 24
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    $password = 'Tr1!' + [Convert]::ToBase64String($bytes)
    New-LocalUser -Name 'runner' -Password (ConvertTo-SecureString $password -AsPlainText -Force) `
        -PasswordNeverExpires -AccountNeverExpires -UserMayNotChangePassword | Out-Null
    Add-LocalGroupMember -Group 'Administrators' -Member 'runner'
    $winlogon = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
    Set-ItemProperty -Path $winlogon -Name 'AutoAdminLogon' -Value '1' -Type String
    Set-ItemProperty -Path $winlogon -Name 'DefaultUserName' -Value 'runner' -Type String
    Set-ItemProperty -Path $winlogon -Name 'DefaultDomainName' -Value '.' -Type String
    Set-ItemProperty -Path $winlogon -Name 'DefaultPassword' -Value $password -Type String
    Remove-ItemProperty -Path $winlogon -Name 'AutoLogonCount' -ErrorAction SilentlyContinue
}

# The settings of firstlogon.ps1 that are not about the local hypervisor.
function Set-ImageSettings {
    Invoke-TryStep 'powercfg' {
        foreach ($name in 'monitor-timeout-ac', 'monitor-timeout-dc', 'standby-timeout-ac',
            'standby-timeout-dc', 'hibernate-timeout-ac', 'hibernate-timeout-dc') {
            powercfg.exe /change $name 0
        }
        powercfg.exe /hibernate off
    }
    Invoke-TryStep 'nolockscreen' {
        New-Item -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Personalization' -Force | Out-Null
        Set-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Personalization' `
            -Name 'NoLockScreen' -Value 1 -Type DWord
    }
    Invoke-TryStep 'defender-off' {
        Set-MpPreference -DisableRealtimeMonitoring $true -ErrorAction SilentlyContinue
        New-Item -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Real-Time Protection' -Force | Out-Null
        Set-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Real-Time Protection' `
            -Name 'DisableRealtimeMonitoring' -Value 1 -Type DWord
    }
    Invoke-TryStep 'server-manager-off' {
        New-Item -Path 'HKLM:\SOFTWARE\Microsoft\ServerManager' -Force | Out-Null
        Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\ServerManager' `
            -Name 'DoNotOpenServerManagerAtLogon' -Value 1 -Type DWord
    }
    Invoke-TryStep 'new-network-window-off' {
        New-Item -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Network' -Force | Out-Null
        Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Network' `
            -Name 'NewNetworkWindowOff' -Value 1 -Type DWord
    }
    Invoke-TryStep 'oobe-privacy-off' {
        New-Item -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\OOBE' -Force | Out-Null
        Set-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\OOBE' `
            -Name 'DisablePrivacyExperience' -Value 1 -Type DWord
    }
}

function Invoke-DiskPart {
    param([Parameter(Mandatory = $true)][string[]]$Commands)
    $script = Join-Path $env:TEMP 'toshi-diskpart.txt'
    Set-Content -LiteralPath $script -Value $Commands -Encoding Ascii
    $out = & diskpart.exe /s $script 2>&1
    $code = $LASTEXITCODE
    Remove-Item -LiteralPath $script -Force
    if ($code -ne 0) { throw "diskpart failed (exit $code): $($out | Out-String)" }
}

# A cloud pool formats each instance's own work volume when it prepares the
# instance, so the AMI holds no Dev Drive. This step proves the image can
# make one: devdrive.ps1, unchanged, formats a temporary virtual disk.
function Test-DevDrive {
    $vhd = Join-Path $ToshiDir 'devdrive-proof.vhdx'
    $status = 'C:\ProgramData\toshi\devdrive.status'
    Invoke-DiskPart @("create vdisk file=`"$vhd`" maximum=51200 type=expandable", 'attach vdisk')
    try {
        & (Join-Path $ConfigRoot 'devdrive.ps1')
        $state = if (Test-Path -LiteralPath $status) { (Get-Content -LiteralPath $status -Raw).Trim() } else { 'no status' }
        if ($state -ne 'ready') { throw "devdrive.ps1 did not format a Dev Drive: $state" }
        Write-SerialLog 'TOSHI-IMAGE-BUILD: devdrive ready'
    } finally {
        # Free D: for the pool's work volume and leave no trace of the proof.
        Get-Partition -DriveLetter D -ErrorAction SilentlyContinue |
            Remove-PartitionAccessPath -AccessPath 'D:\' -ErrorAction SilentlyContinue
        Invoke-DiskPart @("select vdisk file=`"$vhd`"", 'detach vdisk')
        Remove-Item -LiteralPath $vhd -Force
        Remove-Item -LiteralPath $status -Force -ErrorAction SilentlyContinue
    }
}

# No updates are installed: the image keeps the patch level of Amazon's base
# image, and a rebuild picks up the next one. Windows Update stays off, as in
# the local image, so it starts nothing when a pool instance boots.
function Wait-ServicingSettled {
    Invoke-TryStep 'windows-update-off' {
        $au = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
        New-Item -Path $au -Force | Out-Null
        Set-ItemProperty -Path $au -Name 'NoAutoUpdate' -Value 1 -Type DWord
        Set-ItemProperty -Path $au -Name 'AUOptions' -Value 1 -Type DWord
        foreach ($service in 'wuauserv', 'UsoSvc', 'DoSvc') {
            Stop-Service -Name $service -Force -ErrorAction SilentlyContinue
            Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\$service" `
                -Name 'Start' -Value 4 -Type DWord -ErrorAction SilentlyContinue
        }
    }
    # Installers leave servicing work for after the restart; wait until the
    # servicing processes have been gone for a minute.
    $deadline = (Get-Date).AddMinutes(20)
    $quietSince = $null
    while ($true) {
        $busy = @(Get-Process -Name 'TiWorker', 'TrustedInstaller', 'msiexec' -ErrorAction SilentlyContinue)
        if ($busy.Count -eq 0) {
            if ($null -eq $quietSince) { $quietSince = Get-Date }
            if (((Get-Date) - $quietSince).TotalSeconds -ge 60) { break }
        } else {
            $quietSince = $null
        }
        if ((Get-Date) -gt $deadline) {
            throw "servicing is still busy after 20 minutes: $(($busy | ForEach-Object { $_.Name }) -join ', ')"
        }
        Start-Sleep -Seconds 5
    }
    if (Test-Path -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') {
        throw 'Windows still has a servicing restart pending after the restart'
    }
    Write-SerialLog 'TOSHI-IMAGE-BUILD: servicing settled'
}

# Runs after Packer's last command, as SYSTEM: it removes what
# winrm-userdata.txt added and shuts Windows down. If anything fails the
# instance stays up, Packer's wait for the stop times out, and no image with
# an open WinRM listener is made.
$SealTask = @'
$ErrorActionPreference = 'Stop'
Start-Sleep -Seconds 30
try {
    Get-ChildItem -Path WSMan:\localhost\Listener |
        Where-Object { $_.Keys -contains 'Transport=HTTPS' } |
        Remove-Item -Recurse -Force
    Set-Item -Path WSMan:\localhost\Service\Auth\Basic -Value $false
    Remove-NetFirewallRule -Name 'toshi-packer-winrm'
    $thumbprint = (Get-Content -LiteralPath C:\toshi\packer-winrm.thumbprint -Raw).Trim()
    Remove-Item -LiteralPath "Cert:\LocalMachine\My\$thumbprint" -DeleteKey -Force
    Remove-Item -LiteralPath C:\toshi\packer-winrm.thumbprint -Force
    Unregister-ScheduledTask -TaskName 'toshi-image-seal' -Confirm:$false
    Remove-Item -LiteralPath C:\toshi\seal.ps1 -Force
    Stop-Computer -Force
} catch {
    Set-Content -LiteralPath C:\toshi\seal-failed.log -Value $_.Exception.Message
}
'@

function Invoke-Seal {
    # The installers are large and the pool never reads them.
    Remove-Item -LiteralPath $ConfigRoot -Recurse -Force
    # The pool's own files: an image must not look prepared.
    Remove-Item -LiteralPath (Join-Path $ToshiDir 'prepared'), (Join-Path $ToshiDir 'bootstrap.log') `
        -Force -ErrorAction SilentlyContinue
    Write-SerialLog 'TOSHI-IMAGE-BUILD: DONE'

    # Without Sysprep, EC2Launch would treat an instance of the AMI as one it
    # has already set up and skip its user data, which is how the pool
    # prepares it. The reset makes the next boot a first boot again.
    & "$env:ProgramFiles\Amazon\EC2Launch\EC2Launch.exe" reset --clean
    if ($LASTEXITCODE -ne 0) { throw "EC2Launch reset failed (exit $LASTEXITCODE)" }

    Set-Content -LiteralPath (Join-Path $ToshiDir 'seal.ps1') -Value $SealTask -Encoding Ascii
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
        -Argument '-NoProfile -ExecutionPolicy Bypass -File C:\toshi\seal.ps1'
    Register-ScheduledTask -TaskName 'toshi-image-seal' -Action $action -User 'SYSTEM' -RunLevel Highest -Force | Out-Null
    Start-ScheduledTask -TaskName 'toshi-image-seal'
}

try {
    switch ($Step) {
        'plan' {
            $plan = Get-InstallerPlan
            Write-ToolsEnv -Plan $plan
            $plan.Installers | ForEach-Object { "{0} {1} {2}" -f $_.Sha256, $_.File, $_.Url }
        }
        'tools' {
            New-Item -ItemType Directory -Force -Path $ToshiDir | Out-Null
            Write-SerialLog 'TOSHI-IMAGE-BUILD: start'
            $plan = Get-InstallerPlan
            Write-ToolsEnv -Plan $plan
            Get-Installers -Plan $plan
            New-RunnerAccount
            Set-ImageSettings
            # The shared scripts set their own error handling, as under firstlogon.ps1.
            $ErrorActionPreference = 'Continue'
            . (Join-Path $ConfigRoot 'runner-images.ps1')
            . (Join-Path $ConfigRoot 'tools.ps1')
            $ErrorActionPreference = 'Stop'
            Write-SerialLog 'TOSHI-IMAGE-BUILD: tools done'
        }
        'devdrive' { Test-DevDrive }
        'settle' { Wait-ServicingSettled }
        'seal' { Invoke-Seal }
    }
} catch {
    Write-Host "TOSHI-IMAGE-BUILD: FAILED $Step $($_.Exception.Message)"
    exit 1
}
