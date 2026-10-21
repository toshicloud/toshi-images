#Requires -Version 5.1
$ConfigRoot = $PSScriptRoot

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

function Invoke-TryStep {
    param(
        [Parameter(Mandatory = $true)][string]$Step,
        [Parameter(Mandatory = $true)][scriptblock]$Action
    )
    Write-SerialLog "TOSHI-IMAGE-BUILD: $Step"
    try {
        & $Action
        return $true
    } catch {
        Write-Warning "Step '$Step' failed (non-fatal): $($_.Exception.Message)"
        Write-SerialLog "TOSHI-IMAGE-BUILD: WARN $Step $($_.Exception.Message)"
        return $false
    }
}

function Stop-BuildFailed {
    param([Parameter(Mandatory = $true)][string]$Message)
    try {
        Write-SerialLog "TOSHI-IMAGE-BUILD: FAILED $Message"
    } catch {
        Write-Warning "Could not write failure to serial: $($_.Exception.Message)"
    }
    Stop-Transcript -ErrorAction SilentlyContinue | Out-Null
    shutdown.exe /s /t 5 /f
    exit 1
}

function Get-VirtioRoot {
    $vol = Get-Volume -ErrorAction SilentlyContinue | Where-Object {
        $_.FileSystemLabel -like 'virtio-win*'
    } | Select-Object -First 1
    if ($null -eq $vol -or -not $vol.DriveLetter) {
        $cim = Get-CimInstance -ClassName Win32_Volume -ErrorAction SilentlyContinue | Where-Object {
            $_.Label -like 'virtio-win*' -and $_.DriveLetter
        } | Select-Object -First 1
        if ($null -eq $cim) {
            throw 'virtio-win volume not found'
        }
        return ($cim.DriveLetter + '\')
    }
    return ($vol.DriveLetter + ':\')
}

function Install-VirtioDrivers {
    param([Parameter(Mandatory = $true)][string]$Root)
    $dirs = @('viostor', 'NetKVM', 'vioserial', 'Balloon')
    foreach ($dir in $dirs) {
        $infGlob = Join-Path $Root ($dir + '\2k25\amd64\*.inf')
        $parent = Split-Path -Parent $infGlob
        if (-not (Test-Path -LiteralPath $parent)) {
            throw "Driver directory missing: $parent"
        }
        & pnputil.exe /add-driver $infGlob /install
        if ($LASTEXITCODE -eq 259) {
            # ERROR_NO_MORE_ITEMS: every driver in this directory is already in the driver store.
            Write-SerialLog "TOSHI-IMAGE-BUILD: pnputil-no-new-drivers $dir"
        } elseif ($LASTEXITCODE -ne 0) {
            throw "pnputil failed for $dir (exit $LASTEXITCODE)"
        }
    }
}

function Write-PnpDiagnostics {
    Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | ForEach-Object {
        if ($_.InstanceId -match 'VEN_1AF4' -or ($_.Status -ne 'OK' -and $_.FriendlyName -match 'Virtio|Serial')) {
            Write-SerialLog ("DEVICE {0} {1} {2} {3}" -f $_.Status, $_.Service, $_.Class, $_.InstanceId)
        }
    }
}

function Get-DriverByService {
    $byService = @{}
    Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | ForEach-Object {
        if (-not $_.Service) { return }
        $key = $_.Service.ToLowerInvariant()
        # virtio-win has shipped the serial driver service as vioser and as vioserial.
        if ($key -eq 'viostor' -or $key -eq 'netkvm' -or $key -eq 'balloon') {
            $byService[$key] = $_
        } elseif ($key -like 'vioser*' -or $key -eq 'virtioserial') {
            $byService['vioser'] = $_
        }
    }
    return $byService
}

function Write-DriverStatusLines {
    $byService = Get-DriverByService
    foreach ($required in @('viostor', 'vioser')) {
        if (-not $byService.ContainsKey($required)) {
            pnputil.exe /scan-devices | Out-Null
            Start-Sleep -Seconds 5
            $byService = Get-DriverByService
            break
        }
    }
    foreach ($key in @($byService.Keys)) {
        Write-SerialLog ("DRIVER {0} {1}" -f $byService[$key].Service, $byService[$key].Status)
    }
    foreach ($required in @('viostor', 'vioser')) {
        if (-not $byService.ContainsKey($required)) {
            Write-SerialLog "DRIVER $required FAILED"
            Write-PnpDiagnostics
            throw "Required driver $required not present or not OK"
        }
        if ($byService[$required].Status -ne 'OK') {
            Write-SerialLog ("DRIVER {0} FAILED" -f $required)
            Write-PnpDiagnostics
            throw "Required driver $required status is $($byService[$required].Status)"
        }
    }
}

function Install-BalloonService {
    param([Parameter(Mandatory = $true)][string]$Root)
    $src = Join-Path $Root 'Balloon\2k25\amd64\blnsvr.exe'
    if (-not (Test-Path -LiteralPath $src)) {
        throw "blnsvr.exe not found at $src"
    }
    $destDir = 'C:\Program Files\Balloon'
    New-Item -ItemType Directory -Path $destDir -Force | Out-Null
    Copy-Item -LiteralPath $src -Destination (Join-Path $destDir 'blnsvr.exe') -Force
    & (Join-Path $destDir 'blnsvr.exe') -i
    if ($LASTEXITCODE -ne 0) {
        throw "blnsvr.exe -i failed (exit $LASTEXITCODE)"
    }
}

function Expand-RunnerArchive {
    param([Parameter(Mandatory = $true)][string]$ConfigDir)
    $zip = Get-ChildItem -LiteralPath $ConfigDir -Filter 'actions-runner-win-x64-*.zip' -File |
        Select-Object -First 1
    if ($null -eq $zip) {
        throw 'actions-runner win-x64 zip not found on config CD'
    }
    if ($zip.Name -match 'actions-runner-win-x64-([0-9.]+)\.zip') {
        $ver = $Matches[1]
    } else {
        throw "Could not parse runner version from $($zip.Name)"
    }
    $dest = 'C:\actions-runner'
    if (Test-Path -LiteralPath $dest) {
        Remove-Item -LiteralPath $dest -Recurse -Force
    }
    Expand-Archive -LiteralPath $zip.FullName -DestinationPath $dest -Force
    Write-SerialLog "TOOLSET runner $ver"
}

function Register-ToshiGuestTask {
    $exe = 'C:\toshi\toshi-guest.exe'
    if (-not (Test-Path -LiteralPath $exe)) {
        throw 'toshi-guest.exe missing under C:\toshi'
    }
    $devdriveAction = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-NoProfile -ExecutionPolicy Bypass -File C:\toshi\devdrive.ps1 -Wait'
    $action = New-ScheduledTaskAction -Execute $exe -Argument 'run --transport serial:\\.\Global\toshi.guest'
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User 'runner'
    $principal = New-ScheduledTaskPrincipal -UserId 'runner' -LogonType Interactive -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet `
        -ExecutionTimeLimit ([TimeSpan]::Zero) `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -MultipleInstances IgnoreNew
    Register-ScheduledTask -TaskPath '\toshi\' -TaskName 'toshi-guest' -Action $devdriveAction, $action -Trigger $trigger `
        -Principal $principal -Settings $settings -Force | Out-Null
}

function Register-ToshiDevDriveTask {
    $script = 'C:\toshi\devdrive.ps1'
    if (-not (Test-Path -LiteralPath $script)) {
        throw 'devdrive.ps1 missing under C:\toshi'
    }
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-NoProfile -ExecutionPolicy Bypass -File C:\toshi\devdrive.ps1'
    $trigger = New-ScheduledTaskTrigger -AtStartup
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet `
        -ExecutionTimeLimit ([TimeSpan]::FromMinutes(10)) `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -MultipleInstances IgnoreNew
    Register-ScheduledTask -TaskPath '\toshi\' -TaskName 'toshi-devdrive' -Action $action -Trigger $trigger `
        -Principal $principal -Settings $settings -Force | Out-Null
}

trap {
    Stop-BuildFailed $_.Exception.Message
}

New-Item -ItemType Directory -Path 'C:\toshi' -Force | Out-Null
Start-Transcript -Path 'C:\toshi\firstlogon.log' -Force | Out-Null

Write-SerialLog 'TOSHI-IMAGE-BUILD: start'

$virtioRoot = $null
try {
    $virtioRoot = Get-VirtioRoot
} catch {
    Stop-BuildFailed $_.Exception.Message
}

Write-SerialLog 'TOSHI-IMAGE-BUILD: virtio-drivers'
try {
    Install-VirtioDrivers -Root $virtioRoot
} catch {
    Stop-BuildFailed $_.Exception.Message
}

Invoke-TryStep 'balloon-service' { Install-BalloonService -Root $virtioRoot } | Out-Null

try {
    Write-DriverStatusLines
} catch {
    Stop-BuildFailed $_.Exception.Message
}

$guestSrc = Join-Path $ConfigRoot 'toshi-guest.exe'
if (-not (Test-Path -LiteralPath $guestSrc)) {
    Stop-BuildFailed 'toshi-guest.exe not found on config CD'
}
Copy-Item -LiteralPath $guestSrc -Destination 'C:\toshi\toshi-guest.exe' -Force
Write-SerialLog 'TOSHI-IMAGE-BUILD: toshi-guest'

$devdriveSrc = Join-Path $ConfigRoot 'devdrive.ps1'
if (-not (Test-Path -LiteralPath $devdriveSrc)) {
    Stop-BuildFailed 'devdrive.ps1 not found on config CD'
}
Copy-Item -LiteralPath $devdriveSrc -Destination 'C:\toshi\devdrive.ps1' -Force
Write-SerialLog 'TOSHI-IMAGE-BUILD: devdrive-script'

try {
    Expand-RunnerArchive -ConfigDir $ConfigRoot
} catch {
    Stop-BuildFailed $_.Exception.Message
}

try {
    Register-ToshiGuestTask
    Write-SerialLog 'TOSHI-IMAGE-BUILD: scheduled-task'
} catch {
    Stop-BuildFailed $_.Exception.Message
}

try {
    Register-ToshiDevDriveTask
    Write-SerialLog 'TOSHI-IMAGE-BUILD: devdrive-task'
} catch {
    Stop-BuildFailed $_.Exception.Message
}

Invoke-TryStep 'winlogon-autologon' {
    Remove-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' `
        -Name 'AutoLogonCount' -ErrorAction SilentlyContinue
} | Out-Null

Invoke-TryStep 'powercfg' {
    powercfg.exe /change monitor-timeout-ac 0
    powercfg.exe /change monitor-timeout-dc 0
    powercfg.exe /change standby-timeout-ac 0
    powercfg.exe /change standby-timeout-dc 0
    powercfg.exe /change hibernate-timeout-ac 0
    powercfg.exe /change hibernate-timeout-dc 0
    powercfg.exe /hibernate off
} | Out-Null

Invoke-TryStep 'screensaver' {
    Set-ItemProperty -Path 'HKCU:\Control Panel\Desktop' -Name 'ScreenSaveActive' -Value '0' -Type String
} | Out-Null

Invoke-TryStep 'nolockscreen' {
    New-Item -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Personalization' -Force | Out-Null
    Set-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Personalization' `
        -Name 'NoLockScreen' -Value 1 -Type DWord
} | Out-Null

Invoke-TryStep 'windows-update-off' {
    New-Item -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' -Force | Out-Null
    Set-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' `
        -Name 'NoAutoUpdate' -Value 1 -Type DWord
    Stop-Service -Name wuauserv -Force -ErrorAction SilentlyContinue
    Set-Service -Name wuauserv -StartupType Disabled -ErrorAction SilentlyContinue
} | Out-Null

# Install VM has outbound network for evaluation activation only.
try {
    Write-SerialLog 'TOSHI-IMAGE-BUILD: activate'
    $activationWatch = [System.Diagnostics.Stopwatch]::StartNew()
    $activated = $false
    while (-not $activated -and $activationWatch.Elapsed.TotalSeconds -lt 300) {
        & cscript //nologo "$env:SystemRoot\System32\slmgr.vbs" /ato | Out-Null
        $lic = Get-CimInstance SoftwareLicensingProduct -Filter "PartialProductKey IS NOT NULL AND ApplicationID='55c92734-d682-4d71-983e-d6ec3f16059f'" -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -ne $lic -and $lic.LicenseStatus -eq 1) {
            $activated = $true
        } else {
            Start-Sleep -Seconds 10
        }
    }
    if (-not $activated) {
        Stop-BuildFailed 'evaluation not activated within 300 s'
    }
    Write-SerialLog 'TOSHI-IMAGE-BUILD: activated'
    $xprOut = & cscript //nologo "$env:SystemRoot\System32\slmgr.vbs" /xpr
    foreach ($line in ($xprOut | Out-String -Width 4096) -split "`r?`n") {
        if ($line.Trim().Length -gt 0) {
            Write-SerialLog ("TOSHI-IMAGE-BUILD: xpr {0}" -f $line.Trim())
        }
    }
    $activationSeconds = [int]$activationWatch.Elapsed.TotalSeconds
    Write-SerialLog ("TOSHI-IMAGE-BUILD: activation-seconds {0}" -f $activationSeconds)
} catch {
    Stop-BuildFailed $_.Exception.Message
}

Invoke-TryStep 'defender-off' {
    Set-MpPreference -DisableRealtimeMonitoring $true -ErrorAction SilentlyContinue
    New-Item -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Real-Time Protection' -Force | Out-Null
    Set-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Real-Time Protection' `
        -Name 'DisableRealtimeMonitoring' -Value 1 -Type DWord
} | Out-Null

Invoke-TryStep 'server-manager-off' {
    New-Item -Path 'HKLM:\SOFTWARE\Microsoft\ServerManager' -Force | Out-Null
    Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\ServerManager' `
        -Name 'DoNotOpenServerManagerAtLogon' -Value 1 -Type DWord
    Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object {
        $_.TaskPath -like '*Server Manager*' -or $_.TaskName -like '*ServerManager*'
    } | ForEach-Object { Disable-ScheduledTask -TaskName $_.TaskName -TaskPath $_.TaskPath -ErrorAction SilentlyContinue }
} | Out-Null

Invoke-TryStep 'new-network-window-off' {
    New-Item -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Network' -Force | Out-Null
    Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Network' `
        -Name 'NewNetworkWindowOff' -Value 1 -Type DWord
} | Out-Null

Invoke-TryStep 'oobe-privacy-off' {
    New-Item -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\OOBE' -Force | Out-Null
    Set-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\OOBE' `
        -Name 'DisablePrivacyExperience' -Value 1 -Type DWord
} | Out-Null

# toshi-guest starts the OpenSSH Server service when the runner of
# a job with debug minutes exits, so the image has it installed and disabled.
Write-SerialLog 'TOSHI-IMAGE-BUILD: sshd'
try {
    $cap = Get-WindowsCapability -Online -Name 'OpenSSH.Server*' | Select-Object -First 1
    if ($null -eq $cap) { throw 'no OpenSSH.Server capability' }
    if ($cap.State -ne 'Installed') {
        Add-WindowsCapability -Online -Name $cap.Name -ErrorAction Stop | Out-Null
    }
    Stop-Service -Name sshd -Force -ErrorAction SilentlyContinue
    Set-Service -Name sshd -StartupType Disabled -ErrorAction Stop
    $sshdVer = (Get-Item -LiteralPath "$env:WINDIR\System32\OpenSSH\sshd.exe" -ErrorAction Stop).VersionInfo.ProductVersion
    Write-SerialLog "TOOLSET sshd $sshdVer disabled"
} catch {
    Stop-BuildFailed "sshd: $($_.Exception.Message)"
}

Invoke-TryStep 'azure-arc-setup-remove' {
    if (Get-Command Get-WindowsFeature -ErrorAction SilentlyContinue) {
        $feat = Get-WindowsFeature -Name AzureArcSetup -ErrorAction SilentlyContinue
        if ($feat -and $feat.Installed) {
            Uninstall-WindowsFeature -Name AzureArcSetup -ErrorAction Stop | Out-Null
            Write-SerialLog 'TOSHI-IMAGE-BUILD: azure-arc-removed'
        } else {
            Write-SerialLog 'TOSHI-IMAGE-BUILD: azure-arc-not-installed'
        }
    } else {
        Write-SerialLog 'TOSHI-IMAGE-BUILD: azure-arc-skip-no-cmdlet'
    }
} | Out-Null

$runnerImagesSrc = Join-Path $ConfigRoot 'runner-images.ps1'
if (-not (Test-Path -LiteralPath $runnerImagesSrc)) {
    Stop-BuildFailed 'runner-images.ps1 not found on config CD'
}
try {
    . $runnerImagesSrc
} catch {
    Stop-BuildFailed $_.Exception.Message
}

$toolsSrc = Join-Path $ConfigRoot 'tools.ps1'
if (-not (Test-Path -LiteralPath $toolsSrc)) {
    Stop-BuildFailed 'tools.ps1 not found on config CD'
}
try {
    . $toolsSrc
} catch {
    Stop-BuildFailed $_.Exception.Message
}

Invoke-TryStep 'delete-unattend' {
    Remove-Item -Path 'C:\Windows\Panther\unattend*.xml' -Force -ErrorAction SilentlyContinue
    Get-ChildItem -Path 'C:\Windows\Panther' -Recurse -Filter 'unattend*.xml' -ErrorAction SilentlyContinue |
        Remove-Item -Force -ErrorAction SilentlyContinue
} | Out-Null

Invoke-TryStep 'pagefile-clear-shutdown' {
    Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management' `
        -Name 'ClearPageFileAtShutdown' -Value 1 -Type DWord
} | Out-Null

Invoke-TryStep 'retrim' {
    Optimize-Volume -DriveLetter C -ReTrim -ErrorAction Stop
} | Out-Null

Write-SerialLog 'TOSHI-IMAGE-BUILD: DONE'
Stop-Transcript -ErrorAction SilentlyContinue | Out-Null
shutdown.exe /s /t 5 /f
