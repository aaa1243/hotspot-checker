<#
    HotspotChecker.ps1
    ------------------
    Screenshare helper for catching "fakers": players who get screenshared on a
    clean PC while the PC they actually played on sits next to it. To keep the
    same IP as the game, the two PCs share one internet connection, usually
    through a Windows Mobile Hotspot, Internet Connection Sharing or a phone.
    This tool looks at how this PC is connected and whether it is sharing.

    - Read-only. It changes nothing on the PC.
    - It does not show the public IP, MAC addresses or the full list of saved
      Wi-Fi networks. Only the current network, networks used since boot, and
      saved networks whose names look like a hotspot.
    - Windows PowerShell 5.1, WinForms only, no external modules.
    - Compile with:  Invoke-ps2exe .\HotspotChecker.ps1 .\HotspotChecker.exe -noConsole -requireAdmin
    - Mac version: hotspot-checker-mac.sh in the same repo.

    Run it straight from GitHub without downloading anything (admin CMD or PowerShell):
      powershell -ExecutionPolicy Bypass -Command "iex (irm https://raw.githubusercontent.com/aaa1243/hotspot-checker/main/HotspotChecker.ps1)"
    Same, but as text in the console instead of a window:
      powershell -ExecutionPolicy Bypass -Command "& ([scriptblock]::Create((irm https://raw.githubusercontent.com/aaa1243/hotspot-checker/main/HotspotChecker.ps1))) -NoGui"
#>
param(
    [switch]$NoGui,
    [string]$Json = '',
    [string]$OutDir = 'C:\SSTools\HotspotChecker'
)

$ErrorActionPreference = 'Continue'

# Network names that look like a phone or PC hotspot (regex, not case sensitive).
$HotspotNamePatterns = @(
    'iphone', 'ipad', 'android', 'galaxy', 'pixel \d', 'oneplus', 'xiaomi', 'redmi', 'huawei', 'poco [a-z]\d',
    'realme', 'motorola', 'moto [a-z]\d', 'hotspot', 'tether', "'s phone", '^DIRECT-', '^SM-[A-Z0-9]', '^GT-[A-Z0-9]',
    '^(DESKTOP|LAPTOP)-[A-Z0-9]{5,8}( \d{4})?$'
)

# A network change this many minutes before the scan counts as "right before the SS".
$RecentSwitchMinutes = 30

# =============================================================================
#  CHECK LOGIC  (no window code in this part)
# =============================================================================
function Test-IsAdmin {
    try {
        $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        $p  = New-Object System.Security.Principal.WindowsPrincipal($id)
        return $p.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}

function Get-BootTime {
    try { return (Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime }
    catch { return (Get-Date).AddMilliseconds(-[Environment]::TickCount) }
}

function Format-Time($t) {
    if ($null -eq $t) { return '' }
    return ([datetime]$t).ToString('yyyy-MM-dd HH:mm:ss')
}

function Test-HotspotName([string]$Name) {
    if (-not $Name) { return $false }
    foreach ($p in $HotspotNamePatterns) { if ($Name -match $p) { return $true } }
    return $false
}

function Get-GatewayKind([string]$Gateway) {
    # What kind of device hands out this gateway address by default. '' when it is an ordinary router range.
    if ($Gateway -like '192.168.137.*') { return 'a Windows PC sharing its connection (Mobile Hotspot or Internet Connection Sharing)' }
    if ($Gateway -like '192.168.43.*')  { return 'an Android phone hotspot' }
    if ($Gateway -like '172.20.10.*')   { return 'an iPhone hotspot' }
    if ($Gateway -like '192.168.42.*')  { return 'Android USB tethering' }
    if ($Gateway -like '192.168.44.*')  { return 'Android Bluetooth tethering' }
    if ($Gateway -like '192.168.49.*')  { return 'a Wi-Fi Direct group (phone or PC)' }
    return ''
}

function Test-LocalMac([string]$Mac) {
    # Second hex digit 2, 6, A or E means a made-up (locally administered) address, which hotspots use.
    if (-not $Mac -or $Mac.Length -lt 2) { return $false }
    return ($Mac.Substring(1, 1) -match '[26AaEe]')
}

function New-Row([string]$Name, [string]$Display, [string]$What) {
    return [ordered]@{ Name = $Name; Display = $Display; What = $What; Found = ''; Result = 'OK'; Level = 'ok'; Detail = '' }
}

function Get-AdapterConfigs {
    $list = @()
    try {
        foreach ($a in (Get-CimInstance Win32_NetworkAdapterConfiguration -Filter 'IPEnabled=TRUE' -ErrorAction Stop)) {
            $ips = @(); $gws = @()
            foreach ($ip in @($a.IPAddress)) { if ($ip -and $ip -match '^\d+\.\d+\.\d+\.\d+$') { $ips += $ip } }
            foreach ($g in @($a.DefaultIPGateway)) { if ($g -and $g -match '^\d+\.\d+\.\d+\.\d+$') { $gws += $g } }
            $list += [pscustomobject]@{ Description = [string]$a.Description; IPs = $ips; Gateways = $gws }
        }
    } catch { }
    return $list
}

function Get-WifiInterface {
    # Current Wi-Fi network from "netsh wlan show interfaces". SSID and BSSID labels are the same in every language.
    $info = @{ Ssid = ''; LocalMac = $false; Blocked = $false }
    try {
        $out = & netsh.exe wlan show interfaces 2>&1
        foreach ($line in $out) {
            $t = [string]$line
            if ($t -match '^\s*SSID\s*:\s*(.+)$') { $info.Ssid = $Matches[1].Trim() }
            if ($t -match '^\s*BSSID\s*:\s*([0-9A-Fa-f:]{17})') { $info.LocalMac = (Test-LocalMac $Matches[1]) }
            if ($t -match 'ms-settings:privacy-location') { $info.Blocked = $true }
        }
    } catch { }
    if (-not $info.Ssid) {
        # Newer Windows 11 hides Wi-Fi details from netsh while Location is off. The network profile name still works.
        try {
            foreach ($p in (Get-NetConnectionProfile -ErrorAction Stop)) {
                if ([string]$p.InterfaceAlias -match 'Wi-?Fi|WLAN|Wireless') { $info.Ssid = [string]$p.Name }
            }
        } catch { }
    }
    return $info
}

function Get-MobileHotspot {
    # Asks Windows directly whether Mobile Hotspot is on and how many devices are on it.
    $info = @{ Known = $false; On = $false; Clients = 0 }
    try {
        [void][Windows.Networking.Connectivity.NetworkInformation, Windows.Networking.Connectivity, ContentType = WindowsRuntime]
        [void][Windows.Networking.NetworkOperators.NetworkOperatorTetheringManager, Windows.Networking.NetworkOperators, ContentType = WindowsRuntime]
        $conn = [Windows.Networking.Connectivity.NetworkInformation]::GetInternetConnectionProfile()
        if ($null -ne $conn) {
            $mgr = [Windows.Networking.NetworkOperators.NetworkOperatorTetheringManager]::CreateFromConnectionProfile($conn)
            $info.On      = ([string]$mgr.TetheringOperationalState -eq 'On')
            $info.Clients = [int]$mgr.ClientCount
            $info.Known   = $true
        }
    } catch { }
    return $info
}

function Get-SharedClientCount {
    # Devices this PC has talked to on its own shared network (192.168.137.x). Only the count is used.
    $clients = @()
    try {
        foreach ($n in (Get-NetNeighbor -AddressFamily IPv4 -ErrorAction Stop)) {
            $ip = [string]$n.IPAddress
            if ($ip -like '192.168.137.*' -and $ip -ne '192.168.137.1' -and $ip -ne '192.168.137.255' -and
                @('Reachable', 'Stale', 'Delay', 'Probe') -contains [string]$n.State) { $clients += $ip }
        }
    } catch { }
    return @($clients | Select-Object -Unique).Count
}

function Get-IcsShares {
    # Adapters with Internet Connection Sharing switched on. $null when it could not be read.
    $shared = @()
    try {
        $mgr = New-Object -ComObject HNetCfg.HNetShare -ErrorAction Stop
        foreach ($conn in $mgr.EnumEveryConnection) {
            $cfg   = $mgr.INetSharingConfigurationForINetConnection.Invoke($conn)
            $props = $mgr.NetConnectionProps.Invoke($conn)
            if ($cfg.SharingEnabled) {
                $role = 'shared out'
                if ($cfg.SharingConnectionType -eq 1) { $role = 'receives the shared connection' }
                $shared += ('{0} ({1})' -f $props.Name, $role)
            }
        }
    } catch { return $null }
    return , $shared
}

function Get-SharingServices {
    $running = @()
    foreach ($s in @('icssvc', 'SharedAccess')) {
        try {
            $svc = Get-CimInstance Win32_Service -Filter ("Name='" + $s + "'") -ErrorAction Stop
            if ($null -ne $svc -and $svc.State -eq 'Running') {
                $started = 'unknown'
                try { $started = Format-Time ([System.Diagnostics.Process]::GetProcessById([int]$svc.ProcessId).StartTime) } catch { }
                $running += ('{0} (process started {1})' -f $s, $started)
            }
        } catch { }
    }
    return $running
}

function Get-SavedHotspotProfiles {
    $names = @()
    try {
        $out = & netsh.exe wlan show profiles 2>&1
        foreach ($line in $out) {
            $t = [string]$line
            if ($t -match '^\s+.+\s:\s(.+)$') {
                $n = $Matches[1].Trim()
                if ($n -and (Test-HotspotName $n) -and ($names -notcontains $n)) { $names += $n }
            }
        }
    } catch { }
    return $names
}

function Get-NetworkEvents($Boot) {
    # Connect and disconnect events since boot, oldest first.
    $list = @()
    try {
        $ev = Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-NetworkProfile/Operational'; Id = 10000, 10001; StartTime = $Boot } -MaxEvents 400 -ErrorAction Stop
        foreach ($e in $ev) {
            $name = ''
            try { $name = [string]$e.Properties[0].Value } catch { }
            $what = 'connected'
            if ($e.Id -eq 10001) { $what = 'disconnected' }
            $list += [pscustomobject]@{ Time = $e.TimeCreated; What = $what; Name = $name; Source = 'network' }
        }
    } catch { }
    try {
        $ev = Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-WLAN-AutoConfig/Operational'; Id = 8001, 8003; StartTime = $Boot } -MaxEvents 400 -ErrorAction Stop
        foreach ($e in $ev) {
            $name = ''
            try {
                $xml = [xml]$e.ToXml()
                foreach ($d in $xml.Event.EventData.Data) { if ($d.Name -eq 'SSID') { $name = [string]$d.'#text' } }
            } catch { }
            $what = 'Wi-Fi connected'
            if ($e.Id -eq 8003) { $what = 'Wi-Fi disconnected' }
            $list += [pscustomobject]@{ Time = $e.TimeCreated; What = $what; Name = $name; Source = 'wifi' }
        }
    } catch { }
    return @($list | Sort-Object Time)
}

function Get-AllRows {
    $boot    = Get-BootTime
    $rows    = @()
    $configs = @(Get-AdapterConfigs)

    # 1. This PC gets its internet from another PC or a phone
    $r = New-Row 'Gateway' 'Where this PC gets its internet' 'The gateway address shows what kind of device this PC is connected through'
    $kinds = @(); $gwText = @(); $viaPc = $false; $macRange = $false
    foreach ($c in $configs) {
        foreach ($g in $c.Gateways) {
            $gwText += ($g + ' on ' + $c.Description)
            $k = Get-GatewayKind $g
            if ($k) { $kinds += $k; if ($g -like '192.168.137.*') { $viaPc = $true } }
            if ($g -like '192.168.2.*') { $macRange = $true }
        }
    }
    if ($gwText.Count -eq 0) { $r.Found = 'No gateway (not connected)'; $r.Level = 'note'; $r.Result = 'NO NETWORK' }
    else { $r.Found = ($gwText -join '; ') }
    if ($viaPc) {
        $r.Result = 'THROUGH ANOTHER PC'; $r.Level = 'bad'
        $r.Detail = 'This PC gets its internet from another Windows PC that is sharing its connection. That is the classic two-PC setup: the other PC is the one that was in game. Ask to see the other PC. Shared connections also exist for normal reasons, so confirm before banning.'
    } elseif ($kinds.Count -gt 0) {
        $r.Result = 'HOTSPOT'; $r.Level = 'warn'
        $r.Detail = 'This PC is connected through ' + ($kinds -join ', ') + '. A phone hotspot can also be shared with a second PC. Ask why they are not on their normal internet.'
    } elseif ($macRange) {
        $r.Result = 'POSSIBLE MAC SHARING'; $r.Level = 'note'
        $r.Detail = '192.168.2.x is what a Mac hands out when it shares its internet, but normal routers (Bell, Belkin and others) use it too. It only matters if something else here is flagged.'
    }
    $rows += [pscustomobject]$r

    # 2. This PC is sharing its own connection
    $r = New-Row 'Sharing' 'Is this PC sharing its connection' 'A PC that hosts a hotspot or connection sharing gives itself the address 192.168.137.1'
    $hostAdapter = ''
    foreach ($c in $configs) { if ($c.IPs -contains '192.168.137.1') { $hostAdapter = $c.Description } }
    $hot = Get-MobileHotspot
    if ($hostAdapter -or $hot.On) {
        $count = [int](Get-SharedClientCount)
        if ($hot.On -and $hot.Clients -gt $count) { $count = $hot.Clients }
        $how = @()
        if ($hot.On) { $how += 'Mobile Hotspot is on' }
        if ($hostAdapter) { $how += ('sharing on "' + $hostAdapter + '"') }
        $r.Found = ('{0}, {1} device(s) connected' -f ($how -join ', '), $count)
        if ($count -gt 0) {
            $r.Result = 'SHARING, DEVICE CONNECTED'; $r.Level = 'bad'
            $r.Detail = ('This PC is sharing its internet and {0} other device(s) are using it. A second PC on this connection has the same public IP as this one. Ask what the connected device is. It can also be a phone or console, so confirm before banning.' -f $count)
        } else {
            $r.Result = 'SHARING'; $r.Level = 'warn'
            $r.Detail = 'This PC is set up to share its internet. Nothing is connected to it right now, but a device may have been connected earlier.'
        }
    } elseif ($hot.Known) { $r.Found = 'Not sharing, Mobile Hotspot is off' }
    else { $r.Found = 'Not sharing' }
    $rows += [pscustomobject]$r

    # 3. Internet Connection Sharing switched on for an adapter
    $r = New-Row 'ICS' 'Internet Connection Sharing' 'The Windows setting that shares one adapter with another, for example Wi-Fi to an Ethernet cable'
    $shared = Get-IcsShares
    if ($null -eq $shared) {
        $r.Found = 'Could not be read'; $r.Level = 'note'; $r.Result = 'UNKNOWN'; $r.Detail = 'Run as administrator to read this.'
    } elseif (@($shared).Count -gt 0) {
        $r.Found = (@($shared) -join '; '); $r.Result = 'ENABLED'; $r.Level = 'warn'
        $r.Detail = 'Connection sharing is switched on. A second PC plugged into the receiving adapter gets its internet through this PC.'
    } else { $r.Found = 'Off' }
    $rows += [pscustomobject]$r

    # 4. Services behind hotspot and sharing
    $r = New-Row 'Services' 'Hotspot and sharing services' 'icssvc runs while Mobile Hotspot is on, SharedAccess runs while sharing is on'
    $running = @(Get-SharingServices)
    if ($running.Count -gt 0) {
        $r.Found = ($running -join '; '); $r.Result = 'RUNNING'; $r.Level = 'warn'
        $r.Detail = 'These services start when a hotspot or connection sharing is turned on. If nothing above shows sharing right now, it was probably on earlier this session. Compare the start time with when they were in game.'
    } else { $r.Found = 'Not running' }
    $rows += [pscustomobject]$r

    # 5. Current Wi-Fi network
    $r = New-Row 'Wifi' 'Current Wi-Fi network' 'The name of the network and whether its access point looks like a phone or PC'
    $wifi = Get-WifiInterface
    if (-not $wifi.Ssid) {
        if ($wifi.Blocked) {
            $r.Found = 'Hidden by Windows'; $r.Result = 'UNKNOWN'; $r.Level = 'note'
            $r.Detail = 'Windows will not show Wi-Fi details while Location is turned off. Ask them to turn it on in Settings, Privacy and security, Location, then press Rescan.'
        } else { $r.Found = 'Not on Wi-Fi' }
    } else {
        $r.Found = $wifi.Ssid
        $why = @()
        if (Test-HotspotName $wifi.Ssid) { $why += 'the name looks like a phone or PC hotspot' }
        if ($wifi.LocalMac) { $why += 'the access point uses a made-up hardware address, which hotspots do and most routers do not' }
        if ($why.Count -gt 0) {
            $r.Result = 'LOOKS LIKE A HOTSPOT'; $r.Level = 'warn'
            $r.Detail = 'Reason: ' + ($why -join '; ') + '. Mesh systems and some newer routers also use made-up addresses, so check with the gateway result.'
        }
    }
    $rows += [pscustomobject]$r

    # 6. Network changes since boot
    $r = New-Row 'Switches' 'Network changes since boot' 'Connects and disconnects Windows logged this session'
    $events = @(Get-NetworkEvents $boot)
    $names  = @()
    $lastConnect = $null
    foreach ($e in $events) {
        if ($e.What -like '*connected' -and $e.What -notlike '*disconnected') {
            if ($e.Name -and ($names -notcontains $e.Name)) { $names += $e.Name }
            $lastConnect = $e.Time
        }
    }
    $r.Found = ('{0} event(s), {1} different network(s)' -f $events.Count, $names.Count)
    if ($names.Count -gt 0) { $r.Found += ': ' + ($names -join ', ') }
    $why = @()
    if ($names.Count -gt 1) { $why += ('this PC has been on {0} different networks since boot' -f $names.Count) }
    if ($null -ne $lastConnect) {
        $ago = ((Get-Date) - $lastConnect).TotalMinutes
        $sinceBoot = ($lastConnect - $boot).TotalMinutes
        if ($ago -le $RecentSwitchMinutes -and $sinceBoot -gt 10) { $why += ('it connected to a network {0:N0} minute(s) ago' -f $ago) }
    }
    $hotNames = @($names | Where-Object { Test-HotspotName $_ })
    if ($hotNames.Count -gt 0) { $why += ('it used a network that looks like a hotspot: ' + ($hotNames -join ', ')) }
    if ($why.Count -gt 0) {
        $r.Result = 'CHANGED'; $r.Level = 'warn'
        $r.Detail = 'Reason: ' + ($why -join '; ') + '. Compare the times in the log box with when the screenshare was called.'
    }
    $rows += [pscustomobject]$r

    # 7. Saved networks that look like hotspots
    $r = New-Row 'Saved' 'Saved hotspot networks' 'Saved Wi-Fi networks whose names look like a phone or PC hotspot. Other saved networks are not shown.'
    $saved = @(Get-SavedHotspotProfiles)
    if ($saved.Count -gt 0) {
        $r.Found = ($saved -join ', '); $r.Result = 'FOUND'; $r.Level = 'note'
        $r.Detail = 'This PC has joined these before. It shows they have a hotspot available, nothing more. Windows does not say when it was last used here.'
    } else { $r.Found = 'None' }
    $rows += [pscustomobject]$r

    return @{ Rows = $rows; Events = $events; Boot = $boot }
}

function Save-Report($Scan) {
    try {
        if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }
        $base = Join-Path $OutDir ('scan_' + (Get-Date).ToString('yyyyMMdd_HHmmss'))
        $Scan.Rows | Select-Object Name, Display, Found, Result, Detail | Export-Csv -Path ($base + '.csv') -NoTypeInformation -Encoding UTF8
        $txt  = @()
        $txt += 'Hotspot Checker report'
        $txt += 'Computer: ' + $env:COMPUTERNAME + '   User: ' + $env:USERNAME
        $txt += 'Scan time: ' + (Format-Time (Get-Date)) + '   Boot time: ' + (Format-Time $Scan.Boot)
        $txt += 'Running as administrator: ' + (Test-IsAdmin)
        $txt += ''
        foreach ($r in $Scan.Rows) {
            $txt += ('[{0}] {1}: {2}' -f $r.Result, $r.Display, $r.Found)
            if ($r.Detail) { $txt += '      ' + $r.Detail }
        }
        $txt += ''
        $txt += 'Network events since boot:'
        foreach ($e in $Scan.Events) { $txt += ('  {0}  {1}  {2}' -f (Format-Time $e.Time), $e.What, $e.Name) }
        Set-Content -Path ($base + '.txt') -Value $txt -Encoding UTF8
        return ($base + '.txt')
    } catch { return '' }
}

# =============================================================================
#  COMMAND LINE MODE
# =============================================================================
if ($NoGui) {
    $scan = Get-AllRows
    foreach ($r in $scan.Rows) {
        Write-Host ('[{0}] {1}: {2}' -f $r.Result, $r.Display, $r.Found)
        if ($r.Detail) { Write-Host ('      ' + $r.Detail) }
    }
    Write-Host "`nNetwork events since boot:"
    foreach ($e in $scan.Events) { Write-Host ('  {0}  {1}  {2}' -f (Format-Time $e.Time), $e.What, $e.Name) }
    $path = Save-Report $scan
    if ($path) { Write-Host "`nReport saved to $path" }
    if ($Json) { $scan.Rows | ConvertTo-Json -Depth 4 | Set-Content -Path $Json -Encoding UTF8 }
    return
}

# =============================================================================
#  WINDOW
# =============================================================================
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$script:HasNative = $false
try {
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class HotNative {
    [DllImport("dwmapi.dll")]
    public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);
}
"@ -ErrorAction Stop
    $script:HasNative = $true
} catch { }

function C([string]$hex) { return [System.Drawing.ColorTranslator]::FromHtml($hex) }
$ColWindow    = C '#1B1C1F'
$ColPanel     = C '#232529'
$ColPanelHead = C '#2A2C31'
$ColLogBack   = C '#141518'
$ColBorder    = C '#34373D'
$ColText      = C '#E6E7EA'
$ColTitle     = C '#F2F3F5'
$ColSub       = C '#C9CCD1'
$ColDim       = C '#9AA0A8'
$ColMuted     = C '#8E939B'
$ColOK        = C '#4CC38A'
$ColWarn      = C '#E5B454'
$ColErr       = C '#FF6B6E'

$FontUI     = New-Object System.Drawing.Font('Segoe UI', 9.75)
$FontSmall  = New-Object System.Drawing.Font('Segoe UI', 8.5)
$FontSmallB = New-Object System.Drawing.Font('Segoe UI', 8.25, [System.Drawing.FontStyle]::Bold)
$FontTitle  = New-Object System.Drawing.Font('Segoe UI Semibold', 14.25)
$FontMono   = New-Object System.Drawing.Font('Consolas', 9)

function New-Label {
    param([string]$Text, [int]$X, [int]$Y, $Font, $Color)
    $l = New-Object System.Windows.Forms.Label
    $l.Text      = $Text
    $l.Location  = New-Object System.Drawing.Point($X, $Y)
    $l.AutoSize  = $true
    $l.Font      = $Font
    $l.ForeColor = $Color
    $l.BackColor = [System.Drawing.Color]::Transparent
    return $l
}

function New-FlatButton {
    param([string]$Text, [int]$X, [int]$Y, [int]$W, [int]$H)
    $b = New-Object System.Windows.Forms.Button
    $b.Text      = $Text
    $b.Location  = New-Object System.Drawing.Point($X, $Y)
    $b.Size      = New-Object System.Drawing.Size($W, $H)
    $b.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $b.FlatAppearance.BorderColor = $ColBorder
    $b.FlatAppearance.BorderSize  = 1
    $b.BackColor = $ColPanel
    $b.ForeColor = $ColText
    $b.Font      = $FontUI
    $b.Cursor    = [System.Windows.Forms.Cursors]::Hand
    $b.UseVisualStyleBackColor = $false
    return $b
}

$Form = New-Object System.Windows.Forms.Form
$Form.Text          = 'Hotspot Checker'
$Form.ClientSize    = New-Object System.Drawing.Size(1000, 600)
$Form.MinimumSize   = New-Object System.Drawing.Size(860, 520)
$Form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
$Form.BackColor     = $ColWindow
$Form.ForeColor     = $ColText
$Form.Font          = $FontUI

$A = [System.Windows.Forms.AnchorStyles]
$Title     = New-Label 'Hotspot Checker' 18 12 $FontTitle $ColTitle
$SubLabel  = New-Label '' 20 44 $FontSmall $ColDim
$BtnRescan = New-FlatButton 'Rescan' 18 70 96 30
$BtnFolder = New-FlatButton 'Open report folder' 122 70 150 30
$Summary   = New-Label '' 288 77 $FontUI $ColSub

$Grid = New-Object System.Windows.Forms.DataGridView
$Grid.Location = New-Object System.Drawing.Point(18, 110)
$Grid.Size     = New-Object System.Drawing.Size(964, 220)
$Grid.Anchor   = $A::Top -bor $A::Left -bor $A::Right
$Grid.BackgroundColor  = $ColPanel
$Grid.GridColor        = $ColBorder
$Grid.BorderStyle      = [System.Windows.Forms.BorderStyle]::FixedSingle
$Grid.CellBorderStyle  = [System.Windows.Forms.DataGridViewCellBorderStyle]::SingleHorizontal
$Grid.EnableHeadersVisualStyles = $false
$Grid.RowHeadersVisible         = $false
$Grid.AllowUserToAddRows        = $false
$Grid.AllowUserToDeleteRows     = $false
$Grid.AllowUserToResizeRows     = $false
$Grid.ReadOnly                  = $true
$Grid.MultiSelect               = $false
$Grid.SelectionMode             = [System.Windows.Forms.DataGridViewSelectionMode]::FullRowSelect
$Grid.ColumnHeadersBorderStyle  = [System.Windows.Forms.DataGridViewHeaderBorderStyle]::None
$Grid.ColumnHeadersHeightSizeMode = [System.Windows.Forms.DataGridViewColumnHeadersHeightSizeMode]::DisableResizing
$Grid.ColumnHeadersHeight       = 26
$Grid.RowTemplate.Height        = 26
$Grid.ColumnHeadersDefaultCellStyle.BackColor          = $ColPanelHead
$Grid.ColumnHeadersDefaultCellStyle.ForeColor          = $ColDim
$Grid.ColumnHeadersDefaultCellStyle.SelectionBackColor = $ColPanelHead
$Grid.ColumnHeadersDefaultCellStyle.Font               = $FontSmallB
$Grid.DefaultCellStyle.BackColor          = $ColPanel
$Grid.DefaultCellStyle.ForeColor          = $ColText
$Grid.DefaultCellStyle.SelectionBackColor = $ColPanelHead
$Grid.DefaultCellStyle.SelectionForeColor = $ColText
$Grid.DefaultCellStyle.Font               = $FontUI

function New-TextColumn([string]$Header, [int]$Width, [bool]$Fill) {
    $c = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $c.HeaderText = $Header
    $c.ReadOnly   = $true
    $c.SortMode   = [System.Windows.Forms.DataGridViewColumnSortMode]::NotSortable
    if ($Fill) { $c.AutoSizeMode = [System.Windows.Forms.DataGridViewAutoSizeColumnMode]::Fill } else { $c.Width = $Width }
    return $c
}
$colCheck  = New-TextColumn 'CHECK' 250 $false
$colFound  = New-TextColumn 'FOUND' 0 $true
$colResult = New-TextColumn 'RESULT' 200 $false
$colResult.DefaultCellStyle.Font = $FontSmallB
foreach ($col in @($colCheck, $colFound, $colResult)) { [void]$Grid.Columns.Add([System.Windows.Forms.DataGridViewColumn]$col) }

$DetailLabel = New-Object System.Windows.Forms.Label
$DetailLabel.Location  = New-Object System.Drawing.Point(18, 336)
$DetailLabel.Size      = New-Object System.Drawing.Size(964, 54)
$DetailLabel.Anchor    = $A::Top -bor $A::Left -bor $A::Right
$DetailLabel.Font      = $FontSmall
$DetailLabel.ForeColor = $ColSub
$DetailLabel.Text      = 'Click a row to see what the result means.'

$LogBox = New-Object System.Windows.Forms.RichTextBox
$LogBox.Location    = New-Object System.Drawing.Point(18, 396)
$LogBox.Size        = New-Object System.Drawing.Size(964, 188)
$LogBox.Anchor      = $A::Top -bor $A::Left -bor $A::Right -bor $A::Bottom
$LogBox.BackColor   = $ColLogBack
$LogBox.ForeColor   = $ColSub
$LogBox.Font        = $FontMono
$LogBox.ReadOnly    = $true
$LogBox.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
$LogBox.DetectUrls  = $false

foreach ($ctl in @($Title, $SubLabel, $BtnRescan, $BtnFolder, $Summary, $Grid, $DetailLabel, $LogBox)) {
    $Form.Controls.Add([System.Windows.Forms.Control]$ctl)
}

function Add-Log([string]$Text, $Color) {
    $LogBox.SelectionStart  = $LogBox.TextLength
    $LogBox.SelectionLength = 0
    $LogBox.SelectionColor  = $Color
    $LogBox.AppendText($Text + "`r`n")
    $LogBox.ScrollToCaret()
}

function Get-LevelColor([string]$Level) {
    if ($Level -eq 'ok')   { return $ColOK }
    if ($Level -eq 'warn') { return $ColWarn }
    if ($Level -eq 'note') { return $ColMuted }
    return $ColErr
}

function Update-Grid {
    $Form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    $Grid.Rows.Clear()
    $LogBox.Clear()
    $scan = Get-AllRows
    $bad = 0; $warn = 0
    foreach ($r in $scan.Rows) {
        $i = $Grid.Rows.Add([object[]]@($r.Display, $r.Found, $r.Result))
        $row = $Grid.Rows[$i]
        $row.Tag = $r
        $row.Cells[2].Style.ForeColor = Get-LevelColor $r.Level
        $row.Cells[2].Style.SelectionForeColor = Get-LevelColor $r.Level
        $row.Cells[0].ToolTipText = $r.What
        if ($r.Level -eq 'bad')  { $bad++ }
        if ($r.Level -eq 'warn') { $warn++ }
    }
    $admin = 'yes'
    if (-not (Test-IsAdmin)) { $admin = 'NO, some checks cannot be read' }
    $SubLabel.Text = ('Boot time: {0}     Scan: {1}     Administrator: {2}' -f (Format-Time $scan.Boot), (Format-Time (Get-Date)), $admin)
    if ($bad -eq 0 -and $warn -eq 0) { $Summary.Text = 'Nothing points at a shared connection.'; $Summary.ForeColor = $ColOK }
    else {
        $Summary.Text = ('{0} strong sign(s), {1} thing(s) to ask about' -f $bad, $warn)
        if ($bad) { $Summary.ForeColor = $ColErr } else { $Summary.ForeColor = $ColWarn }
    }
    Add-Log 'Network events since boot:' $ColDim
    if (@($scan.Events).Count -eq 0) { Add-Log '  none logged' $ColSub }
    foreach ($e in $scan.Events) {
        $color = $ColSub
        if (Test-HotspotName $e.Name) { $color = $ColWarn }
        Add-Log ('  {0}  {1,-18} {2}' -f (Format-Time $e.Time), $e.What, $e.Name) $color
    }
    $path = Save-Report $scan
    if ($path) { Add-Log ('Report saved: ' + $path) $ColDim } else { Add-Log ('Could not save a report to ' + $OutDir) $ColErr }
    $Form.Cursor = [System.Windows.Forms.Cursors]::Default
}

$Grid.Add_SelectionChanged({
    if ($Grid.SelectedRows.Count -gt 0) {
        $r = $Grid.SelectedRows[0].Tag
        if ($null -ne $r) {
            $d = $r.Detail
            if (-not $d) { $d = 'Normal. ' + $r.What + '.' }
            $DetailLabel.Text = ($r.Display + ': ' + $d)
        }
    }
})

$BtnRescan.Add_Click({ Update-Grid })
$BtnFolder.Add_Click({
    try {
        if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }
        Start-Process explorer.exe $OutDir
    } catch { Add-Log ('Could not open ' + $OutDir) $ColErr }
})

$Form.Add_Shown({
    if ($script:HasNative) {
        try {
            $on = 1
            [void][HotNative]::DwmSetWindowAttribute($Form.Handle, 20, [ref]$on, 4)
            [void][HotNative]::DwmSetWindowAttribute($Form.Handle, 19, [ref]$on, 4)
        } catch { }
    }
    Update-Grid
})

[void]$Form.ShowDialog()
