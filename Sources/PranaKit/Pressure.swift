import Foundation

/// Air pressure helpers. The unit reports `air_pressure` in what looks like mmHg
/// (728–730 in the office), which few people read. Forecasts in the UK and Europe
/// use hPa, and what a barometer actually tells you is the trend.
public enum Pressure {
    public static func hectopascals(fromMmHg mmHg: Int) -> Double {
        Double(mmHg) * 1.333_22
    }

    /// Pressure at the unit corrected to sea level, which is what forecasts quote.
    /// Standard barometric formula; the air column below the unit is assumed to be
    /// at `temperature` (the outside reading, or 15 °C without one).
    public static func seaLevel(hPa: Double, altitude: Double, temperature: Double? = nil) -> Double {
        guard altitude != 0 else { return hPa }
        let lapse = 0.0065 * altitude
        let kelvin = (temperature ?? 15) + lapse + 273.15
        return hPa * pow(1 - lapse / kelvin, -5.257)
    }
}

/// Sea-level pressure in broad bands. Only meaningful once corrected to sea level,
/// since the raw reading falls by about 1 hPa per 8 m of altitude. Average sea-level
/// pressure is about 1013 hPa; below 1000 is a low, above 1025 a high.
public enum PressureLevel: Sendable, Equatable {
    case low, normal, high

    public init(seaLevelHPa hPa: Double) {
        switch hPa {
        case ..<1000: self = .low
        case ...1025: self = .normal
        default: self = .high
        }
    }

    public var title: String {
        switch self {
        case .low: "Low"
        case .normal: "Normal"
        case .high: "High"
        }
    }

    public var meaning: String {
        switch self {
        case .low: "Low pressure usually brings cloud, rain and wind."
        case .normal: "Around the average of 1013 hPa."
        case .high: "High pressure usually brings settled, dry weather."
        }
    }
}

/// Which way the pressure is moving, scaled to a change per 3 hours (the window
/// weather services use).
public enum PressureTrend: Sendable, Equatable {
    case fallingFast, falling, steady, rising, risingFast

    public var title: String {
        switch self {
        case .fallingFast: "Falling fast"
        case .falling: "Falling"
        case .steady: "Steady"
        case .rising: "Rising"
        case .risingFast: "Rising fast"
        }
    }

    /// What the trend usually means for the weather.
    public var meaning: String {
        switch self {
        case .fallingFast: "Usually a storm or strong wind on the way."
        case .falling: "Usually turning cloudier, wetter or windier."
        case .steady: "Usually no change in the weather."
        case .rising: "Usually settling, drier weather."
        case .risingFast: "Usually clearing quickly, but it may not last."
        }
    }
}

/// Recent pressure readings, kept in memory to work out the trend.
public struct PressureHistory: Sendable {
    public struct Sample: Sendable, Equatable {
        public let date: Date
        public let hPa: Double
    }

    /// How far back to look.
    public static let window: TimeInterval = 3 * 3600
    /// The least history worth calling a trend.
    public static let minimumSpan: TimeInterval = 3600
    /// Readings at each end are averaged over this long. The unit reports whole
    /// mmHg (1.33 hPa steps), so a single reading flicking 728 → 729 isn't a trend.
    static let smoothing: TimeInterval = 15 * 60

    public private(set) var samples: [Sample] = []

    public init() {}

    public mutating func add(hPa: Double, at date: Date) {
        samples.append(Sample(date: date, hPa: hPa))
        samples.removeAll { date.timeIntervalSince($0.date) > Self.window }
    }

    /// nil until there's at least an hour of readings.
    public var trend: PressureTrend? {
        guard let first = samples.first, let last = samples.last else { return nil }
        let span = last.date.timeIntervalSince(first.date)
        guard span >= Self.minimumSpan else { return nil }

        let start = mean(samples.filter { $0.date.timeIntervalSince(first.date) <= Self.smoothing })
        let end = mean(samples.filter { last.date.timeIntervalSince($0.date) <= Self.smoothing })
        let perThreeHours = (end - start) * (Self.window / span)

        switch perThreeHours {
        case ..<(-3.5): return .fallingFast
        case ..<(-1.0): return .falling
        case ...1.0: return .steady
        case ...3.5: return .rising
        default: return .risingFast
        }
    }

    private func mean(_ s: [Sample]) -> Double {
        s.map(\.hPa).reduce(0, +) / Double(max(1, s.count))
    }
}
