#Requires -Version 5.1
<#
  windows-migration-skill :: classify

  Turns profile.raw.json into profile.json: every installed item gets
  exactly one class (auto / manual / license / excluded / store).

  Deterministic: same input + same rules => identical output (apps are sorted).
  READ-ONLY. Nothing is installed, changed or deleted.

  Usage:
    powershell -NoProfile -File .\scripts\classify.ps1
    powershell -NoProfile -File .\scripts\classify.ps1 -Raw other.raw.json -Out other.json
#>
[CmdletBinding()]
param(
    [string]$Raw = (Join-Path (Get-Location).Path 'profile.raw.json'),
    [string]$Out = (Join-Path (Get-Location).Path 'profile.json'),
    [string]$Rules = (Join-Path $PSScriptRoot '..\rules\classify.json'),
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $Raw)) { throw "raw profile not found: $Raw" }
if (-not (Test-Path -LiteralPath $Rules)) { throw "rules not found: $Rules" }

$rawData = Get-Content -LiteralPath $Raw -Raw -Encoding UTF8 | ConvertFrom-Json
$ruleData = Get-Content -LiteralPath $Rules -Raw -Encoding UTF8 | ConvertFrom-Json

function Get-NormKey([string]$s) {
    if ([string]::IsNullOrWhiteSpace($s)) { return '' }
    $x = $s.ToLowerInvariant()
    $x = $x -replace '\(x64\)|\(x86\)|\(64-bit\)|\(32-bit\)', ''
    $x = $x -replace '\bv?\d+(\.\d+){1,4}\b', ''
    $x = $x -replace '\b(rc|beta|alpha|preview)\d*\b', ''
    $x = $x -replace '[^a-z0-9\u4e00-\u9fff]', ''
    return $x
}

function Find-ExcludeRule([string]$text) {
    foreach ($r in @($ruleData.exclude)) {
        if ($text -match $r.pattern) { return $r }
    }
    return $null
}

function Test-License([string]$text) {
    if ([string]::IsNullOrWhiteSpace($text)) { return $false }
    foreach ($k in @($ruleData.license_keywords)) {
        if ($text -match [regex]::Escape($k)) { return $true }
    }
    return $false
}

$apps = New-Object System.Collections.ArrayList
$seen = @{}

function Add-App($name, $ver, $cls, $reason, $pkg, $hints) {
    $null = $apps.Add([pscustomobject]@{
        name    = $name
        version = $ver
        class   = $cls
        reason  = $reason
        package = $pkg
        hints   = @($hints)
    })
}

# --- registry metadata, keyed by normalized name ---
$regByKey = @{}
foreach ($r in @($rawData.registry)) {
    $k = Get-NormKey $r.name
    if ($k -and -not $regByKey.ContainsKey($k)) { $regByKey[$k] = $r }
}

# --- 1. winget list is the master list ---
foreach ($w in @($rawData.winget)) {
    $name = [string]$w.name
    if ([string]::IsNullOrWhiteSpace($name)) { continue }
    $key = Get-NormKey $name
    if ($key -and $seen.ContainsKey($key)) { continue }
    if ($key) { $seen[$key] = $true }

    $hints = @(); $publisher = ''
    if ($key -and $regByKey.ContainsKey($key)) {
        $hints = @($regByKey[$key].config_hints)
        $publisher = [string]$regByKey[$key].publisher
    }

    if ($w.kind -eq 'msix') { Add-App $name $w.version 'store' 'store' '' $hints; continue }

    $exRule = Find-ExcludeRule $name
    if ($exRule) { Add-App $name $w.version 'excluded' $exRule.reason '' $hints; continue }

    if ((Test-License $name) -or (Test-License $publisher)) {
        $pkg = ''
        if ($w.kind -eq 'package') { $pkg = [string]$w.id }
        Add-App $name $w.version 'license' 'machine_bound' $pkg $hints
        continue
    }

    if ($w.kind -eq 'package') { Add-App $name $w.version 'auto' 'winget' ([string]$w.id) $hints; continue }
    Add-App $name $w.version 'manual' 'needs_installer' '' $hints
}

# --- 2. registry entries that winget list did not report ---
foreach ($r in @($rawData.registry)) {
    $name = [string]$r.name
    if ([string]::IsNullOrWhiteSpace($name)) { continue }
    $key = Get-NormKey $name
    if ($key -and $seen.ContainsKey($key)) { continue }
    if ($key) { $seen[$key] = $true }

    $hints = @($r.config_hints)
    $exRule = Find-ExcludeRule $name
    if ($exRule) { Add-App $name $r.version 'excluded' $exRule.reason '' $hints; continue }

    if ((Test-License $name) -or (Test-License ([string]$r.publisher))) {
        Add-App $name $r.version 'license' 'machine_bound' '' $hints
        continue
    }
    Add-App $name $r.version 'manual' 'unlisted' '' $hints
}

# --- 3. portable apps from start-menu shortcuts ---
foreach ($s in @($rawData.shortcuts)) {
    $name = [string]$s.name
    if ([string]::IsNullOrWhiteSpace($name)) { continue }
    $key = Get-NormKey $name
    if ($key -and $seen.ContainsKey($key)) { continue }
    if ($key) { $seen[$key] = $true }
    Add-App $name '' 'manual' 'portable' '' @($s.folder)
}

# --- stats ---
$sorted = @($apps | Sort-Object -Property @{ Expression = { $_.class } }, @{ Expression = { $_.name } })
$counts = @{}
foreach ($c in @($ruleData.classes)) { $counts[$c] = 0 }
foreach ($a in $sorted) { $counts[$a.class] = $counts[$a.class] + 1 }

$counted = 0
foreach ($c in @($ruleData.counted_classes)) { $counted += $counts[$c] }

$autoSec = [double]$ruleData.estimate_seconds.auto
$manSec = [double]$ruleData.estimate_seconds.manual
$minutes = 0
if ($counted -gt 0) {
    $minutes = [Math]::Ceiling((($counts['auto'] * $autoSec) + ($counts['manual'] * $manSec)) / 60.0 / 5.0) * 5
}

$bigBytes = [int64]0
foreach ($b in @($rawData.big_paths)) { if ($b.size_bytes) { $bigBytes += [int64]$b.size_bytes } }

$stats = [pscustomobject]@{
    counted           = $counted
    auto              = $counts['auto']
    manual            = $counts['manual']
    license           = $counts['license']
    excluded          = $counts['excluded']
    store             = $counts['store']
    auto_ratio        = $(if ($counted -gt 0) { [Math]::Round($counts['auto'] / [double]$counted, 4) } else { 0 })
    estimated_minutes = $minutes
    big_files_bytes   = $bigBytes
}

$doc = [pscustomobject]@{
    schema_version  = '0.1'
    rules_version   = [string]$ruleData.version
    tool            = 'windows-migration-skill'
    platform        = [string]$rawData.platform
    generated_at    = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    machine         = $rawData.machine
    stats           = $stats
    apps            = $sorted
    big_files       = @($rawData.big_paths)
    warnings        = @($rawData.warnings)
}

$json = $doc | ConvertTo-Json -Depth 8
$enc = New-Object System.Text.UTF8Encoding($false)
$dir = Split-Path -Parent $Out
if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
[System.IO.File]::WriteAllText($Out, $json, $enc)

if (-not $Quiet) {
    Write-Host ''
    Write-Host ('  counted={0}  auto={1} ({2:P0})  manual={3}  license={4}' -f `
        $stats.counted, $stats.auto, $stats.auto_ratio, $stats.manual, $stats.license) -ForegroundColor Green
    Write-Host ('  excluded={0}  store={1}  est={2} min  rules=v{3}' -f `
        $stats.excluded, $stats.store, $stats.estimated_minutes, $doc.rules_version) -ForegroundColor DarkGray
    Write-Host ('  -> {0}' -f $Out) -ForegroundColor DarkGray
    Write-Host ''
}
