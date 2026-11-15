#!/bin/bash
# Self-test for CI on a real Mac. Runs the real scan with sudo and checks it
# finishes, writes its files, does not flag a normal build machine, and can
# read a saved-network list that macOS itself wrote in its binary format.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
TOOL="$HERE/../hotspot-checker-mac.sh"
OUT="$(mktemp -d)"
fail() { echo "FAILED: $1"; exit 1; }

echo "=== 1. Build a saved-network list the way macOS stores it ==="
NOW="$(date +%s)"
JOINED="$(date -u -r $((NOW - 5)) '+%Y-%m-%dT%H:%M:%SZ')"
cat > "$OUT/known.plist" <<XML
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>wifi.network.ssid.Office &amp; Lab</key>
	<dict>
		<key>AddedAt</key>
		<date>2020-01-01T00:00:00Z</date>
		<key>JoinedByUserAt</key>
		<date>2021-06-01T12:00:00Z</date>
		<key>SSID</key>
		<data>T2ZmaWNl</data>
	</dict>
	<key>wifi.network.ssid.Test Hotspot Phone</key>
	<dict>
		<key>JoinedBySystemAt</key>
		<date>$JOINED</date>
		<key>PersonalHotspot</key>
		<true/>
	</dict>
</dict>
</plist>
XML
plutil -convert binary1 "$OUT/known.plist" || fail "plutil could not convert the test list"
file "$OUT/known.plist"

echo "=== 2. Real scan ==="
sudo HC_KNOWN_PLIST="$OUT/known.plist" /bin/bash "$TOOL" --json "$OUT/scan.json" --out "$OUT/reports" || fail "scan exited with an error"
[ -f "$OUT/scan.json" ] || fail "no JSON written"
cat "$OUT/scan.json"
[ "$(grep -c '"Name":' "$OUT/scan.json")" = 6 ] || fail "expected 6 rows"
ls "$OUT/reports"/scan_*.txt >/dev/null 2>&1 || fail "no report written"

echo "=== 3. A build machine on a normal network must not be flagged ==="
grep '"Name": "Gateway"' "$OUT/scan.json" | grep -Eq '"Found": "[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+ on ' || fail "gateway row found no gateway"
grep '"Name": "Gateway"' "$OUT/scan.json" | grep -q '"Level": "bad"' && fail "gateway was flagged"
grep '"Name": "Sharing"' "$OUT/scan.json" | grep -q '"Level": "bad"' && fail "sharing was flagged"

echo "=== 4. The saved-network list was read through the real plutil ==="
grep '"Name": "Switches"' "$OUT/scan.json" | grep -q 'Test Hotspot Phone' || fail "the network joined a moment ago is missing"
grep '"Name": "Switches"' "$OUT/scan.json" | grep -q 'Office' && fail "a network joined years ago was counted as since boot"
grep '"Name": "Saved"' "$OUT/scan.json" | grep -q '"Result": "FOUND"' || fail "the saved hotspot was not found"

echo "=== 5. Run through a pipe, the way the one-liner does ==="
# shellcheck disable=SC2024
cat "$TOOL" | sudo HC_KNOWN_PLIST="$OUT/known.plist" /bin/bash -s -- --out "$OUT/reports2" > "$OUT/pipe.txt" || fail "piped run exited with an error"
grep -q 'Summary:' "$OUT/pipe.txt" || fail "piped run printed no summary"

echo "SELF-TEST PASSED"
