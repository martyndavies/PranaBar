# PranaBar

A macOS menu bar app for Prana recuperators. It talks straight to the unit over its local HTTP API, so it needs no cloud account and keeps working without internet. Tested against a Prana 150 on firmware 49.

## What it does

- **Menu bar:** a fan icon with the current speed (1–6, or B for Boost). It's dimmed when the unit is off and becomes a warning triangle when the unit can't be reached.
- **Glance view:** click the icon to see whether the unit is running and in which mode, plus:
  - fan speed for air in and out, with the outside and inside temperatures
  - room humidity
  - air pressure as Low, Normal or High (once you set your altitude), with its 3-hour trend (rising, steady or falling)
- **Controls:** open "Controls" in the popover to set:
  - fan speed, either linked or with supply and extract separately
  - modes: Night, Boost, Auto, Auto+, Winter and Heater
  - the brightness of the unit's display

  It also shows CO₂ and VOC if your model reports them.
- **More than one unit:** on first launch PranaBar finds every unit on the network and adds them. One unit is the default, shown in the menu bar and each time the popover opens. Click the unit's name in the popover to look at another.
- **Settings:** add or remove units, choose the default unit, set your altitude so pressure matches weather forecasts, and turn on launch at login.

The unit answers "ok" even to commands it ignores, so PranaBar re-reads it after every change. If a change didn't take, the popover tells you, for example "The unit didn't link the fans".

## Requirements

- **A Mac on macOS 14 (Sonoma) or later.**
- **Xcode 15 or later, or just the Command Line Tools** (`xcode-select --install`). Either gives you Swift 5.9+. There are no third-party dependencies.
- **A Prana unit on the same network as the Mac,** with its local API. Units on a separate network segment (a guest or IoT network, say) can't be found automatically, but you can add them by IP address if your router lets the two networks talk.

## Build your own

```sh
git clone https://github.com/martyndavies/PranaBar.git
cd PranaBar
scripts/test.sh                       # run the tests
scripts/bundle.sh                     # build build/PranaBar.app
cp -R build/PranaBar.app /Applications/
open /Applications/PranaBar.app
```

- **Use `scripts/test.sh` rather than `swift test`.** With only the Command Line Tools, plain `swift test` silently runs no tests. The script passes the framework paths it needs and works with Xcode too.
- **`scripts/bundle.sh`** builds a release app and signs it ad hoc (no Apple developer account needed). Because you built it on your own Mac, Gatekeeper doesn't block it.
- **`swift run PranaBar`** runs it straight from the terminal while developing. Launch at login only works from the bundled app.
- To work in Xcode, open `Package.swift`.
- The bundle ID is set in `Support/Info.plist` (`me.martyndavies.PranaBar`). Change it if you're publishing your own fork.

On first launch macOS asks to let PranaBar find devices on your local network. Allow it, or PranaBar can't reach the unit. If you said no, turn it on in System Settings → Privacy & Security → Local Network.

PranaBar then searches for units and adds what it finds. If yours doesn't show up, open Settings → Units → Add a Unit… and enter its IP address. Your router's device list will show it.

## How units are found

On first launch PranaBar searches the network with Bonjour (Apple's way for devices to announce themselves) and adds every unit it finds. It stops searching 30 seconds after the first one is added. If it finds nothing, it tries again on the next launch. After that it only searches:

- while the Add a Unit sheet is open in Settings
- while a saved unit isn't answering, in case the router gave it a new address. When it reappears, PranaBar follows it to that address.

Searches are logged under category `discovery`: `log stream --predicate 'category == "discovery"'`.

## Development

- `Sources/PranaKit`: Foundation-only models and the `PranaClient` actor. It has no UI, so it can be reused in a CLI, App Intents or widgets.
- `Sources/PranaBar`: the SwiftUI `MenuBarExtra` app.
  - `Units` owns the saved units (`SavedUnit` in PranaKit), with one `PranaStore` each, the default unit and the shared altitude setting. It also runs `UnitBrowser` (Bonjour).
  - Each `PranaStore` polls every 3 s while its unit is on screen and every 45 s otherwise. It applies changes straight away, then re-reads the unit.
- `Support/Info.plist`: hides the Dock icon (`LSUIElement`) and holds the network settings:
  - ATS local networking and the local network usage string
  - `NSBonjourServices` (`_prana._tcp`), since macOS won't search for a service the app hasn't declared

  It's embedded into the binary for `swift run` and copied into the bundle by `scripts/bundle.sh`.
- `scripts/spike.sh <host> [--write]`: curl checks against a unit's API. Read-only unless you pass `--write`, which changes the unit's settings.
- `scripts/fake-units.py`: fake units, for trying more than one without owning them.
  - `sudo scripts/fake-units.py Loft Bedroom` puts each on its own loopback address (127.0.0.11 onwards), serves the API on port 80 there and announces it over Bonjour like a real unit. PranaBar finds them with its normal code.
  - It copies the real unit's known quirks: writes ×10, the brightness encoding, "ok" to everything, and Auto+ blocking the link.
  - It needs root for the addresses and port 80. Ctrl-C removes the addresses. Remove the fake units in Settings afterwards, or they'll show as offline.

## Prana local API

Plain HTTP on port 80, no auth.

| Call | Method | Body |
|---|---|---|
| `/info` | GET | |
| `/getState` | GET | |
| `/setSpeed` | POST | `{"speed": 10..60, "fanType": "bounded"\|"supply"\|"extract"}` |
| `/setSpeedIsOn` | POST | `{"value": bool, "fanType": ...}` |
| `/setSwitch` | POST | `{"switchType": "bound"\|"heater"\|"night"\|"boost"\|"auto"\|"auto_plus"\|"winter", "value": bool}` |
| `/setBrightness` | POST | `{"brightness": 0\|1\|2\|4\|8\|16\|32}` |

- Commands answer HTTP 200 with `{"result":"ok"}` (served as `text/html`), including commands the unit then ignores. A malformed command (unknown switch or fan type, speed out of range, missing fields) gets HTTP 400 instead, and an unknown path 404. An invalid brightness value (5) still got "ok". The client treats any `result` other than "ok" as a rejection, though none has been seen.
- Speed reads back as a level (1–6) but is written as level × 10.
- Brightness reads back as a level (0–6) but is written as the value at that position in `[0, 1, 2, 4, 8, 16, 32]`: writing 4 reads back 3, writing 8 reads back 4.
- The unit doesn't keep the speed modes fully exclusive: it reports Night alongside Auto+ or Auto at level 1. PranaBar treats Night, Boost, Auto and Auto+ as one group and switches the others off when you pick one. Winter and Heater are independent.
- Night appears to follow the fan speed rather than the switch: setting supply to level 2 cleared it, and setting it back to 1 brought it back. `setSwitch` night=false is answered `{"result":"ok"}` but ignored (seen twice, with Auto+ on and off). So the popover highlights only one speed mode, ranked Boost, Auto+, Auto, Night (`PranaState.activeFanMode`).
- `air_pressure` looks like mmHg (728–730 here). The popover shows it as a Low / Normal / High band plus a 3-hour trend, with the hPa figure only in the hover hint. The trend (`PressureHistory`) is averaged over 15 minutes at each end because the unit only reports whole mmHg. The history lives in memory, so the trend takes an hour to appear after launch. Set the unit's altitude in Settings and the reading is corrected to sea level (`Pressure.seaLevel`, standard barometric formula using the outside temperature), so it matches forecasts. At 0 m it shows the raw reading, which is lower than the forecast by about 1 hPa per 8 m of altitude. The trend is worked out on the raw readings; the correction barely changes it. The band (Low < 1000 hPa, Normal, High > 1025 hPa, `PressureLevel`) needs an altitude; without one the row offers "Set altitude…" instead, because the raw reading would always look low.
- Temperatures are tenths of °C. The 150 sends `outside_temperature_2` rather than `outside_temperature`.
- When `bound` is true use `fanType: "bounded"`; otherwise set supply and extract separately.
- `setSwitch` doesn't treat `value` the same way for every switch (tested 2026-11-19 by sending each switch the value it already had):
  - `auto_plus` and `winter` toggle and ignore `value`: `auto_plus=false` while it's off turns it on.
  - `heater`, `auto`, `boost` and `bound` honour `value`.
  - `night=false` is ignored.

  So a toggle switch must only be sent when the fresh state differs from the target, or a stale state or a double click flips it the wrong way.
- Winter brings the heater with it: turning Winter on also turned Heater on, and turning it off turned Heater off.
- Any `setSpeed` ends Auto, Auto+ and Boost; Night returns if the level is 1.
- Turning Auto on turns Auto+ off, and `auto=false` while Auto+ is on also turns Auto+ off. `night=false` and `boost=false` leave Auto+ on.
- Boost runs both fans at level 6 and links them (`bound` becomes true). `boost=false` is ignored (sent twice); a `setSpeed` ends Boost, and the fans stay linked.
- Auto blocks linking as Auto+ does: bound=true is answered "ok" but ignored.
- `setSpeedIsOn` with `bounded` turns the whole unit off even with the fans unlinked, and both speeds read 0 while off. Turning `bounded` back on brings the unit back linked. `setSpeedIsOn` for one fan unlinks them.
- Auto+ and linked fans don't mix. `setSwitch` bound=true is answered `{"result":"ok"}` but ignored while Auto+ is on (tried twice, read back at 0.2–8 s); with Auto+ off it links at once. Turning Auto+ on unlinks the fans. PranaBar greys out the link button while Auto+ is on (`PranaState.linkBlockedBy`); Auto blocks it too (see above), which the app doesn't handle yet.
- More generally, "ok" proves nothing, so PranaBar re-reads after each switch command and shows "The unit didn't …" in the popover footer when the value didn't change (`PranaState.applied`). Night is exempt because it follows the speed.
- The unit occasionally drops a request, so `PranaClient.state()` retries once.
- Discovery: each unit advertises `_prana._tcp` over Bonjour. The instance name is the `manufactureId` from `/info` (`88F155142EEC`), the host is `<that>.local`, and the TXT record has `label=` (space-padded) and `maxSpeed=`. The advertised port, 12345, is closed; the API stays on port 80. `UnitBrowser` resolves the host to IPv4, because the unit doesn't answer over IPv6 and a client trying IPv6 first can use up the 4 s timeout.

## Ideas

- App Intents so Shortcuts and Siri can boost a unit.
- Global hotkey for Boost.
- Option to show inside temperature in the menu bar instead of speed.

## License

MIT. See [LICENSE](LICENSE).
