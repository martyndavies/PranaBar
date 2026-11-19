import Foundation

/// Which fan a speed or power command targets.
/// `bounded` drives both fans together and is used when `PranaState.bound` is true.
public enum FanType: String, Sendable, CaseIterable {
    case bounded
    case supply
    case extract
}

/// Boolean switches exposed by `/setSwitch`.
public enum PranaSwitch: String, Sendable, CaseIterable {
    case bound
    case heater
    case night
    case boost
    case auto
    case autoPlus = "auto_plus"
    case winter

    public var title: String {
        switch self {
        case .bound: "Same speed in and out"
        case .heater: "Heater"
        case .night: "Night"
        case .boost: "Boost"
        case .auto: "Auto"
        case .autoPlus: "Auto+"
        case .winter: "Winter"
        }
    }

    /// Modes that each decide the fan speed, so only one should be on at a time.
    /// The unit doesn't enforce this itself: it reported Night and Auto+ both on
    /// (Prana 150, fw 49), so the app switches the others off.
    public static let fanModes: [PranaSwitch] = [.night, .boost, .auto, .autoPlus]

    public var isFanMode: Bool { Self.fanModes.contains(self) }

    /// Switches the unit flips on every `setSwitch`, ignoring `value` (Prana 150,
    /// fw 49: auto_plus=false while off turned it on). Only send these when the
    /// unit's current state differs from the target.
    public var isToggle: Bool { self == .autoPlus || self == .winter }

    public var keyPath: WritableKeyPath<PranaState, Bool> {
        switch self {
        case .bound: \.bound
        case .heater: \.heater
        case .night: \.night
        case .boost: \.boost
        case .auto: \.auto
        case .autoPlus: \.autoPlus
        case .winter: \.winter
        }
    }
}

/// Display brightness. `/getState` reports a level (0 is off, 6 is brightest),
/// but `/setBrightness` wants the raw value at that level's position in `rawValues`.
/// Observed on a Prana 150, fw 49: writing 4 reads back 3, writing 8 reads back 4.
public enum Brightness {
    public static let rawValues: [Int] = [0, 1, 2, 4, 8, 16, 32]
    public static let levels: ClosedRange<Int> = 0...6

    public static func raw(forLevel level: Int) -> Int {
        rawValues[min(max(level, levels.lowerBound), levels.upperBound)]
    }
}

public struct FanState: Codable, Sendable, Equatable {
    /// Current level as the device reports it (1...maxLevel). Writes use level * 10.
    public var speed: Int
    public var isOn: Bool
    /// Raw max as reported, e.g. 60 means 6 levels.
    public var maxSpeed: Int

    public init(speed: Int, isOn: Bool, maxSpeed: Int) {
        self.speed = speed
        self.isOn = isOn
        self.maxSpeed = maxSpeed
    }

    public var maxLevel: Int { max(1, maxSpeed >= 10 ? maxSpeed / 10 : maxSpeed) }

    enum CodingKeys: String, CodingKey {
        case speed
        case isOn = "is_on"
        case maxSpeed = "max_speed"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        speed = try c.decodeIfPresent(Int.self, forKey: .speed) ?? 0
        isOn = try c.decodeIfPresent(Bool.self, forKey: .isOn) ?? false
        maxSpeed = try c.decodeIfPresent(Int.self, forKey: .maxSpeed) ?? 60
    }
}

/// Response of `GET /getState`. Sensor fields vary by model, so all are optional.
/// Temperatures arrive in tenths of a degree C.
public struct PranaState: Codable, Sendable, Equatable {
    public var extract: FanState
    public var supply: FanState
    public var bounded: FanState

    public var bound: Bool
    public var heater: Bool
    public var auto: Bool
    public var autoPlus: Bool
    public var night: Bool
    public var boost: Bool
    public var winter: Bool
    /// Display brightness level, 0...6. See `Brightness` for the write scale.
    public var brightness: Int

    public var insideTemperatureRaw: Int?
    public var outsideTemperatureRaw: Int?
    public var insideTemperature2Raw: Int?
    public var outsideTemperature2Raw: Int?
    public var humidity: Int?
    public var co2: Int?
    public var voc: Int?
    /// Looks like mmHg (730 on a unit in Košice).
    public var airPressure: Int?

    enum CodingKeys: String, CodingKey {
        case extract, supply, bounded
        case bound, heater, auto, night, boost, winter, brightness
        case autoPlus = "auto_plus"
        case insideTemperatureRaw = "inside_temperature"
        case outsideTemperatureRaw = "outside_temperature"
        case insideTemperature2Raw = "inside_temperature_2"
        case outsideTemperature2Raw = "outside_temperature_2"
        case humidity, co2, voc
        case airPressure = "air_pressure"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = FanState(speed: 0, isOn: false, maxSpeed: 60)
        extract = try c.decodeIfPresent(FanState.self, forKey: .extract) ?? fallback
        supply = try c.decodeIfPresent(FanState.self, forKey: .supply) ?? fallback
        bounded = try c.decodeIfPresent(FanState.self, forKey: .bounded) ?? fallback
        bound = try c.decodeIfPresent(Bool.self, forKey: .bound) ?? false
        heater = try c.decodeIfPresent(Bool.self, forKey: .heater) ?? false
        auto = try c.decodeIfPresent(Bool.self, forKey: .auto) ?? false
        autoPlus = try c.decodeIfPresent(Bool.self, forKey: .autoPlus) ?? false
        night = try c.decodeIfPresent(Bool.self, forKey: .night) ?? false
        boost = try c.decodeIfPresent(Bool.self, forKey: .boost) ?? false
        winter = try c.decodeIfPresent(Bool.self, forKey: .winter) ?? false
        brightness = try c.decodeIfPresent(Int.self, forKey: .brightness) ?? 0
        insideTemperatureRaw = try c.decodeIfPresent(Int.self, forKey: .insideTemperatureRaw)
        outsideTemperatureRaw = try c.decodeIfPresent(Int.self, forKey: .outsideTemperatureRaw)
        insideTemperature2Raw = try c.decodeIfPresent(Int.self, forKey: .insideTemperature2Raw)
        outsideTemperature2Raw = try c.decodeIfPresent(Int.self, forKey: .outsideTemperature2Raw)
        humidity = try c.decodeIfPresent(Int.self, forKey: .humidity)
        co2 = try c.decodeIfPresent(Int.self, forKey: .co2)
        voc = try c.decodeIfPresent(Int.self, forKey: .voc)
        airPressure = try c.decodeIfPresent(Int.self, forKey: .airPressure)
    }

    // MARK: Derived values

    /// The fan that represents the unit's overall state.
    public var primaryFan: FanState { bound ? bounded : supply }

    public var isOn: Bool { bound ? bounded.isOn : (supply.isOn || extract.isOn) }

    public var insideTemperature: Double? {
        (insideTemperatureRaw ?? insideTemperature2Raw).map { Double($0) / 10 }
    }

    public var outsideTemperature: Double? {
        (outsideTemperatureRaw ?? outsideTemperature2Raw).map { Double($0) / 10 }
    }

    public func fan(_ type: FanType) -> FanState {
        switch type {
        case .bounded: bounded
        case .supply: supply
        case .extract: extract
        }
    }

    /// The one fan mode to show as active. The unit can report several at once:
    /// on a Prana 150 (fw 49) `night` stays true while the fans are at level 1,
    /// even with Auto+ on, and `setSwitch` night=false is answered "ok" but ignored.
    /// So a mode the user picked outranks Night.
    public var activeFanMode: PranaSwitch? {
        [PranaSwitch.boost, .autoPlus, .auto, .night].first { self[keyPath: $0.keyPath] }
    }

    /// Whether a switch should look on in the UI. Fan modes show only the active one.
    public func isShownOn(_ sw: PranaSwitch) -> Bool {
        sw.isFanMode ? activeFanMode == sw : self[keyPath: sw.keyPath]
    }

    /// Fan modes that are on now and must be switched off for `sw` to be the only one.
    public func conflictingModes(for sw: PranaSwitch) -> [PranaSwitch] {
        guard sw.isFanMode else { return [] }
        return PranaSwitch.fanModes.filter { $0 != sw && self[keyPath: $0.keyPath] }
    }

    /// Whether the unit took a `setSwitch` command. It answers "ok" either way:
    /// on a Prana 150 (fw 49) bound=true was ignored with Auto+ on. Night is left
    /// out because it follows the fan speed (see `activeFanMode`), so a Night
    /// command that "didn't take" isn't something the user can act on.
    public func applied(_ sw: PranaSwitch, _ on: Bool) -> Bool {
        sw == .night || self[keyPath: sw.keyPath] == on
    }

    /// The mode that stops the fans being linked, if any. On a Prana 150 (fw 49)
    /// bound=true is ignored while Auto or Auto+ is on, and turning Auto+ on
    /// unlinks them.
    public var linkBlockedBy: PranaSwitch? {
        if autoPlus { return .autoPlus }
        if auto { return .auto }
        return nil
    }

    /// The mode that stops the unit turning off, if any. On a Prana 150 (fw 49)
    /// power-off is answered "ok" but ignored while Auto or Auto+ is on, whether
    /// sent per fan or as `bounded`.
    public var powerOffBlockedBy: PranaSwitch? { linkBlockedBy }

    /// Turns fans on or off, mirroring the unit: `bounded` powers the whole unit
    /// and links the fans (even if they were unlinked), one fan's power unlinks
    /// them, and the fan modes read false while the unit is off.
    public mutating func setPower(_ on: Bool, fan: FanType) {
        setFan(fan) { $0.isOn = on }
        bound = fan == .bounded
        if !on, fan == .bounded {
            auto = false
            autoPlus = false
            boost = false
            night = false
        }
    }

    /// Sets a switch, mirroring what the unit does (Prana 150, fw 49): turning a
    /// fan mode on turns the other fan modes off, Auto+ unlinks the fans, Boost
    /// links them at full speed, and Heater follows Winter.
    public mutating func setSwitch(_ sw: PranaSwitch, _ on: Bool) {
        if on {
            for other in conflictingModes(for: sw) {
                self[keyPath: other.keyPath] = false
            }
            switch sw {
            case .autoPlus:
                bound = false
            case .boost:
                bound = true
                let top = bounded.maxLevel
                setFan(.bounded) { $0.speed = top }
            default:
                break
            }
        }
        if sw == .winter {
            heater = on
        }
        self[keyPath: sw.keyPath] = on
    }

    /// Sets a fan level, mirroring the unit: any speed change ends Auto, Auto+
    /// and Boost, and Night comes back when the fans are at level 1 (supply 3 with
    /// extract 1 showed no Night).
    public mutating func setLevel(_ level: Int, fan: FanType) {
        setFan(fan) { $0.speed = level }
        auto = false
        autoPlus = false
        boost = false
        night = bound ? bounded.speed == 1 : (supply.speed == 1 && extract.speed == 1)
    }

    public mutating func setFan(_ type: FanType, _ update: (inout FanState) -> Void) {
        switch type {
        case .bounded: update(&bounded); update(&supply); update(&extract)
        case .supply: update(&supply)
        case .extract: update(&extract)
        }
    }
}

/// Response of `GET /info`.
public struct DeviceInfo: Codable, Sendable, Equatable {
    public var manufactureId: String
    public var isValid: Bool
    public var fwVersion: Int
    public var pranaModel: Int
    public var pranaSubtype: Int?
    public var label: String

    enum CodingKeys: String, CodingKey {
        case manufactureId, isValid, fwVersion, pranaModel, pranaSubtype, label
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        manufactureId = try c.decodeIfPresent(String.self, forKey: .manufactureId) ?? ""
        isValid = try c.decodeIfPresent(Bool.self, forKey: .isValid) ?? false
        fwVersion = try c.decodeIfPresent(Int.self, forKey: .fwVersion) ?? 0
        pranaModel = try c.decodeIfPresent(Int.self, forKey: .pranaModel) ?? 0
        pranaSubtype = try c.decodeIfPresent(Int.self, forKey: .pranaSubtype)
        // The device pads the label with spaces.
        label = (try c.decodeIfPresent(String.self, forKey: .label) ?? "")
            .trimmingCharacters(in: .whitespaces)
    }

    public var modelName: String {
        switch (pranaModel, pranaSubtype) {
        case (0x04, _): "Prana 340"
        case (0x02, 0x00): "Prana 150"
        case (0x02, 0x01): "Prana 200C"
        case (0x02, 0x02): "Prana 200G"
        case (0x02, 0x03): "Prana 162"
        case (0x02, 0x04): "Prana 212C"
        case (0x02, 0x05): "Prana 212G"
        default: "Prana"
        }
    }
}
