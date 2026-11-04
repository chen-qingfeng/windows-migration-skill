#Requires -Version 5.1
<#
  windows-migration-skill :: plan

  Reads profile.json (produced by scripts/classify.ps1) and writes two files:

    restore.md    human-readable plan: what installs with one command,
                  what needs manual work, what is license-restricted
    restore.ps1   an executable script that installs the `auto` set

  restore.ps1 is DRY-RUN by default. Nothing is installed unless you pass -Apply.

  Usage:
    powershell -NoProfile -File .\scripts\plan.ps1
    powershell -NoProfile -File .\scripts\plan.ps1 -Profile ..\old-pc\profile.json -OutDir .\plan
#>
[CmdletBinding()]
param(
    [string]$Profile = (Join-Path (Get-Location).Path 'profile.json'),
    [string]$OutDir = (Get-Location).Path,
    [switch]$SkipInstalledCheck,
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $Profile)) { throw "profile not found: $Profile" }
$doc = Get-Content -LiteralPath $Profile -Raw -Encoding UTF8 | ConvertFrom-Json

if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Force -Path $OutDir | Out-Null }

# ---------------------------------------------------------------- target machine

function Get-TargetFacts {
    $arch = 'x64'
    try {
        if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { $arch = 'arm64' }
        elseif ($env:PROCESSOR_ARCHITECTURE -eq 'x86') { $arch = 'x86' }
    } catch { }

    $freeGb = 0
    try {
        $di = New-Object System.IO.DriveInfo($env:SystemDrive)
        $freeGb = [Math]::Round($di.AvailableFreeSpace / 1GB, 1)
    } catch { }

    $wingetOk = $false
    if (Get-Command winget -ErrorAction SilentlyContinue) { $wingetOk = $true }

    return [pscustomobject]@{
        arch      = $arch
        free_gb   = $freeGb
        winget_ok = $wingetOk
    }
}

function Get-InstalledIds {
    $ids = @{}
    if ($SkipInstalledCheck) { return $ids }
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) { return $ids }

    $pkgShape = '^[A-Za-z][A-Za-z0-9._\-]*\.[A-Za-z0-9][A-Za-z0-9._\-+]*$'
    $verShape = '^\d+(\.\d+)*$'
    try {
        foreach ($line in @(& winget list --disable-interactivity --accept-source-agreements 2>$null)) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            foreach ($part in @($line -split '\s{2,}')) {
                $p = $part.Trim()
                if ([string]::IsNullOrWhiteSpace($p)) { continue }
                if ($p -match $pkgShape -and $p -notmatch $verShape) { $ids[$p] = $true }
                elseif ($p -match '^(MSIX\\|ARP\\)') { $ids[$p] = $true }
            }
        }
    } catch { }
    return $ids
}

$target = Get-TargetFacts
$installed = Get-InstalledIds

# ---------------------------------------------------------------- split the plan

$auto  = @($doc.apps | Where-Object { $_.class -eq 'auto' })
$man   = @($doc.apps | Where-Object { $_.class -eq 'manual' })
$lic   = @($doc.apps | Where-Object { $_.class -eq 'license' })
$big   = @($doc.big_files | Where-Object { $_.size_bytes -gt 0 })

$toInstall = New-Object System.Collections.ArrayList
$already   = New-Object System.Collections.ArrayList
foreach ($a in $auto) {
    $pkg = [string]$a.package
    if ($pkg -and $installed.ContainsKey($pkg)) { $null = $already.Add($a) }
    else { $null = $toInstall.Add($a) }
}

$toInstall = @($toInstall | Sort-Object -Property name)
$man = @($man | Sort-Object -Property @{ Expression = { $_.reason } }, @{ Expression = { $_.name } })
$lic = @($lic | Sort-Object -Property name)
$big = @($big | Sort-Object -Property @{ Expression = { $_.size_bytes }; Descending = $true })

$bigGb = 0
foreach ($b in $big) { $bigGb += [double]$b.size_bytes }
$bigGb = [Math]::Round($bigGb / 1GB, 1)

$srcArch = ''
if ($doc.machine -and $doc.machine.arch) { $srcArch = [string]$doc.machine.arch }
$srcOs = ''
if ($doc.machine -and $doc.machine.os_display) { $srcOs = [string]$doc.machine.os_display }
elseif ($doc.machine -and $doc.machine.os) { $srcOs = [string]$doc.machine.os }

# ---------------------------------------------------------------- restore.md

function Esc-Md([string]$s) { return ($s -replace '\|', '\|') }

$md = New-Object System.Collections.ArrayList
function L([string]$line) { $null = $md.Add($line) }

L '# 还原计划'
L ''
L ('**源机器：{0}**　｜　生成于 {1}　｜　规则 v{2}' -f $srcOs, (Get-Date -Format 'yyyy-MM-dd HH:mm'), $doc.rules_version)
L ''
L '> 由 windows-migration-skill 生成 ｜ 本文件只是计划，没有执行任何操作'
L ''
L '---'
L ''
L '## 摘要'
L ''
L ('- **{0}** 个应用可以一条命令装回来' -f $toInstall.Count)
if ($already.Count -gt 0) { L ('- **{0}** 个已经装好，跳过' -f $already.Count) }
L ('- **{0}** 个需要你手动处理' -f $man.Count)
L ('- **{0}** 个受许可限制' -f $lic.Count)
if ($big.Count -gt 0) { L ('- **{0} GB** 大文件需要单独搬运' -f $bigGb) }
L ''
L '---'
L ''
L ('## 一、一条命令能装回来（{0}）' -f $toInstall.Count)
L ''
if ($toInstall.Count -eq 0) {
    L '没有可自动安装的项目。'
} else {
    L '| 软件 | 版本 | 包 ID |'
    L '|---|---:|---|'
    foreach ($a in $toInstall) { L ('| {0} | {1} | `{2}` |' -f (Esc-Md $a.name), $a.version, $a.package) }
}
L ''
if ($already.Count -gt 0) {
    L ('### 已经装好的（{0}）' -f $already.Count)
    L ''
    foreach ($a in $already) { L ('- {0}' -f $a.name) }
    L ''
}
L '---'
L ''
L ('## 二、需要你手动处理（{0}）' -f $man.Count)
L ''
if ($man.Count -eq 0) {
    L '没有需要手动处理的项目。'
} else {
    L '| 软件 | 原因 | 怎么办 |'
    L '|---|---|---|'
    foreach ($a in $man) {
        $why = '需要原始安装包'
        $how = '找到旧机器上的安装器，或去官网下载'
        switch ($a.reason) {
            'needs_installer' { $why = 'winget 里没有这个包'; $how = '用原始安装包，或去官网下载' }
            'unlisted'        { $why = '没有安装记录，可能是绿色版'; $how = '直接复制它的目录' }
            'portable'        { $why = '绿色版，没有安装过程'; $how = '复制整个目录即可' }
            'store_app'       { $why = '商店应用'; $how = '从 Microsoft Store 重新安装' }
            'app_bundle'      { $why = '没有对应的包管理器条目'; $how = '去官网或 App Store 重新下载' }
        }
        L ('| {0} | {1} | {2} |' -f (Esc-Md $a.name), $why, $how)
    }
}
L ''
L '---'
L ''
L ('## 三、受许可限制（{0}）' -f $lic.Count)
L ''
if ($lic.Count -eq 0) {
    L '没有受许可限制的项目。'
} else {
    L '这些装得上，但可能激活不了。**先在旧机器上反激活 / 解绑，再在新机器激活。**'
    L ''
    L '| 软件 | 建议 |'
    L '|---|---|'
    foreach ($a in $lic) {
        $tip = '查官方的设备管理页，先移除旧设备'
        L ('| {0} | {1} |' -f (Esc-Md $a.name), $tip)
    }
}
L ''
L '---'
L ''
L ('## 四、大文件（{0} 项，共 {1} GB）' -f $big.Count, $bigGb)
L ''
if ($big.Count -eq 0) {
    L '没有需要单独搬运的大文件。'
} else {
    L '| 内容 | 大小 | 路径 |'
    L '|---|---:|---|'
    foreach ($b in $big) {
        $gb = [Math]::Round([double]$b.size_bytes / 1GB, 1)
        L ('| {0} | {1} GB | `{2}` |' -f (Esc-Md ([string]$b.label)), $gb, [string]$b.path)
    }
}
L ''
L '---'
L ''
L '## 五、目标机器检查'
L ''
L ('| 检查项 | 结果 |')
L '|---|---|'
if ($srcArch -and $target.arch -ne $srcArch) {
    L ('| 架构 | ⚠️ 源机器 {0}，本机 {1} —— 部分应用可能没有对应版本 |' -f $srcArch, $target.arch)
} else {
    L ('| 架构 | ✅ {0}，与源机器一致 |' -f $target.arch)
}
if ($bigGb -gt 0 -and $target.free_gb -gt 0) {
    if ($target.free_gb -lt $bigGb) {
        L ('| 磁盘 | ⚠️ 剩余 {0} GB，大文件需要 {1} GB |' -f $target.free_gb, $bigGb)
    } else {
        L ('| 磁盘 | ✅ 剩余 {0} GB，大文件需要 {1} GB |' -f $target.free_gb, $bigGb)
    }
} elseif ($target.free_gb -gt 0) {
    L ('| 磁盘 | 剩余 {0} GB |' -f $target.free_gb)
}
if ($target.winget_ok) { L '| winget | ✅ 可用 |' } else { L '| winget | ⚠️ 不可用，自动安装会全部失败 |' }
L ''
L '---'
L ''
L '## 六、怎么执行'
L ''
L '```powershell'
L '# 先预览（默认行为，不会改动任何东西）'
L '.\restore.ps1'
L ''
L '# 确认没问题后再真装'
L '.\restore.ps1 -Apply'
L '```'
L ''
L '> `-Apply` 之前，本脚本不会安装任何东西。'
L ''

$mdText = ($md -join "`n")
$enc = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText((Join-Path $OutDir 'restore.md'), $mdText, $enc)

# ---------------------------------------------------------------- restore.ps1

function Q([string]$s) { return ("'" + ($s -replace "'", "''") + "'") }

$ps = New-Object System.Collections.ArrayList
function P([string]$line) { $null = $ps.Add($line) }

P '#Requires -Version 5.1'
P '<#'
P ('  Generated by windows-migration-skill v0.3')
P ('  Source machine: {0}' -f ($srcOs -replace '[\r\n]', ' '))
P ('  Generated at:   {0}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm'))
P ('  Items:          {0} packages' -f $toInstall.Count)
P ''
P '  DRY-RUN BY DEFAULT. Nothing is installed unless you pass -Apply.'
P '#>'
P '[CmdletBinding()]'
P 'param([switch]$Apply)'
P ''
P '$ErrorActionPreference = ''Continue'''
P ''
P ('$packages = @(')
foreach ($a in $toInstall) {
    P ('    [pscustomobject]@{{ name = {0}; id = {1} }}' -f (Q ([string]$a.name)), (Q ([string]$a.package)))
}
P ')'
P ''
P '$ok = 0'
P '$failed = 0'
P ''
P 'if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {'
P '    Write-Host ''winget not found - nothing to do here.'' -ForegroundColor Red'
P '    exit 1'
P '}'
P ''
P 'if (-not $Apply) {'
P '    Write-Host '''''
P '    Write-Host ''DRY RUN - no changes will be made.'' -ForegroundColor Yellow'
P '    Write-Host ''Pass -Apply to actually install.'' -ForegroundColor Yellow'
P '    Write-Host '''''
P '}'
P ''
P ('Write-Host (''Plan: {0} packages'' ) -ForegroundColor Cyan' -f $toInstall.Count)
P ''
P 'foreach ($p in $packages) {'
P '    if ($Apply) {'
P '        Write-Host (''  installing {0} ...'' -f $p.name) -ForegroundColor DarkGray'
P '        $wingetArgs = @(''install'', ''--id'', $p.id, ''--exact'', ''--silent'','
P '            ''--accept-package-agreements'', ''--accept-source-agreements'', ''--disable-interactivity'')'
P '        & winget @wingetArgs'
P '        if ($LASTEXITCODE -eq 0) { $ok++ } else { $failed++; Write-Host (''    failed: {0}'' -f $p.id) -ForegroundColor Red }'
P '    } else {'
P '        Write-Host (''  would install  {0,-40} {1}'' -f $p.name, $p.id)'
P '    }'
P '}'
P ''
P 'if ($Apply) {'
P '    Write-Host '''''
P '    Write-Host (''Done: {0} ok, {1} failed'' -f $ok, $failed) -ForegroundColor $(if ($failed -eq 0) { ''Green'' } else { ''Yellow'' })'
P '    Write-Host ''Now open restore.md and work through the manual list.'' -ForegroundColor DarkGray'
P '}'
P ''

$psText = ($ps -join "`r`n")
[System.IO.File]::WriteAllText((Join-Path $OutDir 'restore.ps1'), $psText, $enc)

# ---------------------------------------------------------------- console

if (-not $Quiet) {
    Write-Host ''
    Write-Host ('  to install : {0}   already present: {1}' -f $toInstall.Count, $already.Count) -ForegroundColor Green
    Write-Host ('  manual     : {0}   license: {1}   big files: {2} GB' -f $man.Count, $lic.Count, $bigGb) -ForegroundColor DarkGray
    Write-Host ('  -> {0}' -f (Join-Path $OutDir 'restore.md')) -ForegroundColor DarkGray
    Write-Host ('  -> {0}' -f (Join-Path $OutDir 'restore.ps1')) -ForegroundColor DarkGray
    Write-Host ''
}
