#Requires -Version 5.1
<#
  windows-migration-skill :: collector (Windows 10 / 11)

  READ-ONLY. No admin. No network upload. Writes one JSON file.
  Compatibility: Windows PowerShell 5.1 and PowerShell 7+.

  Usage:
    powershell -NoProfile -ExecutionPolicy Bypass -File .\collect\win.ps1
    powershell -NoProfile -ExecutionPolicy Bypass -File .\collect\win.ps1 -OutFile profile.raw.json -SkipWinget

  Output: profile.raw.json (schema: schema/profile.schema.json)
#>
[CmdletBinding()]
param(
    [string]$OutFile = (Join-Path (Get-Location).Path 'profile.raw.json'),
    [switch]$SkipWinget,
    [switch]$SkipStore,
    [switch]$SkipSizes,
    [int]$MaxFilesPerPath = 200000
)

$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
$script:Warnings = New-Object System.Collections.ArrayList
$script:ShortcutTargets = @{}

function Add-Warning {
    param([string]$Message)
    $null = $script:Warnings.Add($Message)
    Write-Warning $Message
}

function Get-NormalizedName {
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return '' }
    $s = $Name.ToLowerInvariant()
    $s = $s -replace '\(x64\)|\(x86\)|\(64-bit\)|\(32-bit\)', ''
    $s = $s -replace '\bv?\d+(\.\d+){1,4}\b', ''
    $s = $s -replace '[^a-z0-9\u4e00-\u9fff]', ''
    return $s
}

function Test-Directory {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    if ($Path.IndexOf([char]0) -ge 0) { return $false }
    try { return (Test-Path -LiteralPath $Path -PathType Container -ErrorAction SilentlyContinue) } catch { return $false }
}

function Get-PathSize {
    param([string]$Path, [int]$MaxFiles)
    $bytes = [int64]0
    $count = 0
    $truncated = $false
    try {
        $items = Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue
        foreach ($f in $items) {
            $bytes += [int64]$f.Length
            $count++
            if ($count -ge $MaxFiles) { $truncated = $true; break }
        }
    } catch {
        $truncated = $true
    }
    return [pscustomobject]@{
        size_bytes = $bytes
        file_count = $count
        truncated  = $truncated
    }
}

function Get-ConfigHints {
    param([string]$Name, [string]$Publisher)
    $hints = New-Object System.Collections.ArrayList
    $bases = @($env:APPDATA, $env:LOCALAPPDATA, $env:ProgramData, (Join-Path $env:LOCALAPPDATA 'Programs'))
    $candidates = New-Object System.Collections.ArrayList
    if (-not [string]::IsNullOrWhiteSpace($Name)) {
        $null = $candidates.Add($Name)
        $stripped = ($Name -replace '\(.*?\)', '').Trim()
        if ($stripped) { $null = $candidates.Add($stripped) }
        $null = $candidates.Add(($Name -replace '\s+', ''))
    }
    if (-not [string]::IsNullOrWhiteSpace($Publisher) -and $Publisher -ne 'Unknown') {
        $null = $candidates.Add($Publisher)
    }
    $seen = @{}
    foreach ($c in $candidates) {
        if ([string]::IsNullOrWhiteSpace($c)) { continue }
        $c = ($c -replace '[\x00-\x1F]', '').Trim()
        if ([string]::IsNullOrWhiteSpace($c)) { continue }
        if ($c -match '[\*\?\|<>:"]' -or $c.Contains('\') -or $c.Contains('/')) { continue }
        foreach ($b in $bases) {
            if ([string]::IsNullOrWhiteSpace($b)) { continue }
            $p = Join-Path $b $c
            if ($seen.ContainsKey($p)) { continue }
            $seen[$p] = $true
            if (Test-Directory $p) {
                $null = $hints.Add($p)
                if ($hints.Count -ge 3) { return @($hints) }
            }
        }
    }
    return @($hints)
}

# ---------------------------------------------------------------- registry apps

function Get-RegistryApps {
    $paths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    $result = New-Object System.Collections.ArrayList
    $seen = @{}

    foreach ($p in $paths) {
        $keys = @()
        try { $keys = @(Get-ItemProperty -Path $p -ErrorAction SilentlyContinue) } catch { }
        foreach ($k in $keys) {
            if ($null -eq $k) { continue }
            $name = ''
            try { $name = [string]$k.DisplayName } catch { }
            if ([string]::IsNullOrWhiteSpace($name)) { continue }
            $name = $name.Trim()

            $sys = $null
            try { $sys = $k.SystemComponent } catch { }
            if ($sys -eq 1 -or $sys -eq '1') { continue }

            $parent = ''
            try { $parent = [string]$k.ParentKeyName } catch { }
            if (-not [string]::IsNullOrWhiteSpace($parent)) { continue }

            $releaseType = ''
            try { $releaseType = [string]$k.ReleaseType } catch { }
            if ($releaseType -eq 'Update' -or $releaseType -eq 'Hotfix' -or $releaseType -eq 'Security Update') { continue }

            if ($name -match '^(KB\d{6,}|Update for |Security Update for |Hotfix for |Microsoft Visual C\+\+ \d{4} Redistributable)') { continue }

            $norm = Get-NormalizedName $name
            if ([string]::IsNullOrWhiteSpace($norm)) { continue }
            if ($seen.ContainsKey($norm)) { continue }
            $seen[$norm] = $true

            $productCode = ''
            $keyName = ''
            try { $keyName = [string]$k.PSChildName } catch { }
            if ($keyName -match '^\{[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\}$') {
                $productCode = $keyName
            }

            $version = ''
            try { $version = ([string]$k.DisplayVersion).Trim() } catch { }
            $publisher = ''
            try { $publisher = ([string]$k.Publisher).Trim() } catch { }
            $location = ''
            try { $location = ([string]$k.InstallLocation).Trim() } catch { }
            $uninstall = ''
            try { $uninstall = ([string]$k.UninstallString).Trim() } catch { }

            $null = $result.Add([pscustomobject]@{
                name             = $name
                normalized_name  = $norm
                version          = $version
                publisher        = $publisher
                install_location = $location
                uninstall_string = $uninstall
                product_code     = $productCode
                source           = 'registry'
                config_hints     = @(Get-ConfigHints -Name $name -Publisher $publisher)
            })
        }
    }
    return @($result)
}

# ---------------------------------------------------------------- winget

function Get-WingetInstalled {
    # `winget list` is the authoritative source. Its ID prefix *is* the answer:
    #   Publisher.Product  -> a real winget package exists   -> auto
    #   ARP\...            -> installed via registry only    -> manual
    #   MSIX\...           -> Microsoft Store app            -> store
    # This replaces name-to-ID fuzzy matching, which fails badly for localized apps.
    $exe = Get-Command winget -ErrorAction SilentlyContinue
    if (-not $exe) {
        Add-Warning 'winget not found; falling back to registry only.'
        return @()
    }

    $lines = @()
    try {
        $lines = @(& $exe.Source list --disable-interactivity --accept-source-agreements 2>$null)
    } catch {
        Add-Warning ('winget list failed: ' + $_.Exception.Message)
        return @()
    }
    if ($lines.Count -eq 0) {
        Add-Warning 'winget list returned no rows.'
        return @()
    }

    $result = New-Object System.Collections.ArrayList
    $kindPrefix = '^(MSIX\\|ARP\\)'
    $pkgShape   = '^[A-Za-z][A-Za-z0-9._\-]*\.[A-Za-z0-9][A-Za-z0-9._\-+]*$'
    $verShape   = '^\d+(\.\d+)*$'

    foreach ($line in $lines) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        if ($line -match '^\s*(名称|Name|Nazwa|Nom|Name)\s{2,}') { continue }
        if ($line -match '^-{5,}') { continue }

        $parts = @($line -split '\s{2,}' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        if ($parts.Count -lt 2) { continue }

        $idIndex = -1
        for ($i = 1; $i -lt $parts.Count; $i++) {
            $candidate = $parts[$i].Trim()
            if ($candidate -match $kindPrefix) { $idIndex = $i; break }
            if ($candidate -match $pkgShape -and $candidate -notmatch $verShape) { $idIndex = $i; break }
        }
        if ($idIndex -lt 0) { continue }

        $name = ($parts[0..($idIndex - 1)] -join '  ').Trim()
        if ([string]::IsNullOrWhiteSpace($name)) { continue }

        $id = $parts[$idIndex].Trim()
        $kind = 'package'
        if ($id.StartsWith('ARP\')) { $kind = 'arp' }
        elseif ($id.StartsWith('MSIX\')) { $kind = 'msix' }

        $version = ''
        $vi = $idIndex + 1
        if ($vi -lt $parts.Count -and $parts[$vi].Trim() -match $verShape) { $version = $parts[$vi].Trim() }

        $null = $result.Add([pscustomobject]@{
            name    = $name
            id      = $id
            kind    = $kind
            version = $version
        })
    }

    if ($result.Count -eq 0) { Add-Warning 'winget list produced no parseable rows.' }
    return @($result)
}

# ---------------------------------------------------------------- other package managers

function Get-ScoopApps {
    $exe = Get-Command scoop -ErrorAction SilentlyContinue
    if (-not $exe) { return @() }
    $result = New-Object System.Collections.ArrayList
    try {
        $out = & $exe.Source export 2>$null
        if (-not $out) { return @() }
        $json = ($out -join "`n") | ConvertFrom-Json
        foreach ($app in @($json.apps)) {
            if ($null -eq $app) { continue }
            $null = $result.Add([pscustomobject]@{
                name    = [string]$app.Name
                version = [string]$app.Version
                bucket  = [string]$app.Source
            })
        }
    } catch {
        Add-Warning 'scoop export failed.'
    }
    return @($result)
}

function Get-ChocoApps {
    $exe = Get-Command choco -ErrorAction SilentlyContinue
    if (-not $exe) { return @() }
    $result = New-Object System.Collections.ArrayList
    try {
        $out = & $exe.Source list --local-only --limit-output 2>$null
        foreach ($line in @($out)) {
            if ($line -match '^([^|]+)\|(.+)$') {
                $null = $result.Add([pscustomobject]@{
                    name    = $Matches[1].Trim()
                    version = $Matches[2].Trim()
                })
            }
        }
    } catch {
        Add-Warning 'choco list failed.'
    }
    return @($result)
}

# ---------------------------------------------------------------- store apps

function Get-StoreApps {
    $result = New-Object System.Collections.ArrayList
    try {
        $pkgs = @(Get-AppxPackage -ErrorAction SilentlyContinue)
        foreach ($p in $pkgs) {
            if ($null -eq $p) { continue }
            if ($p.SignatureKind -ne 'Store') { continue }
            if ($p.IsFramework) { continue }
            $null = $result.Add([pscustomobject]@{
                name            = [string]$p.Name
                version         = [string]$p.Version
                package_full_name = [string]$p.PackageFullName
                publisher       = [string]$p.Publisher
                source          = 'store'
            })
        }
    } catch {
        Add-Warning 'Get-AppxPackage failed.'
    }
    return @($result)
}

# ---------------------------------------------------------------- start menu (portable apps)

function Get-ShortcutApps {
    $dirs = @(
        (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs'),
        (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs')
    )
    $result = New-Object System.Collections.ArrayList
    $shell = $null
    try { $shell = New-Object -ComObject WScript.Shell } catch { }

    foreach ($d in $dirs) {
        if (-not (Test-Directory $d)) { continue }
        $links = @()
        try { $links = @(Get-ChildItem -LiteralPath $d -Filter '*.lnk' -Recurse -Force -ErrorAction SilentlyContinue) } catch { }
        foreach ($l in $links) {
            $target = ''
            if ($shell) {
                try { $target = [string]$shell.CreateShortcut($l.FullName).TargetPath } catch { }
            }
            if ([string]::IsNullOrWhiteSpace($target)) { continue }
            if (-not (Test-Path -LiteralPath $target -PathType Leaf -ErrorAction SilentlyContinue)) { continue }
            if ([System.IO.Path]::GetExtension($target).ToLowerInvariant() -ne '.exe') { continue }
            if ($script:ShortcutTargets.ContainsKey($target)) { continue }
            $script:ShortcutTargets[$target] = $true

            $lower = $target.ToLowerInvariant()
            $inProgramFiles = $false
            foreach ($pf in @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:WINDIR)) {
                if ([string]::IsNullOrWhiteSpace($pf)) { continue }
                if ($lower.StartsWith($pf.ToLowerInvariant())) { $inProgramFiles = $true; break }
            }
            if ($inProgramFiles) { continue }

            $null = $result.Add([pscustomobject]@{
                name   = [System.IO.Path]::GetFileNameWithoutExtension($l.Name)
                target = $target
                folder = [System.IO.Path]::GetDirectoryName($target)
                source = 'shortcut'
            })
        }
    }
    return @($result)
}

# ---------------------------------------------------------------- big data folders

function Get-BigPaths {
    $list = New-Object System.Collections.ArrayList

    $presets = @(
        @{ label = 'Ollama models';      path = (Join-Path $env:USERPROFILE '.ollama\models');        kind = 'local_models' },
        @{ label = 'LM Studio';          path = (Join-Path $env:USERPROFILE '.lmstudio');             kind = 'local_models' },
        @{ label = 'LM Studio cache';    path = (Join-Path $env:USERPROFILE '.cache\lm-studio');      kind = 'local_models' },
        @{ label = 'HuggingFace cache';  path = (Join-Path $env:USERPROFILE '.cache\huggingface');    kind = 'local_models' },
        @{ label = 'ComfyUI';            path = (Join-Path $env:USERPROFILE 'ComfyUI');               kind = 'local_models' },
        @{ label = 'Docker (WSL)';       path = (Join-Path $env:LOCALAPPDATA 'Docker\wsl');           kind = 'vm_disk' },
        @{ label = 'WSL';                path = (Join-Path $env:LOCALAPPDATA 'Packages');             kind = 'vm_disk_scan' }
    )

    foreach ($p in $presets) {
        if ($null -eq $p.path) { continue }
        if (-not (Test-Directory $p.path)) { continue }
        if ($p.kind -eq 'vm_disk_scan') {
            # WSL distros live in LocalState\ext4.vhdx under the distro package folder.
            try {
                $distros = @(Get-ChildItem -LiteralPath $p.path -Directory -Force -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -like 'CanonicalGroupLimited*' -or $_.Name -like '*Ubuntu*' -or $_.Name -like '*Debian*' -or $_.Name -like '*kali*' })
                foreach ($d in $distros) {
                    $localState = Join-Path $d.FullName 'LocalState'
                    if (-not (Test-Directory $localState)) { continue }
                    $vhdx = @(Get-ChildItem -LiteralPath $localState -Filter '*.vhdx' -File -Force -ErrorAction SilentlyContinue)
                    foreach ($v in $vhdx) {
                        $null = $list.Add([pscustomobject]@{
                            label = ('WSL: ' + $d.Name)
                            path  = $v.FullName
                            kind  = 'vm_disk'
                        })
                    }
                }
            } catch { }
            continue
        }
        $null = $list.Add([pscustomobject]@{ label = $p.label; path = $p.path; kind = $p.kind })
    }

    # Steam library
    try {
        $steam = Get-ItemProperty -Path 'HKCU:\Software\Valve\Steam' -ErrorAction SilentlyContinue
        if ($steam -and $steam.SteamPath) {
            $common = Join-Path ([string]$steam.SteamPath) 'steamapps\common'
            if (Test-Directory $common) {
                $null = $list.Add([pscustomobject]@{ label = 'Steam library'; path = $common; kind = 'game_library' })
            }
        }
    } catch { }

    # dedupe by path
    $out = New-Object System.Collections.ArrayList
    $seen = @{}
    foreach ($item in $list) {
        if ($seen.ContainsKey($item.path)) { continue }
        $seen[$item.path] = $true
        $size = [pscustomobject]@{ size_bytes = [int64]0; file_count = 0; truncated = $false }
        if (-not $SkipSizes) {
            try { $size = Get-PathSize -Path $item.path -MaxFiles $MaxFilesPerPath } catch { }
        }
        $null = $out.Add([pscustomobject]@{
            label      = $item.label
            path       = $item.path
            kind       = $item.kind
            size_bytes = $size.size_bytes
            file_count = $size.file_count
            truncated  = $size.truncated
        })
    }
    return @($out)
}

# ---------------------------------------------------------------- machine info

function Get-MachineInfo {
    $osName = 'Windows'
    $displayVersion = ''
    $build = ''
    try {
        $cv = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue
        if ($cv) {
            if ($cv.PSObject.Properties.Name -contains 'ProductName') { $osName = [string]$cv.ProductName }
            if ($cv.PSObject.Properties.Name -contains 'DisplayVersion') { $displayVersion = [string]$cv.DisplayVersion }
            if ($cv.PSObject.Properties.Name -contains 'CurrentBuildNumber') { $build = [string]$cv.CurrentBuildNumber }
        }
    } catch { }

    $arch = 'x64'
    try {
        if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { $arch = 'arm64' }
        elseif ($env:PROCESSOR_ARCHITECTURE -eq 'x86') { $arch = 'x86' }
    } catch { }

    # Windows 11 still reports ProductName = "Windows 10" for compatibility; trust the build number.
    $buildNum = 0
    if (-not [int]::TryParse($build, [ref]$buildNum)) { $buildNum = 0 }
    if ($buildNum -ge 22000) { $osName = 'Windows 11' }
    elseif ($buildNum -gt 0) { $osName = 'Windows 10' }

    $osDisplay = $osName
    if ($displayVersion) { $osDisplay = $osDisplay + ' ' + $displayVersion }
    if ($build) { $osDisplay = $osDisplay + ' (build ' + $build + ')' }

    $user = ''
    try { $user = [string]$env:USERNAME } catch { }

    return [pscustomobject]@{
        os            = $osName
        os_display    = $osDisplay
        os_version    = $displayVersion
        build         = $build
        arch          = $arch
        locale        = [System.Globalization.CultureInfo]::CurrentCulture.Name
        user          = $user
        powershell    = $PSVersionTable.PSVersion.ToString()
        is_admin      = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    }
}

# ---------------------------------------------------------------- main

Write-Host 'windows-migration-skill :: collector' -ForegroundColor Cyan
Write-Host 'Read-only scan. Nothing is installed, changed or deleted.' -ForegroundColor DarkGray

$machine = Get-MachineInfo

Write-Host '  [1/6] registry entries...' -ForegroundColor DarkGray
$registry = @(Get-RegistryApps)

$winget = @()
if (-not $SkipWinget) {
    Write-Host '  [2/6] winget list (names + IDs)...' -ForegroundColor DarkGray
    $winget = @(Get-WingetInstalled)
} else {
    Write-Host '  [2/6] winget skipped' -ForegroundColor DarkGray
}

Write-Host '  [3/6] scoop / choco...' -ForegroundColor DarkGray
$scoop = @(Get-ScoopApps)
$choco = @(Get-ChocoApps)

$store = @()
if (-not $SkipStore) {
    Write-Host '  [4/6] store apps...' -ForegroundColor DarkGray
    $store = @(Get-StoreApps)
} else {
    Write-Host '  [4/6] store apps skipped' -ForegroundColor DarkGray
}

Write-Host '  [5/6] start menu shortcuts...' -ForegroundColor DarkGray
$shortcuts = @(Get-ShortcutApps)

Write-Host '  [6/6] large folders (sizes may take a while)...' -ForegroundColor DarkGray
$bigPaths = @(Get-BigPaths)

$profile = [pscustomobject]@{
    schema_version = '0.1'
    tool           = 'windows-migration-skill'
    platform       = 'windows'
    generated_at   = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    machine        = $machine
    registry       = $registry
    winget         = $winget
    scoop          = $scoop
    choco          = $choco
    store          = $store
    shortcuts      = $shortcuts
    big_paths      = $bigPaths
    warnings       = @($script:Warnings)
}

try {
    $json = $profile | ConvertTo-Json -Depth 8
    $dir = Split-Path -Parent $OutFile
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($OutFile, $json, $enc)
} catch {
    Write-Error ('Failed to write output: ' + $_.Exception.Message)
    exit 1
}

Write-Host ''
Write-Host ('  OK  ' + $registry.Count + ' registry apps, ' + $winget.Count + ' winget packages, ' + $store.Count + ' store apps') -ForegroundColor Green
Write-Host ('      ' + $bigPaths.Count + ' large folders, ' + $shortcuts.Count + ' portable shortcuts') -ForegroundColor Green
Write-Host ('      -> ' + $OutFile) -ForegroundColor Green
Write-Host ''
Write-Host 'Next: hand this file to your agent and ask it to classify and render the report.' -ForegroundColor DarkGray
