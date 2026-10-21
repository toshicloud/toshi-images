#Requires -Version 5.1
# Runs the vendored actions/runner-images build scripts (see vendor/runner-images/README.md),
# then .NET NGen. Dot-sourced by firstlogon.ps1, so Write-SerialLog is in scope. The Test-Is*
# functions below are the upstream helpers these scripts call, with the same checks.

function Test-IsArm64 {
    (Get-CimInstance -ClassName Win32_OperatingSystem).OSArchitecture -match 'ARM 64-bit'
}

function Test-IsX64 {
    (Get-CimInstance -ClassName Win32_OperatingSystem).OSArchitecture -eq '64-bit'
}

function Test-IsWin25 {
    (Get-CimInstance -ClassName Win32_OperatingSystem).Caption -match '2025'
}

function Test-IsWin22 {
    (Get-CimInstance -ClassName Win32_OperatingSystem).Caption -match '2022'
}

function Test-IsWin11 {
    (Get-CimInstance -ClassName Win32_OperatingSystem).Caption -match 'Windows 11'
}

function Test-IsWin25-X64 {
    (Test-IsWin25) -and (Test-IsX64)
}

function Test-IsWin22-X64 {
    (Test-IsWin22) -and (Test-IsX64)
}

function Test-IsWin11-Arm64 {
    (Test-IsWin11) -and (Test-IsArm64)
}

$VendorDir = Join-Path $PSScriptRoot 'vendor/runner-images'
. (Join-Path $VendorDir 'PathHelpers.ps1')

$scripts = @(
    'Configure-WindowsDefender.ps1',
    'Configure-System.ps1'
)
$previousErrorAction = $ErrorActionPreference
$ErrorActionPreference = 'Stop'
try {
    foreach ($file in $scripts) {
        Write-SerialLog "TOSHI-IMAGE-BUILD: runner-images $file"
        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        & (Join-Path $VendorDir $file)
        $watch.Stop()
        Write-SerialLog ("TOSHI-IMAGE-BUILD: runner-images-seconds {0} {1}" -f $file, [int]$watch.Elapsed.TotalSeconds)
    }
} finally {
    $ErrorActionPreference = $previousErrorAction
}

# .NET NGen during the build, the same three commands as upstream's
# Install-NativeImages.ps1. That script stops when `ngen update` exits non-zero,
# and on this image it exits -1 after compiling everything it can: a few CLR 2.0
# assemblies need .NET 3.5, which this image does not install. So the install
# step must succeed, and the update steps log their exit code without failing
# the build.
$ngen64 = Join-Path $env:SystemRoot 'Microsoft.NET\Framework64\v4.0.30319\ngen.exe'
$ngen32 = Join-Path $env:SystemRoot 'Microsoft.NET\Framework\v4.0.30319\ngen.exe'
$ngenSteps = @(
    @{ Name = 'install-x64'; Exe = $ngen64; Fatal = $true
       Args = @('install', 'Microsoft.PowerShell.Utility.Activities, Version=3.0.0.0, Culture=neutral, PublicKeyToken=31bf3856ad364e35') }
    @{ Name = 'update-x64'; Exe = $ngen64; Fatal = $false; Args = @('update') }
    @{ Name = 'update-x86'; Exe = $ngen32; Fatal = $false; Args = @('update') }
)
foreach ($step in $ngenSteps) {
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    & $step.Exe @($step.Args) | Out-Null
    $code = $LASTEXITCODE
    $watch.Stop()
    Write-SerialLog ("TOSHI-IMAGE-BUILD: runner-images-ngen {0} exit {1} seconds {2}" -f $step.Name, $code, [int]$watch.Elapsed.TotalSeconds)
    if ($code -ne 0 -and $step.Fatal) {
        throw "ngen $($step.Name) failed with exit code $code"
    }
}
