# Hotspot Checker

A small tool for Minecraft screenshares, for Windows and Mac. It checks whether the computer you are screensharing is sharing its internet with another device, or getting its internet through one.

That matters because of "fakers": someone plays on one PC and gets screenshared on a clean one next to it. To keep the same IP as the account that was in game, the two PCs share one connection, usually through Windows Mobile Hotspot, Internet Connection Sharing or a phone. This tool shows that setup in one window.

It only reads. It changes nothing on the computer.

Windows gets a window (`HotspotChecker.exe`). Mac gets a Terminal script (`hotspot-checker-mac.sh`). Both run the same kind of checks. The sections below are for Windows, the Mac part is under [On a Mac](#on-a-mac).

## Download

    https://github.com/aaa1243/hotspot-checker/releases/latest/download/HotspotChecker.exe

Windows shows an "unknown publisher" warning because the exe is not signed. Click Run.

## Run it without downloading

From an admin CMD or PowerShell on the player's PC:

    powershell -ExecutionPolicy Bypass -Command "iex (irm https://raw.githubusercontent.com/aaa1243/hotspot-checker/main/HotspotChecker.ps1)"

That opens the same window as the exe. If you want plain text in the console instead:

    powershell -ExecutionPolicy Bypass -Command "& ([scriptblock]::Create((irm https://raw.githubusercontent.com/aaa1243/hotspot-checker/main/HotspotChecker.ps1))) -NoGui"

A one-liner like this runs whatever is at that link at that moment, so only ever use the link to this repo.

## How to use it

1. Run `HotspotChecker.exe` on the player's PC and accept the admin prompt.
2. Read the RESULT column. Click a row to see what the result means.
3. Check the log box at the bottom. It lists every network connect and disconnect since the PC booted, with times.
4. Take your screenshot. A report is already saved in `C:\SSTools\HotspotChecker`.

## What it checks

| Check | What it looks at | Flags |
| --- | --- | --- |
| Where this PC gets its internet | The gateway address | `THROUGH ANOTHER PC` when the gateway is 192.168.137.x, which is what a Windows PC hands out when it shares its connection. `HOTSPOT` for phone hotspot and tethering ranges. `POSSIBLE MAC SHARING` (only a note) for 192.168.2.x, which a Mac hands out when it shares but normal routers use too. |
| Is this PC sharing its connection | Whether Mobile Hotspot is on, whether this PC holds 192.168.137.1, and how many devices are on it | `SHARING, DEVICE CONNECTED` or `SHARING` |
| Internet Connection Sharing | The Windows setting that shares one adapter with another, like Wi-Fi to an Ethernet cable | `ENABLED` |
| Hotspot and sharing services | Whether `icssvc` and `SharedAccess` are running and when they started | `RUNNING` |
| Current Wi-Fi network | The network name and whether the access point looks like a phone or PC | `LOOKS LIKE A HOTSPOT` |
| Network changes since boot | Connect and disconnect events Windows logged this session | `CHANGED` when it used more than one network, joined one in the last 30 minutes, or used one that looks like a hotspot |
| Saved hotspot networks | Saved Wi-Fi networks whose names look like a hotspot | `FOUND` (only a note) |

## On a Mac

Open Terminal on the player's Mac and run:

    curl -fsSL https://raw.githubusercontent.com/aaa1243/hotspot-checker/main/hotspot-checker-mac.sh | sudo bash

It asks for the Mac's password because of `sudo`. Without `sudo` it still runs, but it cannot read the saved Wi-Fi list, so two checks say `UNKNOWN`. Only ever use the link to this repo.

If you downloaded the file instead:

    sudo bash hotspot-checker-mac.sh

Results print in Terminal with the same colors (red, yellow, grey) and a report is saved in `/Users/Shared/SSTools/HotspotChecker`.

| Check | What it looks at | Flags |
| --- | --- | --- |
| Where this Mac gets its internet | The gateway address and which port it is on (Wi-Fi, Ethernet, iPhone USB and so on) | `THROUGH ANOTHER PC`, `HOTSPOT`, `POSSIBLE MAC SHARING` (note) |
| Is this Mac sharing its connection | The Internet Sharing switch, the shared network it creates, devices on it now, and devices that got an address from it recently | `SHARING, DEVICE CONNECTED`, `SHARING, DEVICE WAS CONNECTED`, `SHARING`, `VIRTUAL NETWORK` (note) |
| Sharing services | Whether the Internet Sharing processes are running and when they started | `RUNNING` (note) |
| Current Wi-Fi network | The network name, when macOS lets Terminal see it | `LOOKS LIKE A HOTSPOT` |
| Networks joined since boot | Saved networks whose last join time is after the Mac booted (needs sudo) | `CHANGED` when it joined more than one, joined one in the last 30 minutes, or used a hotspot |
| Saved hotspot networks | Saved networks that macOS marked as a hotspot or that have a hotspot-looking name, with the last time each was joined (needs sudo) | `FOUND` (note) |

Mac things to know:

- Newer macOS hides the current Wi-Fi name from Terminal. When that happens the tool says so. Have them click the Wi-Fi icon in the menu bar and read it there.
- macOS only keeps the last time each network was joined, not every connect and disconnect like Windows does.
- Virtual machine apps (Parallels, UTM, Docker) make the same kind of shared network that Internet Sharing does. That is why a shared network with the switch off is only a note.
- If the saved-network checks say they could not be read even with sudo, Terminal needs Full Disk Access in System Settings, Privacy and Security.

## Reading the results

Red means a strong sign of a two-PC setup. Yellow means ask about it. Grey is a note.

None of this is a ban on its own. Lots of people use a phone hotspot because their internet is bad, or share their connection with a console. Use it as a reason to ask questions:

- `THROUGH ANOTHER PC`: ask to see the other PC. That one is the PC to screenshare.
- `SHARING, DEVICE CONNECTED`: ask what the connected device is and have them show it.
- `CHANGED` a few minutes before you called the SS: ask why they switched networks.

If the story does not add up, follow your server's rules for refusing or failing a screenshare.

## What it does not show

- No public IP address.
- No MAC addresses.
- No full list of saved Wi-Fi networks. Only the ones with hotspot-looking names.

A screenshare should not turn into collecting someone's network details, so those are left out on purpose.

## Limits

- It cannot see a second PC that sits behind the same normal router. Two PCs on one home network look like any other house.
- A phone that shares the house Wi-Fi with both computers is just a normal network. Nothing here flags that.
- A hotspot can be renamed to look like a router. The gateway check still catches the default address ranges, but those can be changed too by someone who knows how.
- On newer Windows 11 the Wi-Fi name is hidden while Location is turned off. The tool says so when that happens.
- The device count is what Windows reports right now. A device that disconnected before the scan does not show, which is why the services and event checks are there.

## Build it yourself

    Install-Module ps2exe -Scope CurrentUser
    Invoke-ps2exe .\HotspotChecker.ps1 .\HotspotChecker.exe -noConsole -requireAdmin -STA

The workflow in `.github/workflows/build.yml` does this on every push and attaches the exe to a release when you push a `v*` tag.

## Tests

    powershell -ExecutionPolicy Bypass -File tests\logic.ps1
    powershell -ExecutionPolicy Bypass -File tests\selftest.ps1

`logic.ps1` feeds the checks fake network setups (normal router, behind another PC, hosting a hotspot, phone tethering and so on) and checks each one gets the right result. `selftest.ps1` runs a real scan on the machine it is on.

The Mac version has the same two:

    bash tests/logic-mac.sh
    bash tests/selftest-mac.sh

`logic-mac.sh` also runs on Linux because every Mac command is faked. `selftest-mac.sh` needs a real Mac and sudo.

## Credits

The idea comes from the hotspot scripts in [praiselily/lilith-ps](https://github.com/praiselily/lilith-ps) and [quickpots/ScreenSharing](https://github.com/quickpots/ScreenSharing). This is a separate tool written from scratch, not a copy of either.

## License

MIT
