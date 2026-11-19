# PranaBar

macOS 14+ menu bar app (SwiftUI `MenuBarExtra`, SwiftPM) that controls Prana recuperators over their local HTTP API. Full docs (setup, layout, scripts, API notes): `DOCUMENTATION.md`.

- Build: `swift build`. Test: `scripts/test.sh` (plain `swift test` silently runs zero tests with only the Command Line Tools). Run: `swift run PranaBar`. Bundle: `scripts/bundle.sh`.
- Keep `PranaKit` Foundation-only. UI and state live in `Sources/PranaBar`.
- Send every device write through `PranaStore.perform`, so local state updates optimistically and the unit is re-read after.
- Never write to a real unit without asking, including `scripts/spike.sh --write`: it changes the owner's settings. Use `scripts/fake-units.py` to try commands.
- The unit's behaviour is surprising (it answers "ok" to commands it ignores, some switches toggle whatever `value` says, `boost=false` is ignored). Read the "Prana local API" section of `DOCUMENTATION.md` before touching encodings or switch logic, and update it when you learn something new.
- Multiple units: `Units` owns one `PranaStore` per `SavedUnit`. Match units by `deviceID` (the `manufactureId`, also the Bonjour instance name), never by host, since addresses change.
