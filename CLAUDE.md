# PranaBar

macOS 14+ menu bar app (SwiftUI `MenuBarExtra`, SwiftPM) controlling a Prana recuperator over its local HTTP API. See README.md for the API table and open questions.

- Build: `swift build`. Test: `swift test` (with only the Command Line Tools, use `scripts/test.sh`: plain `swift test` silently runs zero tests there). Run: `swift run PranaBar`. Bundle: `scripts/bundle.sh`.
- Keep `PranaKit` Foundation-only. UI and state live in `Sources/PranaBar`.
- All device writes go through `PranaStore.perform` so local state updates optimistically and is re-read after.
- Device quirks: speed is read as 1–6 but written ×10; brightness is read as 0–6 but written as `[0,1,2,4,8,16,32][level]`; temperatures are tenths of °C; sensor keys vary by model, so decode them as optional. The unit doesn't keep Night/Boost/Auto/Auto+ exclusive, so `PranaState.setSwitch` does; Night stays on at fan level 1 and ignores night=false, so the UI shows `activeFanMode` rather than the raw flags. The unit answers `{"result":"ok"}` even to commands it ignores (bound=true with Auto+ on; Auto+ also unlinks the fans, see `linkBlockedBy`), so switch commands are checked against the re-read state (`PranaState.applied`).
- Multiple units: `Units` owns one `PranaStore` per `SavedUnit` and the default unit. Units are matched by `deviceID` (the `manufactureId`, which is also the Bonjour instance name), never by host, since addresses change. Bonjour only runs while `Units.searchReasons` is non-empty (first launch, the Add sheet, an unreachable unit). Its advertised port is wrong; always use port 80.
- Don't run `scripts/spike.sh --write` without asking: it changes the unit's settings.
