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

Write-Host ''
Write-Host ('  {0} passed, {1} failed' -f $passed, $failed) -ForegroundColor $(if ($failed -eq 0) { 'Green' } else { 'Red' })
Write-Host ''

if ($failed -gt 0) { exit 1 }
