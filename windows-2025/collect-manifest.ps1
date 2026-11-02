#Requires -Version 5.1
# Collects the Windows image's contents as the fragment of its image manifest:
# packages, local users, services, listening ports and the firewall profiles.
# The fragment goes to the serial console between TOSHI-MANIFEST-BEGIN and
# TOSHI-MANIFEST-END, base64 and a line at a time, the way the Linux image's
# toshi-finalize writes its own; build.sh decodes it and assembles
# manifest.json beside the qcow2.
#
# Dot-sourced by tools.ps1, after the toolset lines, so Write-SerialLog is in
# scope. The AWS template's wrapper (aws/windows-2025/provision.ps1) keeps the
# same lines in C:\toshi\image-build.log instead, where the image carries them.
# Run on its own, it prints the lines and writes nothing else.

if (-not (Get-Command Write-SerialLog -ErrorAction SilentlyContinue)) {
    function Write-SerialLog {
        param([Parameter(Mandatory = $true)][string]$Line)
        Write-Host $Line
    }
}

# The installed packages, as the Linux image's dpkg-query line lists them: the
# name and the version the package itself reports.
function Get-ManifestPackages {
    return @(Get-Package -ErrorAction SilentlyContinue | Where-Object { $_.Name } |
        ForEach-Object { [pscustomobject]@{ name = $_.Name; version = [string]$_.Version } } |
        Sort-Object name, version)
}

# Local accounts with the groups they belong to. A member of Administrators
# whose account has no password is password-less; one that signs in with a
# password gets its rights only while the build supplies it, as build-only
# does on the Linux images.
function Get-ManifestUsers {
    $adminGroup = 'Administrators'
    $builtin = Get-LocalGroup -SID 'S-1-5-32-544' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($builtin) { $adminGroup = $builtin.Name }

    $local = @{}
    Get-LocalUser -ErrorAction SilentlyContinue | ForEach-Object { $local[$_.Name.ToLowerInvariant()] = $true }

    $groups = @{}
    Get-LocalGroup -ErrorAction SilentlyContinue | ForEach-Object {
        $groupName = $_.Name
        Get-LocalGroupMember -Group $groupName -ErrorAction SilentlyContinue | ForEach-Object {
            $key = ($_.Name -split '\\')[-1].ToLowerInvariant()
            if (-not $local.ContainsKey($key)) { return }
            if (-not $groups.ContainsKey($key)) {
                $groups[$key] = New-Object System.Collections.Generic.List[string]
            }
            $groups[$key].Add($groupName)
        }
    }

    return @(Get-LocalUser -ErrorAction SilentlyContinue | ForEach-Object {
            $user = $_
            $key = $user.Name.ToLowerInvariant()
            $userGroups = @()
            if ($groups.ContainsKey($key)) { $userGroups = @($groups[$key] | Sort-Object -Unique) }
            $sudo = 'none'
            if ($userGroups -contains $adminGroup) {
                if ($user.PasswordRequired) { $sudo = 'build-only' } else { $sudo = 'password-less' }
            }
            # uid is a Linux identifier; a Windows account has none.
            [pscustomobject]@{ name = $user.Name; uid = $null; groups = $userGroups; sudo = $sudo }
        } | Sort-Object name)
}

# Services that start with the machine, and scheduled tasks that are not
# disabled, each with the name the image reports it by.
function Get-ManifestServices {
    $services = @(Get-Service -ErrorAction SilentlyContinue | Where-Object { $_.StartType -eq 'Automatic' } |
        ForEach-Object { [pscustomobject]@{ name = $_.Name; kind = 'windows-service'; enabled = $true } })
    $tasks = @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.State -ne 'Disabled' } |
        ForEach-Object { [pscustomobject]@{ name = ($_.TaskPath + $_.TaskName); kind = 'scheduled-task'; enabled = $true } })
    return @(($services + $tasks) | Sort-Object kind, name)
}

# The TCP listeners, as ss -ltnpH lists them: the port and the process that
# holds it. IPv4 and IPv6 entries for one socket collapse to one line.
function Get-ManifestListening {
    return @(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | ForEach-Object {
            $process = ''
            $owner = Get-Process -Id $_.OwningProcess -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($owner) { $process = $owner.ProcessName }
            [pscustomobject]@{ port = [int]$_.LocalPort; process = $process }
        } | Sort-Object port, process -Unique)
}

# The Linux image names the nft table it loads; here it is the profiles of
# Windows Firewall that are on.
function Get-ManifestFirewall {
    $enabled = @(Get-NetFirewallProfile -ErrorAction SilentlyContinue | Where-Object { $_.Enabled } |
        ForEach-Object { $_.Name } | Sort-Object)
    if ($enabled.Count -eq 0) { return 'none' }
    return "windows-firewall:$($enabled -join ',')"
}

$fragment = [pscustomobject]@{
    packages  = @(Get-ManifestPackages)
    users     = @(Get-ManifestUsers)
    services  = @(Get-ManifestServices)
    listening = @(Get-ManifestListening)
    firewall  = (Get-ManifestFirewall)
}
$json = $fragment | ConvertTo-Json -Depth 6 -Compress
$encoded = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($json))

Write-SerialLog 'TOSHI-MANIFEST-BEGIN'
# 950 characters a line: far below any serial buffer, and few enough lines that
# the console keeps up.
for ($offset = 0; $offset -lt $encoded.Length; $offset += 950) {
    Write-SerialLog $encoded.Substring($offset, [Math]::Min(950, $encoded.Length - $offset))
}
Write-SerialLog 'TOSHI-MANIFEST-END'
