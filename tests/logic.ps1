# Logic test. Loads the check functions out of HotspotChecker.ps1, swaps the
# parts that read the PC for fake data, and checks each setup gets the right
# result. Runs on Windows PowerShell 5.1 and on PowerShell 7, no admin needed.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$tool = Join-Path $root 'HotspotChecker.ps1'

$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($tool, [ref]$null, [ref]$errors)
if ($errors) { $errors | ForEach-Object { Write-Host $_ }; throw 'Syntax errors found' }

# Settings at the top of the script, then every function in it.
foreach ($st in $ast.EndBlock.Statements) {
    if ($st -is [System.Management.Automation.Language.AssignmentStatementAst] -and
        $st.Left.Extent.Text -in '$HotspotNamePatterns', '$RecentSwitchMinutes') { . ([scriptblock]::Create($st.Extent.Text)) }
    if ($st -is [System.Management.Automation.Language.FunctionDefinitionAst]) { . ([scriptblock]::Create($st.Extent.Text)) }
}
$OutDir = Join-Path ([System.IO.Path]::GetTempPath()) 'hotspot-logic-test'

$script:Fails = 0
function Check([string]$What, $Got, $Want) {
    if ([string]$Got -eq [string]$Want) { Write-Host ('  ok    ' + $What) }
    else { Write-Host ('  FAIL  ' + $What + ': got "' + $Got + '", wanted "' + $Want + '"'); $script:Fails++ }
}
function Row($Scan, [string]$Name) { return ($Scan.Rows | Where-Object { $_.Name -eq $Name } | Select-Object -First 1) }

# Fake PC. Each test changes $Fake and scans again.
function Reset-Fake {
    $script:Fake = @{
        Configs  = @([pscustomobject]@{ Description = 'Intel Ethernet'; IPs = @('192.168.1.50'); Gateways = @('192.168.1.1') })
        Wifi     = @{ Ssid = ''; LocalMac = $false; Blocked = $false }
        Hotspot  = @{ Known = $true; On = $false; Clients = 0 }
        Clients  = 0
        Ics      = @()
        Services = @()
        Saved    = @()
        Events   = @()
        Boot     = (Get-Date).AddHours(-5)
    }
}
function Get-BootTime           { return $script:Fake.Boot }
function Get-AdapterConfigs     { return $script:Fake.Configs }
function Get-WifiInterface      { return $script:Fake.Wifi }
function Get-MobileHotspot      { return $script:Fake.Hotspot }
function Get-SharedClientCount  { return $script:Fake.Clients }
function Get-IcsShares          { if ($null -eq $script:Fake.Ics) { return $null }; return , $script:Fake.Ics }
function Get-SharingServices    { return $script:Fake.Services }
function Get-SavedHotspotProfiles { return $script:Fake.Saved }
function Get-NetworkEvents($Boot) { return $script:Fake.Events }
function Ev([double]$MinutesAgo, [string]$What, [string]$Name) {
    return [pscustomobject]@{ Time = (Get-Date).AddMinutes(-$MinutesAgo); What = $What; Name = $Name; Source = 'network' }
}

Write-Host '1. Normal home PC on a router'
Reset-Fake
$Fake.Events = @((Ev 299 'connected' 'Network'))
$s = Get-AllRows
Check 'seven rows' @($s.Rows).Count 7
foreach ($r in $s.Rows) { Check ($r.Name + ' is clean') $r.Level 'ok' }

Write-Host '2. Connected through another Windows PC'
Reset-Fake
$Fake.Configs = @([pscustomobject]@{ Description = 'Intel Wi-Fi'; IPs = @('192.168.137.52'); Gateways = @('192.168.137.1') })
$Fake.Wifi = @{ Ssid = 'DESKTOP-AB12CDE 4821'; LocalMac = $true; Blocked = $false }
$s = Get-AllRows
Check 'gateway result' (Row $s 'Gateway').Result 'THROUGH ANOTHER PC'
Check 'gateway level'  (Row $s 'Gateway').Level 'bad'
Check 'wifi result'    (Row $s 'Wifi').Result 'LOOKS LIKE A HOTSPOT'
Check 'not flagged as the one sharing' (Row $s 'Sharing').Level 'ok'

Write-Host '3. This PC hosts a hotspot with one device on it'
Reset-Fake
$Fake.Configs += [pscustomobject]@{ Description = 'Microsoft Wi-Fi Direct Virtual Adapter #2'; IPs = @('192.168.137.1'); Gateways = @() }
$Fake.Hotspot = @{ Known = $true; On = $true; Clients = 1 }
$Fake.Services = @('icssvc (process started 2026-01-01 10:00:00)')
$s = Get-AllRows
Check 'sharing result'  (Row $s 'Sharing').Result 'SHARING, DEVICE CONNECTED'
Check 'sharing level'   (Row $s 'Sharing').Level 'bad'
Check 'services result' (Row $s 'Services').Result 'RUNNING'
Check 'gateway stays clean' (Row $s 'Gateway').Level 'ok'

Write-Host '4. Hotspot on, nothing connected'
$Fake.Hotspot = @{ Known = $true; On = $true; Clients = 0 }
$s = Get-AllRows
Check 'sharing result' (Row $s 'Sharing').Result 'SHARING'
Check 'sharing level'  (Row $s 'Sharing').Level 'warn'

Write-Host '5. Phone hotspots and tethering'
foreach ($case in @(@('192.168.43.1', 'Android phone'), @('172.20.10.1', 'iPhone'), @('192.168.42.129', 'USB tethering'))) {
    Reset-Fake
    $Fake.Configs = @([pscustomobject]@{ Description = 'Adapter'; IPs = @('10.0.0.2'); Gateways = @($case[0]) })
    $s = Get-AllRows
    Check ($case[0] + ' result') (Row $s 'Gateway').Result 'HOTSPOT'
    Check ($case[0] + ' names the device') ((Row $s 'Gateway').Detail -like ('*' + $case[1] + '*')) 'True'
}

Write-Host '5b. 192.168.2.x gateway is a note, not a flag'
Reset-Fake
$Fake.Configs = @([pscustomobject]@{ Description = 'Adapter'; IPs = @('192.168.2.40'); Gateways = @('192.168.2.1') })
$s = Get-AllRows
Check 'result' (Row $s 'Gateway').Result 'POSSIBLE MAC SHARING'
Check 'level'  (Row $s 'Gateway').Level 'note'

Write-Host '6. Internet Connection Sharing over a cable'
Reset-Fake
$Fake.Ics = @('Wi-Fi (shared out)', 'Ethernet 2 (receives the shared connection)')
$Fake.Services = @('SharedAccess (process started 2026-01-01 10:00:00)')
$s = Get-AllRows
Check 'ics result' (Row $s 'ICS').Result 'ENABLED'
Reset-Fake
$Fake.Ics = $null
$s = Get-AllRows
Check 'ics unreadable is a note, not a flag' (Row $s 'ICS').Level 'note'

Write-Host '7. Switched networks right before the screenshare'
Reset-Fake
$Fake.Events = @((Ev 290 'connected' 'HomeWifi'), (Ev 6 'disconnected' 'HomeWifi'), (Ev 5 'connected' "Liam's iPhone"))
$s = Get-AllRows
$sw = Row $s 'Switches'
Check 'switch result' $sw.Result 'CHANGED'
Check 'counts two networks' ($sw.Detail -like '*2 different networks*') 'True'
Check 'says how recent'     ($sw.Detail -like '*5 minute*') 'True'
Check 'names the hotspot'   ($sw.Detail -like "*Liam's iPhone*") 'True'

Write-Host '8. Connecting once at boot is not a switch'
Reset-Fake
$Fake.Boot = (Get-Date).AddMinutes(-8)
$Fake.Events = @((Ev 7 'connected' 'HomeWifi'))
$s = Get-AllRows
Check 'fresh boot stays clean' (Row $s 'Switches').Level 'ok'

Write-Host '9. Saved hotspot networks are only a note'
Reset-Fake
$Fake.Saved = @('Galaxy S23')
$s = Get-AllRows
Check 'saved level' (Row $s 'Saved').Level 'note'

Write-Host '10. Wi-Fi details hidden by Windows'
Reset-Fake
$Fake.Wifi = @{ Ssid = ''; LocalMac = $false; Blocked = $true }
$s = Get-AllRows
Check 'wifi hidden is a note' (Row $s 'Wifi').Level 'note'

Write-Host '11. Name matching'
foreach ($n in "John's iPhone", 'Galaxy A54 5G', 'AndroidAP_1234', 'DIRECT-xy-HP OfficeJet', 'DESKTOP-9K2LM4P 7731', 'Pixel 8', 'moto g54') { Check ('hotspot name: ' + $n) (Test-HotspotName $n) 'True' }
foreach ($n in 'NETGEAR-5G', 'Vivo Fibra 2.4', 'Xfinity', 'TP-Link_A1B2', 'eduroam', 'PixelPerfect Studio', 'Motown Cafe') { Check ('router name: ' + $n) (Test-HotspotName $n) 'False' }
Check 'made-up address' (Test-LocalMac 'a6:91:b1:00:11:22') 'True'
Check 'real address'    (Test-LocalMac '3c:84:6a:00:11:22') 'False'

Write-Host '12. Report'
Reset-Fake
$path = Save-Report (Get-AllRows)
Check 'report written' (Test-Path $path) 'True'

if ($script:Fails -gt 0) { throw "$($script:Fails) check(s) failed" }
Write-Host 'LOGIC TEST PASSED'
