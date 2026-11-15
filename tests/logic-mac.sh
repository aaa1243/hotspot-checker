#!/bin/bash
# Logic test for the Mac version. Loads the checks out of hotspot-checker-mac.sh,
# swaps every command that reads the Mac for fake output, and checks each setup
# gets the right result. Runs on macOS and Linux, no sudo needed.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC2034
HC_LIB=1
# shellcheck source=/dev/null
. "$HERE/../hotspot-checker-mac.sh"

FAILS=0
check() {  # what, got, want
    if [ "$2" = "$3" ]; then echo "  ok    $1"; else echo "  FAIL  $1: got \"$2\", wanted \"$3\""; FAILS=$((FAILS + 1)); fi
}
has() {  # what, text, part
    case "$2" in *"$3"*) echo "  ok    $1" ;; *) echo "  FAIL  $1: \"$3\" not in \"$2\""; FAILS=$((FAILS + 1)) ;; esac
}

NOW=1794700000            # fixed "now" so the tests do not depend on the clock
iso() { date -u -r "$1" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -d "@$1" '+%Y-%m-%dT%H:%M:%SZ'; }

reset_fake() {
    F_BOOT=$((NOW - 18000))
    F_ROOT=1
    F_ROUTES="Routing tables

Internet:
Destination        Gateway            Flags               Netif Expire
default            192.168.1.1        UGScg                 en0
127                127.0.0.1          UCS                   lo0
192.168.1          link#12            UCS                   en0      !"
    F_PORTS="
Hardware Port: Wi-Fi
Device: en0
Ethernet Address: 00:00:00:00:00:00

Hardware Port: Thunderbolt Bridge
Device: bridge0
Ethernet Address: 00:00:00:00:00:00
"
    F_IFLIST="lo0 gif0 stf0 en0 bridge0 utun0"
    F_WIFI_STATUS="active"
    F_BRIDGE_IP=""
    F_NAT=""
    F_ARP=""
    F_LEASES=""
    F_PROCS="Sat Nov 14 08:00:00 2026 /sbin/launchd
Sat Nov 14 08:00:05 2026 /usr/libexec/configd"
    F_SSID="HomeWifi"
    F_KNOWN=""
}
known_xml() {  # pairs of: name, joined epoch (0 = never), hotspot flag
    echo '<?xml version="1.0" encoding="UTF-8"?>'
    echo '<plist version="1.0">'
    echo '<dict>'
    while [ $# -gt 0 ]; do
        printf '\t<key>wifi.network.ssid.%s</key>\n\t<dict>\n' "$1"
        printf '\t\t<key>AddedAt</key>\n\t\t<date>2020-01-01T00:00:00Z</date>\n'
        printf '\t\t<key>BSSList</key>\n\t\t<array>\n\t\t\t<dict>\n\t\t\t\t<key>LastAssociatedAt</key>\n\t\t\t\t<date>2030-01-01T00:00:00Z</date>\n\t\t\t</dict>\n\t\t</array>\n'
        [ "$2" != 0 ] && printf '\t\t<key>JoinedBySystemAt</key>\n\t\t<date>%s</date>\n' "$(iso "$2")"
        printf '\t\t<key>PersonalHotspot</key>\n\t\t<%s/>\n' "$([ "$3" = 1 ] && echo true || echo false)"
        printf '\t\t<key>__OSSpecific__</key>\n\t\t<dict>\n\t\t\t<key>IsPersonalHotspot</key>\n\t\t\t<%s/>\n\t\t\t<key>CaptiveBypass</key>\n\t\t\t<true/>\n\t\t</dict>\n' "$([ "$3" = 2 ] && echo true || echo false)"
        printf '\t</dict>\n'
        shift 3
    done
    echo '</dict>'
    echo '</plist>'
}

src_now()         { echo "$NOW"; }
src_boot()        { echo "$F_BOOT"; }
src_is_root()     { [ "$F_ROOT" = 1 ]; }
src_routes()      { echo "$F_ROUTES"; }
src_ports()       { echo "$F_PORTS"; }
src_iflist()      { echo "$F_IFLIST"; }
src_ifconfig()    {
    case "$1" in
        en0)       printf 'en0: flags=8863<UP> mtu 1500\n\tinet 192.168.1.50 netmask 0xffffff00 broadcast 192.168.1.255\n\tstatus: %s\n' "$F_WIFI_STATUS" ;;
        bridge100) [ -n "$F_BRIDGE_IP" ] && printf 'bridge100: flags=8863<UP> mtu 1500\n\tinet %s netmask 0xffffff00 broadcast 192.168.2.255\n\tstatus: active\n' "$F_BRIDGE_IP" ;;
    esac
}
src_nat_enabled() { echo "$F_NAT"; }
src_arp()         { echo "$F_ARP"; }
src_leases()      { echo "$F_LEASES"; }
src_procs()       { echo "$F_PROCS"; }
src_wifi_info()   { printf 'Wi-Fi:\n\n      Interfaces:\n        en0:\n          Status: Connected\n          Current Network Information:\n            %s:\n              PHY Mode: 802.11ax\n          Other Local Wi-Fi Networks:\n            Neighbour:\n' "$F_SSID"; }
src_known_xml()   { printf '%s\n' "$F_KNOWN"; }

echo "1. Normal Mac on a home router"
reset_fake
F_KNOWN="$(known_xml HomeWifi $((NOW - 400000)) 0 "Coffee Shop" $((NOW - 9000000)) 0)"
run_scan
check "five checks give six rows" "${#R_NAME[@]}" 6
for n in Gateway Sharing Services Wifi Switches Saved; do check "$n is clean" "$(row_field $n LEVEL)" ok; done
has "gateway names the port" "$(row_field Gateway FOUND)" "192.168.1.1 on en0 (Wi-Fi)"

echo "2. Connected through a Windows PC"
reset_fake
F_ROUTES="default            192.168.137.1      UGScg                 en0"
F_SSID="DESKTOP-AB12CDE 4821"
run_scan
check "gateway result" "$(row_field Gateway RESULT)" "THROUGH ANOTHER PC"
check "gateway level"  "$(row_field Gateway LEVEL)" bad
check "wifi result"    "$(row_field Wifi RESULT)" "LOOKS LIKE A HOTSPOT"
check "not flagged as the one sharing" "$(row_field Sharing LEVEL)" ok

echo "3. This Mac shares its internet with one device on it"
reset_fake
F_NAT=1; F_IFLIST="lo0 en0 bridge0 bridge100"; F_BRIDGE_IP="192.168.2.1"
F_ARP="? (192.168.2.1) at 3e:22:fb:0:0:64 on bridge100 ifscope permanent [bridge]
? (192.168.2.2) at a4:5e:60:11:22:33 on bridge100 ifscope [bridge]
? (192.168.2.9) at (incomplete) on bridge100 ifscope [bridge]
? (192.168.2.255) at ff:ff:ff:ff:ff:ff on bridge100 ifscope [bridge]
? (224.0.0.251) at 1:0:5e:0:0:fb on bridge100 ifscope permanent [ethernet]"
F_PROCS="$F_PROCS
Sat Nov 14 09:12:44 2026 /usr/libexec/InternetSharing
Sat Nov 14 09:12:50 2026 /usr/libexec/bootpd"
run_scan
check "sharing result" "$(row_field Sharing RESULT)" "SHARING, DEVICE CONNECTED"
check "sharing level"  "$(row_field Sharing LEVEL)" bad
has   "counts one device" "$(row_field Sharing FOUND)" "1 device(s) connected"
check "services result" "$(row_field Services RESULT)" RUNNING
has   "services start time" "$(row_field Services FOUND)" "InternetSharing (started Sat Nov 14 09:12:44 2026)"
check "gateway stays clean" "$(row_field Gateway LEVEL)" ok

echo "4. Sharing on, device left but its address has not run out"
F_ARP=""
F_LEASES="{
	name=SOME-PC
	ip_address=192.168.2.2
	hw_address=1,a4:5e:60:11:22:33
	lease=0x$(printf '%x' $((NOW + 1200)))
}
{
	name=old
	ip_address=192.168.2.3
	lease=0x$(printf '%x' $((NOW - 90000)))
}"
run_scan
check "sharing result" "$(row_field Sharing RESULT)" "SHARING, DEVICE WAS CONNECTED"
has   "counts only the live lease" "$(row_field Sharing FOUND)" "1 device(s) recently"

echo "5. Sharing on, nothing connected"
F_LEASES=""
run_scan
check "sharing result" "$(row_field Sharing RESULT)" SHARING
check "sharing level"  "$(row_field Sharing LEVEL)" warn

echo "6. Virtual machine network is only a note"
reset_fake
F_IFLIST="lo0 en0 bridge100"; F_BRIDGE_IP="192.168.64.1"
F_ARP="? (192.168.64.2) at 52:54:0:11:22:33 on bridge100 ifscope [bridge]"
run_scan
check "vm result" "$(row_field Sharing RESULT)" "VIRTUAL NETWORK"
check "vm level"  "$(row_field Sharing LEVEL)" note

echo "7. Phone hotspots and tethering"
for pair in "192.168.43.1|Android phone" "172.20.10.1|iPhone hotspot" "192.168.42.129|USB tethering"; do
    reset_fake
    F_ROUTES="default            ${pair%%|*}        UGScg                 en0"
    run_scan
    check "${pair%%|*} result" "$(row_field Gateway RESULT)" HOTSPOT
    has   "${pair%%|*} names the device" "$(row_field Gateway DETAIL)" "${pair##*|}"
done
reset_fake
F_ROUTES="default            10.44.0.1          UGScg                 en7"
F_PORTS="$F_PORTS
Hardware Port: iPhone USB
Device: en7
Ethernet Address: 00:00:00:00:00:00"
run_scan
check "iPhone USB port result" "$(row_field Gateway RESULT)" HOTSPOT
has   "iPhone USB port named"  "$(row_field Gateway DETAIL)" "iPhone or iPad over USB"

echo "8. 192.168.2.x gateway is a note, not a flag"
reset_fake
F_ROUTES="default            192.168.2.1        UGScg                 en0"
run_scan
check "result" "$(row_field Gateway RESULT)" "POSSIBLE MAC SHARING"
check "level"  "$(row_field Gateway LEVEL)" note

echo "9. Joined a hotspot right before the screenshare"
reset_fake
F_KNOWN="$(known_xml HomeWifi $((NOW - 17000)) 0 "Liam's iPhone" $((NOW - 300)) 1 OldPlace $((NOW - 9000000)) 0)"
run_scan
check "switch result" "$(row_field Switches RESULT)" CHANGED
has "counts two networks" "$(row_field Switches DETAIL)" "2 different networks"
has "says how recent"     "$(row_field Switches DETAIL)" "5 minute(s) ago"
has "names the hotspot"   "$(row_field Switches DETAIL)" "Liam's iPhone"
has "old network left out" "$(row_field Switches FOUND)" "2 network(s): HomeWifi, Liam's iPhone"
check "saved result" "$(row_field Saved RESULT)" FOUND
has "saved has the last join time" "$(row_field Saved FOUND)" "Liam's iPhone (last joined "
has "log lists the join" "$EVENTS" "joined  Liam's iPhone"

echo "10. Joining once at boot is not a switch"
reset_fake
F_BOOT=$((NOW - 480))
F_KNOWN="$(known_xml HomeWifi $((NOW - 420)) 0)"
run_scan
check "fresh boot stays clean" "$(row_field Switches LEVEL)" ok

echo "11. Saved hotspot marked by macOS even with a plain name"
reset_fake
F_KNOWN="$(known_xml HomeWifi $((NOW - 400000)) 0 "Bob" 0 1 "Tom &amp; Jerry" $((NOW - 800000)) 0)"
run_scan
check "saved level" "$(row_field Saved LEVEL)" note
check "saved found" "$(row_field Saved FOUND)" "Bob"
has "xml names decoded" "$(src_known_xml | parse_known)" "Tom & Jerry"
F_KNOWN="$(known_xml HomeWifi $((NOW - 400000)) 0 "Nested" 0 2)"
run_scan
check "hotspot flag one level down" "$(row_field Saved FOUND)" "Nested"

echo "12. No sudo, and Wi-Fi name hidden"
reset_fake
F_ROOT=0; F_SSID="<redacted>"
run_scan
check "switches unknown" "$(row_field Switches RESULT)" UNKNOWN
has   "says to use sudo" "$(row_field Switches DETAIL)" "sudo"
check "wifi hidden is a note" "$(row_field Wifi LEVEL)" note
F_WIFI_STATUS="inactive"
run_scan
check "wifi off" "$(row_field Wifi FOUND)" "Not on Wi-Fi"

echo "13. Name matching"
for n in "John's iPhone" "Galaxy A54 5G" "AndroidAP_1234" "DIRECT-xy-HP OfficeJet" "DESKTOP-9K2LM4P 7731" "Pixel 8" "moto g54"; do
    is_hotspot_name "$n" && r=yes || r=no; check "hotspot name: $n" "$r" yes
done
for n in "NETGEAR-5G" "Vivo Fibra 2.4" "Xfinity" "TP-Link_A1B2" "eduroam" "PixelPerfect Studio" "Motown Cafe"; do
    is_hotspot_name "$n" && r=yes || r=no; check "router name: $n" "$r" no
done

echo "14. Report and JSON"
reset_fake
OUT_DIR="${TMPDIR:-/tmp}/hotspot-mac-logic.$$"
run_scan
path="$(save_report)"
[ -f "$path" ] && r=yes || r=no; check "report written" "$r" yes
write_json "$OUT_DIR/out.json"
has "json has the rows" "$(cat "$OUT_DIR/out.json")" '"Name": "Gateway"'
rm -rf "$OUT_DIR"

if [ "$FAILS" -gt 0 ]; then echo "$FAILS check(s) failed"; exit 1; fi
echo "LOGIC TEST PASSED"
