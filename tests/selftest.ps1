# Self-test for CI. Runs the real scan on a real Windows machine and checks it
# finishes, writes its files and does not call a normal wired PC a faker.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$tool = Join-Path $root 'HotspotChecker.ps1'
$out  = Join-Path $env:TEMP 'hotspot-selftest'
New-Item -ItemType Directory -Path $out -Force | Out-Null
function Get-Row($Rows, [string]$Name) { return ($Rows | Where-Object { $_.Name -eq $Name } | Select-Object -First 1) }

Write-Host '=== 1. Scan from the file ==='
$json = Join-Path $out 'first.json'
& powershell -NoProfile -ExecutionPolicy Bypass -File $tool -NoGui -Json $json -OutDir $out | Out-Host
if (-not (Test-Path $json)) { throw 'Scan wrote no JSON' }
$rows = Get-Content $json -Raw | ConvertFrom-Json
if (@($rows).Count -ne 7) { throw "Expected 7 rows, got $(@($rows).Count)" }
foreach ($n in 'Gateway', 'Sharing', 'ICS', 'Services', 'Wifi', 'Switches', 'Saved') {
    if ($null -eq (Get-Row $rows $n)) { throw "Row $n is missing" }
}
if (@(Get-ChildItem $out -Filter 'scan_*.txt').Count -lt 1) { throw 'No scan report was written' }

Write-Host '=== 2. A build machine on a normal network must not be flagged ==='
$gw = Get-Row $rows 'Gateway'
if ($gw.Found -notmatch '\d+\.\d+\.\d+\.\d+') { throw "Gateway row found no gateway: '$($gw.Found)'" }
if ($gw.Level -eq 'bad') { throw "Gateway was flagged: $($gw.Result)" }
$sh = Get-Row $rows 'Sharing'
if ($sh.Level -ne 'ok') { throw "Sharing was flagged: $($sh.Result) / $($sh.Found)" }

Write-Host '=== 3. Run from text, the way the one-liner does ==='
$json = Join-Path $out 'oneliner.json'
& powershell -NoProfile -ExecutionPolicy Bypass -Command "& ([scriptblock]::Create((Get-Content -Raw '$tool'))) -NoGui -Json '$json' -OutDir '$out'" | Out-Host
if (-not (Test-Path $json)) { throw 'Running from text wrote no JSON' }
if (@(Get-Content $json -Raw | ConvertFrom-Json).Count -ne 7) { throw 'Running from text returned the wrong number of rows' }

Write-Host 'SELF-TEST PASSED'
