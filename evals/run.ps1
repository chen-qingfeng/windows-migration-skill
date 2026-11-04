#Requires -Version 5.1
<#
  windows-migration-skill :: evals

  Runs scripts/classify.ps1 against every fixture in evals/cases/ and compares
  the resulting stats with evals/expected/<name>.json.
  Exit code 1 if anything fails, so CI or a pre-commit hook can use it.

  Usage:
    powershell -NoProfile -File .\evals\run.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$classify = Join-Path $root 'scripts\classify.ps1'
$tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) ('wms-eval-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tmpDir | Out-Null

$checks = @('counted', 'auto', 'manual', 'license', 'excluded', 'store')
$passed = 0
$failed = 0

Write-Host ''
Write-Host 'windows-migration-skill :: evals' -ForegroundColor Cyan
Write-Host ''

foreach ($caseFile in (Get-ChildItem -LiteralPath (Join-Path $root 'evals\cases') -Filter '*.json' | Sort-Object Name)) {
    $name = [System.IO.Path]::GetFileNameWithoutExtension($caseFile.Name)
    $expectedFile = Join-Path $root ('evals\expected\' + $name + '.json')
    $outFile = Join-Path $tmpDir ($name + '.out.json')

    if (-not (Test-Path -LiteralPath $expectedFile)) {
        Write-Host ('  SKIP  {0}  (no expected file)' -f $name) -ForegroundColor Yellow
        continue
    }

    try {
        & $classify -Raw $caseFile.FullName -Out $outFile -Quiet
    } catch {
        Write-Host ('  FAIL  {0}  (classify threw: {1})' -f $name, $_.Exception.Message) -ForegroundColor Red
        $failed++
        continue
    }

    $actual = (Get-Content -LiteralPath $outFile -Raw -Encoding UTF8 | ConvertFrom-Json).stats
    $expected = Get-Content -LiteralPath $expectedFile -Raw -Encoding UTF8 | ConvertFrom-Json

    $bad = @()
    foreach ($k in $checks) {
        $e = $expected.$k
        if ($null -eq $e) { continue }
        $a = $actual.$k
        if ($a -ne $e) { $bad += ('{0}: want {1}, got {2}' -f $k, $e, $a) }
    }

    if ($bad.Count -eq 0) {
        Write-Host ('  PASS  {0,-18} counted={1} auto={2} manual={3} license={4} excluded={5} store={6}' -f `
            $name, $actual.counted, $actual.auto, $actual.manual, $actual.license, $actual.excluded, $actual.store) -ForegroundColor Green
        $passed++
    } else {
        Write-Host ('  FAIL  {0}' -f $name) -ForegroundColor Red
        foreach ($b in $bad) { Write-Host ('          {0}' -f $b) -ForegroundColor Red }
        if ($expected.desc) { Write-Host ('          note: {0}' -f $expected.desc) -ForegroundColor DarkGray }
        $failed++
    }
}

Remove-Item -LiteralPath $tmpDir -Recurse -Force -ErrorAction SilentlyContinue

# ---------------------------------------------------------------- pipeline smoke
# raw -> classify -> plan, end to end, using the shipped example.

Write-Host ''
Write-Host '  pipeline: raw -> classify -> plan' -ForegroundColor Cyan

$pipeDir = Join-Path ([System.IO.Path]::GetTempPath()) ('wms-pipe-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $pipeDir | Out-Null
$smokeOk = $true

try {
    $exampleRaw = Join-Path $root 'examples\raw.windows.example.json'
    $pipeProfile = Join-Path $pipeDir 'profile.json'

    & (Join-Path $root 'scripts\classify.ps1') -Raw $exampleRaw -Out $pipeProfile -Quiet
    & (Join-Path $root 'scripts\plan.ps1') -Profile $pipeProfile -OutDir $pipeDir -SkipInstalledCheck -Quiet

    $mdFile = Join-Path $pipeDir 'restore.md'
    $psFile = Join-Path $pipeDir 'restore.ps1'

    if (-not (Test-Path -LiteralPath $mdFile)) { Write-Host '          restore.md missing' -ForegroundColor Red; $smokeOk = $false }
    if (-not (Test-Path -LiteralPath $psFile)) { Write-Host '          restore.ps1 missing' -ForegroundColor Red; $smokeOk = $false }

    if ($smokeOk) {
        $md = Get-Content -LiteralPath $mdFile -Raw -Encoding UTF8
        if ($md -notmatch '一条命令能装回来（3）') { Write-Host '          expected 3 auto items in plan' -ForegroundColor Red; $smokeOk = $false }
        if ($md -notmatch '需要你手动处理（3）') { Write-Host '          expected 3 manual items in plan' -ForegroundColor Red; $smokeOk = $false }

        $generated = Get-Content -LiteralPath $psFile -Raw -Encoding UTF8
        if ($generated -notmatch '-Apply') { Write-Host '          restore.ps1 lost its -Apply gate' -ForegroundColor Red; $smokeOk = $false }

        $parseErrors = $null; $tokens = $null
        $null = [System.Management.Automation.Language.Parser]::ParseFile($psFile, [ref]$tokens, [ref]$parseErrors)
        if ($parseErrors -and $parseErrors.Count -gt 0) {
            Write-Host ('          generated script does not parse: {0}' -f $parseErrors[0].Message) -ForegroundColor Red
            $smokeOk = $false
        }
    }
} catch {
    Write-Host ('          pipeline threw: {0}' -f $_.Exception.Message) -ForegroundColor Red
    $smokeOk = $false
}

Remove-Item -LiteralPath $pipeDir -Recurse -Force -ErrorAction SilentlyContinue

if ($smokeOk) {
    Write-Host '  PASS  pipeline          classify + plan produce a parsable script' -ForegroundColor Green
    $passed++
} else {
    Write-Host '  FAIL  pipeline' -ForegroundColor Red
    $failed++
}

Write-Host ''
Write-Host ('  {0} passed, {1} failed' -f $passed, $failed) -ForegroundColor $(if ($failed -eq 0) { 'Green' } else { 'Red' })
Write-Host ''

if ($failed -gt 0) { exit 1 }
