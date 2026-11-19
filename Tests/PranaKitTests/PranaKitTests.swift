import Foundation
import Testing
@testable import PranaKit

// Swift Testing rather than XCTest: the Command Line Tools ship Testing.framework
// but not XCTest, so this builds without a full Xcode install.
struct PranaKitTests {
    // Captured from the office unit (Prana 150, fw 49) on 2026-11-19.
    let statePayload = """
    {"extract":{"speed":1,"is_on":true,"max_speed":60},"supply":{"speed":1,"is_on":true,"max_speed":60},\
    "bounded":{"speed":1,"is_on":true,"max_speed":60},"bound":false,"heater":false,"auto":false,\
    "auto_plus":false,"night":true,"boost":false,"winter":false,"inside_temperature":232,\
    "outside_temperature_2":235,"humidity":42,"air_pressure":730,"brightness":4}
    """

    let infoPayload = """
    {"manufactureId":"88F155142EEC","isValid":true,"fwVersion":49,"pranaModel":2,"pranaSubtype":0,"label":"Office           "}
    """

    @Test func decodesState() throws {
        let state = try JSONDecoder().decode(PranaState.self, from: Data(statePayload.utf8))
        #expect(!state.bound)
        #expect(state.night)
        #expect(state.supply.speed == 1)
        #expect(state.supply.maxLevel == 6)
        #expect(state.insideTemperature == 23.2)
        #expect(state.outsideTemperature == 23.5) // falls back to outside_temperature_2
        #expect(state.humidity == 42)
        #expect(state.airPressure == 730)
        #expect(state.co2 == nil)
        #expect(state.brightness == 4)
        #expect(state.isOn)
    }

    @Test func decodesInfo() throws {
        let info = try JSONDecoder().decode(DeviceInfo.self, from: Data(infoPayload.utf8))
        #expect(info.label == "Office")
        #expect(info.fwVersion == 49)
        #expect(info.modelName == "Prana 150")
    }

    @Test func speedBodyScalesLevel() throws {
        let data = try JSONEncoder().encode(SpeedBody(speed: 3 * 10, fanType: FanType.bounded.rawValue))
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(json?["speed"] as? Int == 30)
        #expect(json?["fanType"] as? String == "bounded")
    }

    @Test func setFanBoundedUpdatesAll() throws {
        var state = try JSONDecoder().decode(PranaState.self, from: Data(statePayload.utf8))
        state.setFan(.bounded) { $0.speed = 4 }
        #expect(state.bounded.speed == 4)
        #expect(state.supply.speed == 4)
        #expect(state.extract.speed == 4)
    }

    @Test func brightnessReadsAsLevel() throws {
        let state = try JSONDecoder().decode(PranaState.self, from: Data(statePayload.utf8))
        #expect(state.brightness == 4)
    }

    // Observed on the unit: writing 4 reads back 3, writing 8 reads back 4.
    @Test(arguments: [(0, 0), (1, 1), (2, 2), (3, 4), (4, 8), (5, 16), (6, 32)])
    func brightnessLevelToRaw(level: Int, raw: Int) {
        #expect(Brightness.raw(forLevel: level) == raw)
    }

    @Test func brightnessLevelIsClamped() {
        #expect(Brightness.raw(forLevel: -1) == 0)
        #expect(Brightness.raw(forLevel: 9) == 32)
    }

    @Test func commandResultOkPasses() throws {
        try PranaClient.checkCommandResult(Data(#"{"result":"ok"}"#.utf8))
        try PranaClient.checkCommandResult(Data())
    }

    @Test func commandResultOtherIsRejected() {
        #expect(throws: PranaError.self) {
            try PranaClient.checkCommandResult(Data(#"{"result":"error"}"#.utf8))
        }
    }

    // The office unit reported Night and Auto+ both on at once.
    @Test func selectingFanModeClearsOthers() throws {
        var state = try JSONDecoder().decode(PranaState.self, from: Data(statePayload.utf8))
        state.boost = true
        #expect(state.conflictingModes(for: .autoPlus) == [.night, .boost])
        state.setSwitch(.autoPlus, true)
        #expect(state.autoPlus)
        #expect(!state.night && !state.boost && !state.auto)
    }

    @Test func winterAndHeaterAreIndependent() throws {
        var state = try JSONDecoder().decode(PranaState.self, from: Data(statePayload.utf8))
        #expect(state.conflictingModes(for: .winter).isEmpty)
        state.setSwitch(.winter, true)
        state.setSwitch(.heater, true)
        #expect(state.winter && state.heater && state.night)
    }

    @Test func turningModeOffLeavesOthers() throws {
        var state = try JSONDecoder().decode(PranaState.self, from: Data(statePayload.utf8))
        state.auto = true
        state.setSwitch(.night, false)
        #expect(!state.night)
        #expect(state.auto)
    }

    // What the office unit reported after picking Auto+: night stayed true.
    @Test func autoPlusOutranksStuckNight() throws {
        var state = try JSONDecoder().decode(PranaState.self, from: Data(statePayload.utf8))
        state.autoPlus = true
        #expect(state.night)
        #expect(state.activeFanMode == .autoPlus)
        #expect(state.isShownOn(.autoPlus))
        #expect(!state.isShownOn(.night))
    }

    @Test func nightShownWhenAlone() throws {
        let state = try JSONDecoder().decode(PranaState.self, from: Data(statePayload.utf8))
        #expect(state.activeFanMode == .night)
        #expect(state.isShownOn(.night))
        #expect(!state.isShownOn(.winter))
    }

    @Test func cancellationIsNotAFailure() {
        #expect(PranaError.transport(URLError(.cancelled)).isCancellation)
        #expect(PranaError.transport(CancellationError()).isCancellation)
        #expect(!PranaError.transport(URLError(.notConnectedToInternet)).isCancellation)
        #expect(!PranaError.http(500).isCancellation)
    }

    // The office unit answered "ok" to bound=true but stayed unlinked.
    @Test func ignoredSwitchIsDetected() throws {
        let state = try JSONDecoder().decode(PranaState.self, from: Data(statePayload.utf8))
        #expect(!state.applied(.bound, true))
        #expect(state.applied(.bound, false))
        #expect(!state.applied(.winter, true))
        #expect(state.applied(.night, false)) // Night follows speed; never reported as ignored
    }

    // Office unit: bound=true ignored with Auto+ on, accepted with it off;
    // turning Auto+ on unlinked the fans.
    @Test func autoPlusBlocksLinking() throws {
        var state = try JSONDecoder().decode(PranaState.self, from: Data(statePayload.utf8))
        #expect(state.linkBlockedBy == nil)
        state.setSwitch(.bound, true)
        #expect(state.bound)
        state.setSwitch(.autoPlus, true)
        #expect(!state.bound)
        #expect(state.linkBlockedBy == .autoPlus)
    }

    @Test func pressureConvertsToHectopascals() {
        #expect(abs(Pressure.hectopascals(fromMmHg: 728) - 970.6) < 0.1)
    }

    private func history(_ readings: [(minutes: Double, mmHg: Int)]) -> PressureHistory {
        var h = PressureHistory()
        let start = Date(timeIntervalSince1970: 0)
        for r in readings {
            h.add(hPa: Pressure.hectopascals(fromMmHg: r.mmHg), at: start.addingTimeInterval(r.minutes * 60))
        }
        return h
    }

    @Test func pressureTrendNeedsAnHour() {
        #expect(history([(0, 728), (30, 730), (59, 732)]).trend == nil)
    }

    @Test func pressureTrendIgnoresOneStepFlicker() {
        // 728/729 alternating for 2 hours: noise, not weather.
        let flicker = stride(from: 0.0, through: 120, by: 1).map { (minutes: $0, mmHg: Int($0) % 2 == 0 ? 728 : 729) }
        #expect(history(flicker).trend == .steady)
    }

    @Test func pressureTrendDirections() {
        // 2 mmHg (2.7 hPa) over 3 hours: falling. 4 mmHg (5.3 hPa): falling fast.
        #expect(history([(0, 730), (180, 728)]).trend == .falling)
        #expect(history([(0, 728), (180, 732)]).trend == .risingFast)
        #expect(history([(0, 728), (180, 728)]).trend == .steady)
    }

    @Test func pressureHistoryKeepsThreeHours() {
        let h = history([(0, 720), (100, 728), (200, 728)])
        #expect(h.samples.count == 2)
    }

    @Test func seaLevelCorrection() {
        #expect(Pressure.seaLevel(hPa: 971, altitude: 0) == 971)
        // About 1 hPa per 8 m near the ground: 300 m at 15 °C adds ~35 hPa.
        let corrected = Pressure.seaLevel(hPa: 971, altitude: 300, temperature: 15)
        #expect(abs(corrected - 1006) < 1)
        // Colder air is denser, so the same height needs a bigger correction.
        #expect(Pressure.seaLevel(hPa: 971, altitude: 300, temperature: -10) > corrected)
    }

    @Test(arguments: [(985.0, PressureLevel.low), (999.9, .low), (1000, .normal), (1013, .normal),
                      (1025, .normal), (1025.1, .high), (1040, .high)])
    func pressureLevelBands(hPa: Double, level: PressureLevel) {
        #expect(PressureLevel(seaLevelHPa: hPa) == level)
    }

    // Bonjour reports the instance name (= manufactureId); a manual add may only
    // know the host until the unit answers.
    @Test func savedUnitsMatchByDeviceIDOrHost() {
        let units = [SavedUnit(deviceID: "88F155142EEC", name: "Office", host: "192.168.0.166"),
                     SavedUnit(name: "10.0.0.5", host: "10.0.0.5")]
        #expect(units.contains(deviceID: "88f155142eec", host: nil))
        #expect(units.contains(deviceID: "AAAA", host: "10.0.0.5"))
        #expect(!units.contains(deviceID: "AAAA", host: "10.0.0.6"))
        #expect(units.unit(withDeviceID: "88F155142EEC")?.name == "Office")
        #expect(units.unit(withDeviceID: "10.0.0.5") == nil)
    }

    @Test func savedUnitFollowsNewAddress() {
        var units = [SavedUnit(deviceID: "88F155142EEC", name: "Office", host: "192.168.0.166")]
        let id = units[0].id
        let moved = units.update(id, host: "192.168.0.170")
        #expect(moved)
        #expect(units[0].host == "192.168.0.170")
        let again = units.update(id, host: "192.168.0.170")
        #expect(!again) // no change
        let blank = units.update(id, name: "")
        #expect(!blank) // empty label doesn't wipe the name
        #expect(units[0].name == "Office")
    }

    @Test func legacyUnitLearnsItsIdentity() {
        var units = [SavedUnit(name: "192.168.0.166", host: "192.168.0.166")]
        units.update(units[0].id, deviceID: "88F155142EEC", name: "Office")
        #expect(units[0].deviceID == "88F155142EEC")
        #expect(units[0].name == "Office")
    }

    @Test func savedUnitsRoundTrip() throws {
        let units = [SavedUnit(deviceID: "88F155142EEC", name: "Office", host: "192.168.0.166"),
                     SavedUnit(name: "Loft", host: "loft.local")]
        let decoded = try JSONDecoder().decode([SavedUnit].self, from: JSONEncoder().encode(units))
        #expect(decoded == units)
    }
}
