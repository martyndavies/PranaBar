import PranaKit
import SwiftUI

// Custom controls for the popover. Icons are SF Symbols throughout: they ship with
// macOS, match the system's weight and size, and need no extra dependency.

extension PranaSwitch {
    var symbol: String {
        switch self {
        case .bound: "link"
        case .heater: "flame.fill"
        case .night: "moon.fill"
        case .boost: "bolt.fill"
        case .auto: "sparkle"
        case .autoPlus: "sparkles"
        case .winter: "snowflake"
        }
    }
}

extension PressureLevel {
    /// Weather each band usually brings.
    var symbol: String {
        switch self {
        case .low: "cloud.rain.fill"
        case .normal: "cloud.sun.fill"
        case .high: "sun.max.fill"
        }
    }
}

/// The band's weather icon, coloured by layer so the grey cloud stays visible in
/// light mode (the multicolour rendering draws it white).
struct WeatherIcon: View {
    let level: PressureLevel

    var body: some View {
        switch level {
        case .low:
            Image(systemName: level.symbol)
                .symbolRenderingMode(.palette)
                .foregroundStyle(.secondary, .blue)
        case .normal:
            Image(systemName: level.symbol)
                .symbolRenderingMode(.palette)
                .foregroundStyle(.secondary, .yellow)
        case .high:
            Image(systemName: level.symbol)
                .foregroundStyle(.orange)
        }
    }
}

/// Low / Normal / High in a capsule tinted by band, with its weather icon.
struct PressureTag: View {
    let level: PressureLevel

    private var tint: Color {
        switch level {
        case .low: .blue
        case .normal: .green
        case .high: .orange
        }
    }

    var body: some View {
        HStack(spacing: 3) {
            WeatherIcon(level: level)
            Text(level.title)
                .foregroundStyle(tint)
        }
        .font(.caption2.weight(.semibold))
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(tint.opacity(0.15)))
    }
}

/// A fan that spins faster at higher levels and stops when the fan is off.
struct FanGlyph: View {
    let level: Int
    let isOn: Bool
    var size: CGFloat = 18

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let spinning = isOn && !reduceMotion
        TimelineView(.animation(paused: !spinning)) { context in
            let degreesPerSecond = Double(40 + level * 70)
            let angle = spinning
                ? (context.date.timeIntervalSinceReferenceDate * degreesPerSecond).truncatingRemainder(dividingBy: 360)
                : 0
            Image(systemName: "fan.fill")
                .font(.system(size: size))
                .rotationEffect(.degrees(angle))
        }
        .foregroundStyle(isOn ? .primary : .tertiary)
        .accessibilityHidden(true)
    }
}

/// Rising bars, one per fan level. Read-only unless `onSelect` is given, in which
/// case clicking a bar sets that level and hovering previews it.
struct LevelMeter: View {
    let label: String
    let level: Int
    let maxLevel: Int
    var isOn = true
    var height: CGFloat = 14
    /// Fixed bar width for compact use; nil stretches the bars to fill the row.
    var barWidth: CGFloat? = 4
    var onSelect: ((Int) -> Void)?

    @State private var hovered: Int?

    var body: some View {
        HStack(alignment: .bottom, spacing: barWidth.map { $0 > 6 ? 6 : 3 } ?? 4) {
            ForEach(1...max(1, maxLevel), id: \.self) { i in
                bar(i)
            }
        }
        .frame(height: height)
        .animation(.easeOut(duration: 0.15), value: level)
        .animation(.easeOut(duration: 0.1), value: hovered)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(isOn ? "\(level) of \(maxLevel)" : "Off")
        .accessibilityAdjustableAction { direction in
            guard let onSelect else { return }
            switch direction {
            case .increment: onSelect(min(level + 1, maxLevel))
            case .decrement: onSelect(max(level - 1, 1))
            @unknown default: break
            }
        }
    }

    private func bar(_ i: Int) -> some View {
        let lit = isOn && i <= level
        let preview = hovered.map { i <= $0 } ?? false
        let fraction = 0.25 + 0.75 * Double(i) / Double(max(1, maxLevel))
        let style: AnyShapeStyle = lit
            ? AnyShapeStyle(.primary)
            : preview ? AnyShapeStyle(.secondary) : AnyShapeStyle(.quaternary)

        return RoundedRectangle(cornerRadius: min(4, (barWidth ?? 8) / 2), style: .continuous)
            .fill(style)
            .frame(width: barWidth, height: height * fraction)
            .frame(maxWidth: barWidth == nil ? .infinity : nil, maxHeight: .infinity, alignment: .bottom)
            .contentShape(Rectangle())
            .onTapGesture { onSelect?(i) }
            .onHover { inside in
                guard onSelect != nil else { return }
                hovered = inside ? i : (hovered == i ? nil : hovered)
            }
    }
}

/// A water drop filled to the humidity level. Drawn rather than taken from SF Symbols
/// so the fill lines up with the drop's outline, not the symbol's padded box.
struct HumidityDrop: View {
    let percent: Int?
    var size: CGFloat = 18

    var body: some View {
        let fraction = Double(min(max(percent ?? 0, 0), 100)) / 100
        let fillHeight = DropShape.heightFraction(forArea: fraction)
        ZStack {
            DropShape()
                .fill(.primary)
                .mask {
                    GeometryReader { geo in
                        Rectangle()
                            .frame(height: geo.size.height * fillHeight)
                            .frame(maxHeight: .infinity, alignment: .bottom)
                    }
                }
            DropShape()
                .stroke(.secondary, lineWidth: 1.3)
        }
        .padding(0.65)
        .frame(width: size * DropShape.aspect, height: size)
        .animation(.easeOut(duration: 0.3), value: fraction)
        .accessibilityHidden(true)
    }
}

/// A point at the top, a circle at the bottom, joined by straight tangents.
struct DropShape: Shape {
    /// Width over height.
    static let aspect: CGFloat = 0.72

    func path(in rect: CGRect) -> Path {
        let g = Geometry(width: rect.width, height: rect.height)
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX + g.r * sin(g.beta), y: rect.minY + g.tangentY))
        path.addArc(
            center: CGPoint(x: rect.midX, y: rect.minY + g.cy),
            radius: g.r,
            startAngle: .radians(g.beta - .pi / 2),
            endAngle: .radians(3 * .pi / 2 - g.beta),
            clockwise: false
        )
        path.closeSubpath()
        return path
    }

    /// The fill height (as a fraction of the drop's height, from the bottom) that
    /// covers `area` of the drop. The drop is widest near the bottom, so 61% of the
    /// area sits well below 61% of the height.
    static func heightFraction(forArea area: Double) -> Double {
        guard area > 0 else { return 0 }
        guard area < 1 else { return 1 }
        let g = Geometry(width: aspect, height: 1)
        let steps = 400
        var widths: [Double] = []
        for i in 0..<steps {
            widths.append(g.width(atY: (Double(i) + 0.5) / Double(steps)))
        }
        let total = widths.reduce(0, +)
        var filled = 0.0
        for i in stride(from: steps - 1, through: 0, by: -1) {
            filled += widths[i]
            if filled / total >= area { return Double(steps - i) / Double(steps) }
        }
        return 1
    }

    private struct Geometry {
        let r: Double, cy: Double, beta: Double, tangentY: Double

        init(width: Double, height: Double) {
            r = width / 2
            cy = height - r
            // Angle at the circle's centre between straight up and the tangent point.
            beta = acos(min(1, r / cy))
            tangentY = cy - r * cos(beta)
        }

        func width(atY y: Double) -> Double {
            if y <= tangentY {
                return 2 * (y / tangentY) * r * sin(beta)
            }
            let dy = y - cy
            return 2 * (max(0, r * r - dy * dy)).squareRoot()
        }
    }
}

/// The unit's power button: filled with the accent colour while running.
struct PowerButton: View {
    let isOn: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "power")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isOn ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                .frame(width: 30, height: 30)
                .background {
                    Circle().fill(isOn ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.primary.opacity(hovering ? 0.12 : 0.06)))
                }
                .shadow(color: isOn ? Color.accentColor.opacity(0.45) : .clear, radius: 6)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.2), value: isOn)
        .help(isOn ? "Running. Click to turn the unit off." : "Off. Click to turn the unit on.")
        .accessibilityLabel("Power")
        .accessibilityValue(isOn ? "On" : "Off")
    }
}

/// A square-ish toggle with an icon over a short label.
struct ModeChip: View {
    let symbol: String
    let title: String
    let isOn: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 14)
                Text(title)
                    .font(.caption)
            }
            .foregroundStyle(isOn ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .background {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(isOn ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.primary.opacity(hovering ? 0.1 : 0.05)))
            }
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: isOn)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// Six segments for display brightness; the dim sun on the left turns the display off.
struct BrightnessDots: View {
    let level: Int
    let onSelect: (Int) -> Void

    @State private var hovered: Int?

    var body: some View {
        HStack(spacing: 10) {
            Button { onSelect(0) } label: {
                Image(systemName: level == 0 ? "sun.min" : "sun.min.fill")
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
            }
            .buttonStyle(.plain)
            .help("Turn the unit's display off")

            HStack(spacing: 3) {
                ForEach(1...Brightness.levels.upperBound, id: \.self) { i in
                    let lit = i <= level
                    let preview = hovered.map { i <= $0 } ?? false
                    // Lit segments are taller and in the accent colour, so the level
                    // reads at a glance; hovering previews in grey.
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(lit ? AnyShapeStyle(Color.accentColor) : preview ? AnyShapeStyle(.secondary) : AnyShapeStyle(.quaternary))
                        .frame(height: lit ? 10 : 6)
                        .frame(maxWidth: .infinity, minHeight: 18)
                        .contentShape(Rectangle())
                        .onTapGesture { onSelect(i) }
                        .onHover { inside in hovered = inside ? i : (hovered == i ? nil : hovered) }
                }
            }

            Image(systemName: "sun.max.fill")
                .foregroundStyle(.secondary)
                .frame(width: 18)
                .accessibilityHidden(true)
        }
        .animation(.easeOut(duration: 0.15), value: level)
        .animation(.easeOut(duration: 0.1), value: hovered)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Display brightness")
        .accessibilityValue(level == 0 ? "Off" : "\(level) of \(Brightness.levels.upperBound)")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: onSelect(min(level + 1, Brightness.levels.upperBound))
            case .decrement: onSelect(max(level - 1, 0))
            @unknown default: break
            }
        }
    }
}

/// A subtle rounded panel used for the glance tiles.
struct Panel<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.primary.opacity(0.05))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(.primary.opacity(0.06))
            }
    }
}

/// Small icon-and-caption heading for a section.
struct SectionLabel: View {
    let title: String
    let symbol: String

    var body: some View {
        Label(title, systemImage: symbol)
            .font(.caption)
            .foregroundStyle(.secondary)
            .labelStyle(.titleAndIcon)
    }
}
