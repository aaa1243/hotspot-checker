#!/bin/bash
#
#  hotspot-checker-mac.sh
#  ----------------------
#  Mac version of Hotspot Checker. Screenshare helper for catching "fakers":
#  players who get screenshared on a clean computer while the one they played
#  on sits next to it. To keep the same IP as the game, the two computers share
#  one internet connection, usually through Internet Sharing or a phone hotspot.
#  This looks at how this Mac is connected and whether it is sharing.
#
#  - Read-only. It changes nothing on the Mac.
#  - It does not show the public IP, MAC addresses or the full list of saved
#    Wi-Fi networks. Only networks joined since boot and saved networks that
#    are hotspots.
#  - Plain bash 3.2 and tools that ship with macOS. Nothing to install.
#
#  Run it (the saved-network checks need sudo):
#    sudo bash hotspot-checker-mac.sh
#  Straight from GitHub without downloading:
#    curl -fsSL https://raw.githubusercontent.com/aaa1243/hotspot-checker/main/hotspot-checker-mac.sh | sudo bash
#
#  Options:
#    --json FILE   also write the results as JSON
#    --out DIR     where reports go (default /Users/Shared/SSTools/HotspotChecker)

set -u

OUT_DIR="/Users/Shared/SSTools/HotspotChecker"
JSON_PATH=""

# Joining a network this many minutes before the scan counts as "right before the SS".
RECENT_SWITCH_MINUTES=30

# Network names that look like a phone or PC hotspot (extended regex, not case sensitive).
HOTSPOT_RE="iphone|ipad|android|galaxy|pixel [0-9]|oneplus|xiaomi|redmi|huawei|poco [a-z][0-9]|realme|motorola|moto [a-z][0-9]|hotspot|tether|s phone|^DIRECT-|^SM-[A-Z0-9]|^GT-[A-Z0-9]|^(DESKTOP|LAPTOP)-[A-Z0-9]{5,8}( [0-9]{4})?\$"

KNOWN_PLIST="${HC_KNOWN_PLIST:-/Library/Preferences/com.apple.wifi.known-networks.plist}"

# =============================================================================
#  DATA SOURCES  (every command that reads the Mac lives here, so the tests can
#  swap them for fake data)
# =============================================================================
src_now()         { date +%s; }
src_boot()        { sysctl -n kern.boottime 2>/dev/null | sed -n 's/.*{ sec = \([0-9]*\),.*/\1/p'; }
src_is_root()     { [ "$(id -u)" = "0" ]; }
src_routes()      { netstat -rn -f inet 2>/dev/null; }
src_ports()       { networksetup -listallhardwareports 2>/dev/null; }
src_iflist()      { ifconfig -l 2>/dev/null; }
src_ifconfig()    { ifconfig "$1" 2>/dev/null; }
src_nat_enabled() { /usr/libexec/PlistBuddy -c 'Print :NAT:Enabled' /Library/Preferences/SystemConfiguration/com.apple.nat.plist 2>/dev/null; }
src_arp()         { arp -an -i "$1" 2>/dev/null; }
src_leases()      { cat /var/db/dhcpd_leases 2>/dev/null; }
src_procs()       { ps -axo lstart=,comm= 2>/dev/null; }
src_wifi_info()   { system_profiler SPAirPortDataType 2>/dev/null; }
src_known_xml()   {
    # Three ways to turn the binary list into XML, in case one is blocked on this macOS version.
    local out
    out="$(plutil -convert xml1 -o - "$KNOWN_PLIST" 2>/dev/null)"
    [ -z "$out" ] && out="$(/usr/libexec/PlistBuddy -x -c Print "$KNOWN_PLIST" 2>/dev/null)"
    [ -z "$out" ] && out="$(cat "$KNOWN_PLIST" 2>/dev/null | plutil -convert xml1 -o - - 2>/dev/null)"
    printf '%s' "$out"
}
src_known_error() { cat "$KNOWN_PLIST" 2>&1 >/dev/null | head -1; }
src_preferred()   { networksetup -listpreferredwirelessnetworks "$1" 2>/dev/null; }

# =============================================================================
#  HELPERS
# =============================================================================
fmt_time() {
    # Epoch seconds to local time. First form is macOS, second is Linux (used by the tests).
    date -r "$1" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date -d "@$1" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || printf '%s' "$1"
}

is_hotspot_name() {
    [ -n "$1" ] && printf '%s\n' "$1" | grep -Eiq -- "$HOTSPOT_RE"
}

gateway_kind() {
    # What kind of device hands out this gateway address by default. Empty for ordinary router ranges.
    case "$1" in
        192.168.137.*) echo "a Windows PC sharing its connection (Mobile Hotspot or Internet Connection Sharing)" ;;
        192.168.43.*)  echo "an Android phone hotspot" ;;
        172.20.10.*)   echo "an iPhone hotspot" ;;
        192.168.42.*)  echo "Android USB tethering" ;;
        192.168.44.*)  echo "Android Bluetooth tethering" ;;
        192.168.49.*)  echo "a Wi-Fi Direct group (phone or PC)" ;;
    esac
}

port_name() {
    # "en0" -> "Wi-Fi", "en7" -> "iPhone USB"
    src_ports | awk -v d="$1" '/^Hardware Port: /{p=substr($0,16)} /^Device: /{ if ($2==d) { print p; exit } }'
}

wifi_device() {
    src_ports | awk '/^Hardware Port: (Wi-Fi|AirPort)/{getline; print $2; exit}'
}

count_clients() {
    # Devices this Mac has talked to on its own shared network. Only the count is used.
    src_arp "$1" | awk '
        /incomplete/ || /permanent/ || /ff:ff:ff:ff:ff:ff/ { next }
        $2 ~ /^\((224|239)\./ { next }
        $4 ~ /^[0-9a-fA-F]+:[0-9a-fA-F]+:/ { n++ }
        END { print n + 0 }'
}

count_live_leases() {
    # Addresses this Mac handed out that have not run out yet. $1 = now (epoch).
    local now="$1" n=0 line hex
    while IFS= read -r line; do
        case "$line" in
            *lease=0x*)
                hex="${line##*lease=0x}"
                hex="$(printf '%s' "$hex" | tr -cd '0-9a-fA-F')"
                [ -n "$hex" ] && [ "$((16#$hex))" -gt "$now" ] && n=$((n + 1))
                ;;
        esac
    done <<EOF
$(src_leases)
EOF
    echo "$n"
}

parse_known() {
    # Saved Wi-Fi networks from the XML form of the known-networks plist.
    # Prints one line per network: <last joined, epoch or 0> TAB <1 if macOS marked it a hotspot> TAB <name>
    awk '
    function epoch(s,   y, m, d) {
        y = substr(s, 1, 4) + 0; m = substr(s, 6, 2) + 0; d = substr(s, 9, 2) + 0
        if (m <= 2) { y--; m += 12 }
        return (365 * y + int(y / 4) - int(y / 100) + int(y / 400) + int((153 * (m - 3) + 2) / 5) + d - 719469) * 86400 \
               + substr(s, 12, 2) * 3600 + substr(s, 15, 2) * 60 + substr(s, 18, 2)
    }
    function flush() { if (name != "") printf "%d\t%d\t%s\n", joined, hot, name; name = ""; joined = 0; hot = 0 }
    {
        line = $0
        sub(/^[ \t]+/, "", line); sub(/[ \t\r]+$/, "", line)
        if (line == "<dict>")  { depth++; next }
        if (line == "</dict>") { depth--; if (depth == 1) flush(); next }
        if (line ~ /^<key>.*<\/key>$/) {
            k = substr(line, 6, length(line) - 11)
            if (depth == 1) {
                flush()
                gsub(/&lt;/, "<", k); gsub(/&gt;/, ">", k); gsub(/&amp;/, "\\&", k)
                sub(/^wifi\.network\.ssid\./, "", k)
                name = k
            } else { key = k }
            next
        }
        if (depth >= 2) {
            if (depth == 2 && line ~ /^<date>/ && (key == "JoinedByUserAt" || key == "JoinedBySystemAt")) {
                t = epoch(substr(line, 7, 20)); if (t > joined) joined = t
            }
            # macOS marks hotspots itself. The flag has moved between versions, so take it at any level.
            if (line == "<true/>" && key ~ /PersonalHotspot/) hot = 1
            if (line !~ /^<(array|dict)/) key = ""
        }
    }
    END { flush() }'
}

# Result rows, kept in matching lists (bash 3.2 has no dictionaries).
R_NAME=(); R_DISPLAY=(); R_FOUND=(); R_RESULT=(); R_LEVEL=(); R_DETAIL=()
EVENTS=""

add_row() {  # name, display, found, result, level, detail
    R_NAME+=("$1"); R_DISPLAY+=("$2"); R_FOUND+=("$3"); R_RESULT+=("$4"); R_LEVEL+=("$5"); R_DETAIL+=("$6")
}

row_field() {  # row_field Gateway RESULT   (used by the tests)
    local i
    for i in "${!R_NAME[@]}"; do
        if [ "${R_NAME[$i]}" = "$1" ]; then
            case "$2" in
                FOUND)  printf '%s' "${R_FOUND[$i]}" ;;
                RESULT) printf '%s' "${R_RESULT[$i]}" ;;
                LEVEL)  printf '%s' "${R_LEVEL[$i]}" ;;
                DETAIL) printf '%s' "${R_DETAIL[$i]}" ;;
            esac
            return 0
        fi
    done
    return 1
}

# =============================================================================
#  CHECKS
# =============================================================================
GW_WIFI_KIND=""
check_gateway() {
    local display="Where this Mac gets its internet"
    local found="" kinds="" via_pc=0 mac_range=0 gw ifc port k
    while read -r gw ifc; do
        [ -z "$gw" ] && continue
        port="$(port_name "$ifc")"
        found="${found:+$found; }$gw on $ifc${port:+ ($port)}"
        k="$(gateway_kind "$gw")"
        case "$port" in
            *"iPhone USB"*|*"iPad USB"*) [ -z "$k" ] && k="an iPhone or iPad over USB" ;;
            *"Bluetooth PAN"*)           [ -z "$k" ] && k="a phone over Bluetooth" ;;
            *Android*|*RNDIS*|*Tether*)  [ -z "$k" ] && k="a phone over USB" ;;
        esac
        [ -n "$k" ] && kinds="${kinds:+$kinds, }$k"
        [ -n "$k" ] && [ "$ifc" = "$(wifi_device)" ] && GW_WIFI_KIND="$k"
        case "$gw" in
            192.168.137.*) via_pc=1 ;;
            192.168.2.*)   mac_range=1 ;;
        esac
    done <<EOF
$(src_routes | awk '$1 == "default" && $2 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ { print $2, $4 }' | sort -u)
EOF
    if [ -z "$found" ]; then
        add_row Gateway "$display" "No gateway (not connected, or everything goes through a VPN)" "NO NETWORK" note ""
    elif [ "$via_pc" = 1 ]; then
        add_row Gateway "$display" "$found" "THROUGH ANOTHER PC" bad \
            "This Mac gets its internet from a Windows PC that is sharing its connection. That is the classic two-computer setup: the other PC is the one that was in game. Ask to see it. Shared connections also exist for normal reasons, so confirm before banning."
    elif [ -n "$kinds" ]; then
        add_row Gateway "$display" "$found" "HOTSPOT" warn \
            "This Mac is connected through $kinds. A phone hotspot can also be shared with a second computer. Ask why they are not on their normal internet."
    elif [ "$mac_range" = 1 ]; then
        add_row Gateway "$display" "$found" "POSSIBLE MAC SHARING" note \
            "192.168.2.x is what a Mac hands out when it shares its internet, but normal routers (Bell, Belkin and others) use it too. It only matters if something else here is flagged."
    else
        add_row Gateway "$display" "$found" "OK" ok ""
    fi
}

check_sharing() {
    local display="Is this Mac sharing its connection"
    local now="$1" nat enabled=0 ifc ip bridges="" clients=0 leases n
    nat="$(src_nat_enabled)"
    case "$nat" in 1|true|YES) enabled=1 ;; esac
    for ifc in $(src_iflist); do
        case "$ifc" in
            bridge1[0-9][0-9])
                ip="$(src_ifconfig "$ifc" | awk '$1 == "inet" { print $2; exit }')"
                [ -z "$ip" ] && continue
                bridges="${bridges:+$bridges, }$ifc ($ip)"
                n="$(count_clients "$ifc")"
                clients=$((clients + n))
                ;;
        esac
    done
    leases="$(count_live_leases "$now")"
    if [ "$enabled" = 1 ]; then
        if [ "$clients" -gt 0 ]; then
            add_row Sharing "$display" "Internet Sharing is on${bridges:+ on $bridges}, $clients device(s) connected" "SHARING, DEVICE CONNECTED" bad \
                "This Mac is sharing its internet and $clients other device(s) are using it. A second computer on this connection has the same public IP as this one. Ask what the connected device is. It can also be a phone or console, so confirm before banning."
        elif [ "$leases" -gt 0 ]; then
            add_row Sharing "$display" "Internet Sharing is on${bridges:+ on $bridges}, nothing connected now, $leases device(s) recently" "SHARING, DEVICE WAS CONNECTED" bad \
                "This Mac is sharing its internet. Nothing is on it right now, but $leases device(s) got an address from it recently and that address has not run out yet. Ask what was connected."
        else
            add_row Sharing "$display" "Internet Sharing is on${bridges:+ on $bridges}, 0 device(s) connected" "SHARING" warn \
                "This Mac is set up to share its internet. Nothing is connected to it right now, but a device may have been connected earlier."
        fi
    elif [ -n "$bridges" ]; then
        add_row Sharing "$display" "Internet Sharing is off, but $bridges exists with $clients device(s)" "VIRTUAL NETWORK" note \
            "A shared network exists while the Internet Sharing switch is off. That is normally a virtual machine app (Parallels, UTM, Docker and so on). Ask what is running if it does not fit."
    else
        add_row Sharing "$display" "Not sharing" "OK" ok ""
    fi
}

check_services() {
    local display="Sharing services"
    local found=""  line name
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        name="${line##*/}"
        found="${found:+$found; }$name (started ${line%% /*})"
    done <<EOF
$(src_procs | grep -E '/(InternetSharing|NetworkSharing|bootpd)$')
EOF
    if [ -n "$found" ]; then
        add_row Services "$display" "$found" "RUNNING" note \
            "These run while Internet Sharing is on or a device asks this Mac for an address. Virtual machine apps start them too, so this only matters next to another flag. Compare the start time with when they were in game."
    else
        add_row Services "$display" "Not running" "OK" ok ""
    fi
}

check_wifi() {
    local display="Current Wi-Fi network"
    local dev ssid
    dev="$(wifi_device)"
    if [ -z "$dev" ]; then add_row Wifi "$display" "This Mac has no Wi-Fi" "OK" ok ""; return; fi
    if ! src_ifconfig "$dev" | grep -q 'status: active'; then add_row Wifi "$display" "Not on Wi-Fi" "OK" ok ""; return; fi
    ssid="$(src_wifi_info | awk '/Current Network Information:/ { getline; sub(/^[ \t]+/, ""); sub(/:[ \t]*$/, ""); print; exit }')"
    case "$ssid" in
        ""|*redacted*|*Redacted*)
            if [ -n "$GW_WIFI_KIND" ]; then
                add_row Wifi "$display" "Name hidden by macOS, but the gateway shows $GW_WIFI_KIND" "LOOKS LIKE A HOTSPOT" warn \
                    "macOS hides the Wi-Fi name from Terminal, but the address this Wi-Fi hands out matches $GW_WIFI_KIND. Have them click the Wi-Fi icon in the menu bar to show the name."
            else
                add_row Wifi "$display" "On Wi-Fi, name hidden by macOS" "UNKNOWN" note \
                    "Newer macOS hides the Wi-Fi name from Terminal. Have them click the Wi-Fi icon in the menu bar so you can read the name."
            fi
            ;;
        *)
            if is_hotspot_name "$ssid"; then
                add_row Wifi "$display" "$ssid" "LOOKS LIKE A HOTSPOT" warn \
                    "The name looks like a phone or PC hotspot. Check it against the gateway result."
            else
                add_row Wifi "$display" "$ssid" "OK" ok ""
            fi
            ;;
    esac
}

check_known() {
    # Two rows from the saved-network list: networks joined since boot, and saved hotspots.
    local boot="$1" now="$2"
    local d1="Networks joined since boot" d2="Saved hotspot networks"
    local known joined hot name count=0 names="" hotnames="" last=0 saved="" why="" ago since
    known="$(src_known_xml | parse_known)"
    if [ -z "$known" ]; then
        local err dev pref list
        err="$(src_known_error)"
        if ! src_is_root; then
            why="Run it with sudo to read this."
        elif [ -n "$err" ]; then
            why="macOS blocked reading the saved network list ($err). Give Terminal Full Disk Access in System Settings, Privacy and Security, then run it again."
        else
            why="The saved network list could not be read on this macOS version."
        fi
        add_row Switches "$d1" "Could not be read" "UNKNOWN" note "$why"
        # Backup: networksetup still lists saved names (no dates), so saved hotspots can be shown.
        dev="$(wifi_device)"
        list=""
        [ -n "$dev" ] && list="$(src_preferred "$dev" | tail -n +2)"
        while IFS= read -r pref; do
            pref="$(printf '%s' "$pref" | sed 's/^[[:space:]]*//')"
            [ -z "$pref" ] && continue
            if is_hotspot_name "$pref"; then saved="${saved:+$saved, }$pref"; fi
        done <<LIST
$list
LIST
        if [ -n "$saved" ]; then
            add_row Saved "$d2" "$saved" "FOUND" note \
                "This Mac has joined these before. It shows they have a hotspot available. The full list with dates was blocked, so this comes from the saved names only."
        elif [ -n "$list" ]; then
            add_row Saved "$d2" "None (from saved names, no dates)" "OK" ok ""
        else
            add_row Saved "$d2" "Could not be read" "UNKNOWN" note "$why"
        fi
        return
    fi
    while IFS="$(printf '\t')" read -r joined hot name; do
        [ -z "$name" ] && continue
        if [ "$joined" -ge "$boot" ] && [ "$joined" -gt 0 ]; then
            count=$((count + 1))
            names="${names:+$names, }$name"
            [ "$joined" -gt "$last" ] && last="$joined"
            EVENTS="${EVENTS}  $(fmt_time "$joined")  joined  $name
"
            if [ "$hot" = 1 ] || is_hotspot_name "$name"; then hotnames="${hotnames:+$hotnames, }$name"; fi
        fi
        if [ "$hot" = 1 ] || is_hotspot_name "$name"; then
            if [ "$joined" -gt 0 ]; then saved="${saved:+$saved, }$name (last joined $(fmt_time "$joined"))"
            else saved="${saved:+$saved, }$name"; fi
        fi
    done <<EOF
$(printf '%s\n' "$known" | sort -n)
EOF
    why=""
    [ "$count" -gt 1 ] && why="this Mac has joined $count different networks since boot"
    if [ "$last" -gt 0 ]; then
        ago=$(( (now - last) / 60 )); since=$(( (last - boot) / 60 ))
        if [ "$ago" -le "$RECENT_SWITCH_MINUTES" ] && [ "$since" -gt 10 ]; then
            why="${why:+$why; }it joined a network $ago minute(s) ago"
        fi
    fi
    [ -n "$hotnames" ] && why="${why:+$why; }it used a hotspot: $hotnames"
    if [ -n "$why" ]; then
        add_row Switches "$d1" "$count network(s): $names" "CHANGED" warn \
            "Reason: $why. macOS only keeps the last time each network was joined, so compare those times with when the screenshare was called."
    elif [ "$count" -gt 0 ]; then
        add_row Switches "$d1" "$count network(s): $names" "OK" ok ""
    else
        add_row Switches "$d1" "None (wired, or on the same network since before boot)" "OK" ok ""
    fi
    if [ -n "$saved" ]; then
        add_row Saved "$d2" "$saved" "FOUND" note \
            "This Mac has joined these before. It shows they have a hotspot available. The date is the last time it was used here."
    else
        add_row Saved "$d2" "None" "OK" ok ""
    fi
}

run_scan() {
    R_NAME=(); R_DISPLAY=(); R_FOUND=(); R_RESULT=(); R_LEVEL=(); R_DETAIL=(); EVENTS=""; GW_WIFI_KIND=""
    SCAN_NOW="$(src_now)"
    SCAN_BOOT="$(src_boot)"
    [ -z "$SCAN_BOOT" ] && SCAN_BOOT=0
    check_gateway
    check_sharing "$SCAN_NOW"
    check_services
    check_wifi
    check_known "$SCAN_BOOT" "$SCAN_NOW"
}

# =============================================================================
#  OUTPUT
# =============================================================================
print_rows() {  # $1 = 1 for colors
    local i color reset=""
    for i in "${!R_NAME[@]}"; do
        color=""
        if [ "$1" = 1 ]; then
            reset="$(printf '\033[0m')"
            case "${R_LEVEL[$i]}" in
                ok)   color="$(printf '\033[32m')" ;;
                warn) color="$(printf '\033[33m')" ;;
                bad)  color="$(printf '\033[1;31m')" ;;
                *)    color="$(printf '\033[90m')" ;;
            esac
        fi
        printf '%s[%s]%s %s: %s\n' "$color" "${R_RESULT[$i]}" "$reset" "${R_DISPLAY[$i]}" "${R_FOUND[$i]}"
        [ -n "${R_DETAIL[$i]}" ] && printf '      %s\n' "${R_DETAIL[$i]}"
    done
    printf '\nNetworks joined since boot:\n'
    if [ -n "$EVENTS" ]; then printf '%s' "$EVENTS"; else printf '  none listed\n'; fi
}

json_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

write_json() {
    local i last=$(( ${#R_NAME[@]} - 1 )) comma
    {
        printf '[\n'
        for i in "${!R_NAME[@]}"; do
            comma=","; [ "$i" = "$last" ] && comma=""
            printf '  {"Name": "%s", "Display": "%s", "Found": "%s", "Result": "%s", "Level": "%s", "Detail": "%s"}%s\n' \
                "$(json_escape "${R_NAME[$i]}")" "$(json_escape "${R_DISPLAY[$i]}")" "$(json_escape "${R_FOUND[$i]}")" \
                "$(json_escape "${R_RESULT[$i]}")" "$(json_escape "${R_LEVEL[$i]}")" "$(json_escape "${R_DETAIL[$i]}")" "$comma"
        done
        printf ']\n'
    } > "$1"
}

save_report() {
    local path root="no"
    mkdir -p "$OUT_DIR" 2>/dev/null || return 1
    path="$OUT_DIR/scan_$(date '+%Y%m%d_%H%M%S').txt"
    src_is_root && root="yes"
    {
        echo "Hotspot Checker report (Mac)"
        echo "Computer: $(hostname 2>/dev/null)   User: ${SUDO_USER:-${USER:-unknown}}"
        echo "Scan time: $(fmt_time "$SCAN_NOW")   Boot time: $(fmt_time "$SCAN_BOOT")"
        echo "Run with sudo: $root"
        echo
        print_rows 0
    } > "$path" 2>/dev/null || return 1
    chmod -R a+rX "$OUT_DIR" 2>/dev/null
    printf '%s' "$path"
}

main() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --json) JSON_PATH="${2:-}"; shift ;;
            --out)  OUT_DIR="${2:-$OUT_DIR}"; shift ;;
            -h|--help) sed -n '3,25p' "$0" 2>/dev/null; return 0 ;;
        esac
        shift
    done
    if [ "$(uname -s)" != "Darwin" ]; then
        echo "This is the Mac version. On Windows use HotspotChecker.exe." >&2
        return 1
    fi
    local colors=0 bad=0 warn=0 i path
    [ -t 1 ] && colors=1
    echo "Hotspot Checker (Mac)"
    if ! src_is_root; then echo "Not run with sudo, so the saved-network checks will be skipped."; fi
    echo "Scanning, the Wi-Fi lookup takes a few seconds..."
    echo
    run_scan
    print_rows "$colors"
    for i in "${!R_LEVEL[@]}"; do
        case "${R_LEVEL[$i]}" in bad) bad=$((bad + 1)) ;; warn) warn=$((warn + 1)) ;; esac
    done
    echo
    if [ "$bad" = 0 ] && [ "$warn" = 0 ]; then echo "Summary: nothing points at a shared connection."
    else echo "Summary: $bad strong sign(s), $warn thing(s) to ask about."; fi
    path="$(save_report)" && echo "Report saved to $path"
    [ -n "$JSON_PATH" ] && write_json "$JSON_PATH"
    return 0
}

if [ "${HC_LIB:-0}" != "1" ]; then
    main "$@"
fi
