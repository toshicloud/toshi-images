#Requires -Version 5.1
# CI tool installs: the common set of GitHub's windows-2025 image (PowerShell 7,
# Git for Windows with Git LFS, Python, Node.js, Go, Rust, .NET SDK 8 and 9,
# Temurin 17 and 21, MSVC Build Tools, CMake, Ninja, 7-Zip, gh, yq, jq, NuGet)
# and WiX. Dot-sourced by firstlogon.ps1, so Write-SerialLog and $ConfigRoot are
# in scope. build.sh writes tools.env (installer file names and versions from
# versions.env) next to the installers on the config CD.

$toolsEnv = Join-Path $ConfigRoot 'tools.env'
if (-not (Test-Path -LiteralPath $toolsEnv)) {
    throw "tools.env not found on config CD"
}
$tools = Get-Content -LiteralPath $toolsEnv -Raw | ConvertFrom-StringData

. (Join-Path $ConfigRoot 'vendor/runner-images/PathHelpers.ps1')

function Get-ToolInstaller {
    param([Parameter(Mandatory = $true)][string]$Key)
    $name = $tools[$Key]
    if (-not $name) {
        throw "tools.env has no $Key"
    }
    $path = Join-Path $ConfigRoot $name
    if (-not (Test-Path -LiteralPath $path)) {
        throw "installer not found on config CD: $name"
    }
    return $path
}

# Start-Process -Wait, because PowerShell does not wait for GUI-subsystem
# installers (msiexec, Inno Setup, the VS bootstrapper) started with `&`.
# -Tries 3 is for an installer that downloads: it is run up to three times,
# 10 and then 30 seconds apart, with one serial line for each failed try.
function Invoke-ToolInstaller {
    param(
        [Parameter(Mandatory = $true)][string]$Tool,
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string[]]$ArgumentList,
        [int]$Tries = 1
    )
    Write-SerialLog "TOSHI-IMAGE-BUILD: tools $Tool"
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    for ($try = 1; ; $try++) {
        $process = Start-Process -FilePath $FilePath -ArgumentList $ArgumentList -Wait -PassThru -NoNewWindow
        if ($process.ExitCode -eq 0 -or $process.ExitCode -eq 3010) {
            break
        }
        if ($Tries -gt 1) {
            Write-SerialLog "TOSHI-IMAGE-BUILD: tools $Tool try $try/$Tries failed (exit $($process.ExitCode))"
        }
        if ($try -ge $Tries) {
            break
        }
        Start-Sleep -Seconds ($try * 20 - 10)
    }
    $watch.Stop()
    if ($process.ExitCode -ne 0 -and $process.ExitCode -ne 3010) {
        throw "$Tool installer failed (exit $($process.ExitCode))"
    }
    Write-SerialLog ("TOSHI-IMAGE-BUILD: tools-seconds {0} {1}" -f $Tool, [int]$watch.Elapsed.TotalSeconds)
}

function Install-Msi {
    param(
        [Parameter(Mandatory = $true)][string]$Tool,
        [Parameter(Mandatory = $true)][string]$Key,
        [string[]]$Properties = @()
    )
    $msi = Get-ToolInstaller $Key
    $msiArgs = @('/i', "`"$msi`"", '/qn', '/norestart', '/l*v', "`"C:\toshi\$Tool-install.log`"") + $Properties
    Invoke-ToolInstaller -Tool $Tool -FilePath 'msiexec.exe' -ArgumentList $msiArgs
}

function Assert-ToolFile {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "expected tool file missing after install: $Path"
    }
}

# 7-Zip, not Expand-Archive: Node's npm tree has paths past MAX_PATH.
function Expand-ToolZip {
    param(
        [Parameter(Mandatory = $true)][string]$Tool,
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $true)][string]$Destination
    )
    Invoke-ToolInstaller -Tool $Tool -FilePath 'C:\Program Files\7-Zip\7z.exe' -ArgumentList @(
        'x', '-y', '-bso0', '-bsp0', "-o`"$Destination`"", "`"$(Get-ToolInstaller $Key)`"")
}

function Install-PowerShell7 {
    Install-Msi -Tool 'powershell-7' -Key 'POWERSHELL_7' -Properties @('ADD_PATH=1', 'USE_MU=0', 'ENABLE_MU=0')
    Assert-ToolFile 'C:\Program Files\PowerShell\7\pwsh.exe'
}

function Install-GitForWindows {
    Invoke-ToolInstaller -Tool 'git' -FilePath (Get-ToolInstaller 'GIT_FOR_WINDOWS') -ArgumentList @(
        '/VERYSILENT', '/NORESTART', '/NOCANCEL', '/SP-', '/CLOSEAPPLICATIONS', '/RESTARTAPPLICATIONS',
        '/o:PathOption=CmdTools', '/o:BashTerminalOption=ConHost', '/o:EnableSymlinks=Enabled',
        '/COMPONENTS=gitlfs')
    $git = 'C:\Program Files\Git\cmd\git.exe'
    Assert-ToolFile $git
    Assert-ToolFile 'C:\Program Files\Git\bin\bash.exe'
    # `shell: bash` steps find Git Bash through PATH, as on GitHub-hosted runners.
    Add-MachinePathItem 'C:\Program Files\Git\bin'
    foreach ($setting in @(
            @('core.longpaths', 'true'),
            @('safe.directory', '*'),
            @('credential.interactive', 'false'))) {
        & $git config --system $setting[0] $setting[1]
        if ($LASTEXITCODE -ne 0) {
            throw "git config --system $($setting[0]) failed (exit $LASTEXITCODE)"
        }
    }
}

function Install-Rust {
    $env:RUSTUP_HOME = 'C:\Rust\rustup'
    $env:CARGO_HOME = 'C:\Rust\cargo'
    Invoke-ToolInstaller -Tool 'rust' -Tries 3 -FilePath (Get-ToolInstaller 'RUSTUP_INIT') -ArgumentList @(
        '-y', '--no-modify-path', '--profile', 'minimal', '--default-host', 'x86_64-pc-windows-msvc',
        '--default-toolchain', $tools['RUST_TOOLCHAIN'], '-c', 'clippy', '-c', 'rustfmt')
    Assert-ToolFile 'C:\Rust\cargo\bin\cargo.exe'
    foreach ($toolchain in ($tools['RUST_EXTRA_TOOLCHAINS'] -split '[ ,]' | Where-Object { $_ })) {
        Invoke-ToolInstaller -Tool "rust-$toolchain" -Tries 3 -FilePath 'C:\Rust\cargo\bin\rustup.exe' -ArgumentList @(
            'toolchain', 'install', $toolchain, '--profile', 'minimal', '-c', 'clippy', '-c', 'rustfmt')
    }
    [Environment]::SetEnvironmentVariable('RUSTUP_HOME', $env:RUSTUP_HOME, 'Machine')
    [Environment]::SetEnvironmentVariable('CARGO_HOME', $env:CARGO_HOME, 'Machine')
    Add-MachinePathItem 'C:\Rust\cargo\bin'
    # Jobs install other toolchains and fill the cargo registry: Users may modify.
    & icacls.exe 'C:\Rust' /grant '*S-1-5-32-545:(OI)(CI)M' /T /Q | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "icacls C:\Rust failed (exit $LASTEXITCODE)"
    }
}

function Install-VSBuildTools {
    Invoke-ToolInstaller -Tool 'vs-buildtools' -FilePath (Get-ToolInstaller 'VS_BUILDTOOLS') -ArgumentList @(
        '--quiet', '--wait', '--norestart', '--nocache',
        '--add', 'Microsoft.VisualStudio.Workload.VCTools',
        '--add', 'Microsoft.VisualStudio.Component.VC.Tools.x86.x64',
        '--add', 'Microsoft.VisualStudio.Component.Windows11SDK.26100')
    $vswhere = 'C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe'
    Assert-ToolFile $vswhere
    $link = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
        -find 'VC\Tools\MSVC\**\bin\Hostx64\x64\link.exe' | Select-Object -First 1
    if (-not $link) {
        throw 'link.exe not found through vswhere after the Build Tools install'
    }
}

function Install-SevenZip {
    Install-Msi -Tool '7zip' -Key 'SEVENZIP'
    Assert-ToolFile 'C:\Program Files\7-Zip\7z.exe'
    Add-MachinePathItem 'C:\Program Files\7-Zip'
}

function Install-DotNetAndWix {
    foreach ($major in @('8', '9')) {
        Invoke-ToolInstaller -Tool "dotnet-sdk-$major" -FilePath (Get-ToolInstaller "DOTNET_SDK_$major") -ArgumentList @(
            '/install', '/quiet', '/norestart')
    }
    $dotnet = 'C:\Program Files\dotnet\dotnet.exe'
    Assert-ToolFile $dotnet
    [Environment]::SetEnvironmentVariable('DOTNET_CLI_TELEMETRY_OPTOUT', '1', 'Machine')
    [Environment]::SetEnvironmentVariable('DOTNET_NOLOGO', '1', 'Machine')
    $env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
    $env:DOTNET_NOLOGO = '1'
    # The pinned nupkg on the config CD is the package source. The CD root (E:\)
    # stays unquoted: a quoted trailing backslash would escape the quote.
    Get-ToolInstaller 'WIX' | Out-Null
    Invoke-ToolInstaller -Tool 'wix' -FilePath $dotnet -ArgumentList @(
        'tool', 'install', 'wix', '--version', $tools['WIX_VERSION'],
        '--tool-path', 'C:\Tools\wix', '--add-source', $ConfigRoot)
    Assert-ToolFile 'C:\Tools\wix\wix.exe'
    Add-MachinePathItem 'C:\Tools\wix'
}

function Install-Python {
    Invoke-ToolInstaller -Tool 'python' -FilePath (Get-ToolInstaller 'PYTHON') -ArgumentList @(
        '/quiet', 'InstallAllUsers=1', 'TargetDir=C:\Python312', 'PrependPath=1',
        'Include_test=0', 'Include_launcher=1', 'InstallLauncherAllUsers=1', 'Shortcuts=0')
    Assert-ToolFile 'C:\Python312\python.exe'
    Assert-ToolFile 'C:\Python312\Scripts\pip.exe'
}

function Install-NodeJs {
    Expand-ToolZip -Tool 'node' -Key 'NODE' -Destination 'C:\toshi\node'
    $root = Get-ChildItem -LiteralPath 'C:\toshi\node' -Directory | Select-Object -First 1
    Move-Item -LiteralPath $root.FullName -Destination 'C:\Program Files\nodejs'
    Remove-Item -LiteralPath 'C:\toshi\node' -Force
    Assert-ToolFile 'C:\Program Files\nodejs\node.exe'
    Assert-ToolFile 'C:\Program Files\nodejs\npm.cmd'
    Add-MachinePathItem 'C:\Program Files\nodejs'
}

function Install-Go {
    # The zip's top directory is go\.
    Expand-ToolZip -Tool 'go' -Key 'GO' -Destination 'C:\Program Files'
    Assert-ToolFile 'C:\Program Files\Go\bin\go.exe'
    Add-MachinePathItem 'C:\Program Files\Go\bin'
}

# Temurin 17 is the default, as on GitHub's image; JAVA_HOME_<n>_X64 name each.
function Install-Temurin {
    $adoptium = 'C:\Program Files\Eclipse Adoptium'
    foreach ($major in @('17', '21')) {
        Expand-ToolZip -Tool "java-$major" -Key "JAVA$major" -Destination $adoptium
        $jdk = Get-ChildItem -LiteralPath $adoptium -Directory -Filter "jdk-$major.*" | Select-Object -First 1
        if (-not $jdk) {
            throw "Temurin $major not found under $adoptium"
        }
        Assert-ToolFile (Join-Path $jdk.FullName 'bin\java.exe')
        [Environment]::SetEnvironmentVariable("JAVA_HOME_${major}_X64", $jdk.FullName, 'Machine')
        if ($major -eq '17') {
            [Environment]::SetEnvironmentVariable('JAVA_HOME', $jdk.FullName, 'Machine')
            Add-MachinePathItem (Join-Path $jdk.FullName 'bin')
        }
    }
}

function Install-CMake {
    Install-Msi -Tool 'cmake' -Key 'CMAKE' -Properties @('ADD_CMAKE_TO_PATH=System', 'ALLUSERS=1')
    Assert-ToolFile 'C:\Program Files\CMake\bin\cmake.exe'
}

function Install-GitHubCli {
    Install-Msi -Tool 'gh' -Key 'GH'
    Assert-ToolFile 'C:\Program Files\GitHub CLI\gh.exe'
}

# Single-file tools go to C:\Tools\bin.
function Install-SmallTools {
    $bin = 'C:\Tools\bin'
    New-Item -ItemType Directory -Path $bin -Force | Out-Null
    Expand-ToolZip -Tool 'ninja' -Key 'NINJA' -Destination $bin
    foreach ($pair in @(@('YQ', 'yq.exe'), @('JQ', 'jq.exe'), @('NUGET', 'nuget.exe'))) {
        Copy-Item -LiteralPath (Get-ToolInstaller $pair[0]) -Destination (Join-Path $bin $pair[1])
    }
    foreach ($exe in @('ninja.exe', 'yq.exe', 'jq.exe', 'nuget.exe')) {
        Assert-ToolFile (Join-Path $bin $exe)
    }
    Add-MachinePathItem $bin
}

# Runs a tool and returns its output as one string. Windows PowerShell turns a
# native command's stderr into errors, and java writes its version there.
function Get-ToolOutput {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$ArgumentList = @()
    )
    $ErrorActionPreference = 'Continue'
    $out = & $FilePath @ArgumentList 2>&1 | ForEach-Object { "$_" }
    if ($LASTEXITCODE -ne 0) {
        throw "$FilePath $($ArgumentList -join ' ') failed (exit $LASTEXITCODE)"
    }
    return ($out -join "`n")
}

function Write-Toolset {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$Pattern
    )
    if ($Text -notmatch $Pattern) {
        throw "no $Name version in: $Text"
    }
    Write-SerialLog "TOOLSET $Name $($Matches[1])"
}

# One `TOOLSET <name> <version>` line per tool, from the tool itself run through
# the machine PATH a job gets; build.sh checks each against versions.env.
function Write-ToolsetVersions {
    $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    Write-Toolset 'pwsh' (Get-ToolOutput 'pwsh' @('-NoProfile', '-Command', '$PSVersionTable.PSVersion.ToString()')) '^(\S+)'
    Write-Toolset 'git' (Get-ToolOutput 'git' @('--version')) 'git version (\S+)'
    Write-Toolset 'git-lfs' (Get-ToolOutput 'git' @('lfs', 'version')) 'git-lfs/(\S+)'
    Write-Toolset 'python' (Get-ToolOutput 'python' @('--version')) 'Python (\S+)'
    Write-Toolset 'pip' (Get-ToolOutput 'python' @('-m', 'pip', '--version')) 'pip (\S+)'
    Write-Toolset 'node' (Get-ToolOutput 'node' @('--version')) 'v(\S+)'
    Write-Toolset 'go' (Get-ToolOutput 'go' @('version')) 'go version go(\S+)'
    Write-Toolset 'rust' (Get-ToolOutput 'rustc' @('--version')) 'rustc (\S+)'
    foreach ($toolchain in ($tools['RUST_EXTRA_TOOLCHAINS'] -split '[ ,]' | Where-Object { $_ })) {
        Write-Toolset 'rust-extra' (Get-ToolOutput 'rustup' @('run', $toolchain, 'rustc', '--version')) 'rustc (\S+)'
    }
    $sdks = Get-ToolOutput 'dotnet' @('--list-sdks')
    Write-Toolset 'dotnet-8' $sdks '(?m)^(8\.\S+)'
    Write-Toolset 'dotnet-9' $sdks '(?m)^(9\.\S+)'
    # Temurin 21's build string ends in -LTS; the version is the part before it.
    foreach ($major in @('17', '21')) {
        $java = Join-Path ([Environment]::GetEnvironmentVariable("JAVA_HOME_${major}_X64", 'Machine')) 'bin\java.exe'
        Write-Toolset "java-$major" (Get-ToolOutput $java @('-version')) '\(build ([0-9][0-9.+]*)'
    }
    $msbuild = & 'C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe' -latest -products * `
        -requires Microsoft.Component.MSBuild -find 'MSBuild\**\Bin\MSBuild.exe' | Select-Object -First 1
    if (-not $msbuild) {
        throw 'MSBuild.exe not found through vswhere'
    }
    Write-Toolset 'msbuild' (Get-ToolOutput $msbuild @('-version', '-nologo')) '(?m)^(\d+\.\d+\.\d+\.\d+)\s*$'
    Write-Toolset 'cmake' (Get-ToolOutput 'cmake' @('--version')) 'cmake version (\S+)'
    Write-Toolset 'ninja' (Get-ToolOutput 'ninja' @('--version')) '^(\S+)'
    Write-Toolset '7zip' (Get-Item 'C:\Program Files\7-Zip\7z.exe').VersionInfo.ProductVersion '^(\S+)'
    Write-Toolset 'gh' (Get-ToolOutput 'gh' @('--version')) 'gh version (\S+)'
    Write-Toolset 'yq' (Get-ToolOutput 'yq' @('--version')) 'version v(\S+)'
    Write-Toolset 'jq' (Get-ToolOutput 'jq' @('--version')) 'jq-(\S+)'
    Write-Toolset 'nuget' (Get-ToolOutput 'nuget' @('help')) 'NuGet Version: (\S+)'
    Write-Toolset 'wix' (Get-ToolOutput 'wix' @('--version')) '^([^+\s]+)'
}

$previousErrorAction = $ErrorActionPreference
$ErrorActionPreference = 'Stop'
try {
    Install-PowerShell7
    Install-GitForWindows
    Install-Rust
    Install-VSBuildTools
    Install-SevenZip
    Install-DotNetAndWix
    Install-Python
    Install-NodeJs
    Install-Go
    Install-Temurin
    Install-CMake
    Install-GitHubCli
    Install-SmallTools
    Write-ToolsetVersions
    Write-SerialLog 'TOSHI-IMAGE-BUILD: tools done'
} finally {
    $ErrorActionPreference = $previousErrorAction
}
