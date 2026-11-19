import AppKit
import PranaKit
import SwiftUI

/// The menu bar popover. The top half answers "is it running, and what's the air
/// doing?" at a glance; everything that changes the unit sits under "Controls".
struct PopoverView: View {
    @Environment(PranaStore.self) private var store
    @Environment(Units.self) private var units
    @Environment(\.openSettings) private var openSettings
    /// Closed whenever the popover closes, so it always opens on the glance view.
    @State private var showControls = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if let state = store.state {
                glance(state)
                    .zIndex(1)
                if let mmHg = state.airPressure {
                    pressureRow(mmHg: mmHg, outside: state.outsideTemperature, trend: store.pressureHistory.trend)
                        .padding(.horizontal, 2)
                        .zIndex(1)
                }
                controlsToggle
                    .zIndex(1)
                if showControls {
                    controls(state)
                        // Fade only: a slide would pass underneath the glance tiles.
                        .transition(.opacity)
                }
            } else {
                placeholder
            }
            footer
        }
        .padding(16)
        .frame(width: 320)
        .onAppear {
            store.isPopoverOpen = true
            Task { await store.refresh() }
        }
        .onDisappear {
            store.isPopoverOpen = false
            showControls = false
        }
    }

    // MARK: Glance

    private var header: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                unitName
                HStack(spacing: 4) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 6, height: 6)
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .help(statusHelp)
            }
            Spacer()
            if let state = store.state {
                PowerButton(isOn: state.isOn) { store.setPower(!state.isOn) }
            }
        }
    }

    private var name: String {
        if let label = store.info?.label, !label.isEmpty { return label }
        return units.shownUnit?.name ?? "Prana"
    }

    /// The unit's name; with more than one unit, a menu to look at another.
    @ViewBuilder
    private var unitName: some View {
        let title = Text(name).font(.system(size: 15, weight: .semibold))
        if units.saved.count > 1 {
            Menu {
                Picker("Unit", selection: Binding(
                    get: { units.shownUnit?.id },
                    set: { if let id = $0 { units.show(id) } }
                )) {
                    ForEach(units.saved) { unit in
                        Text(menuTitle(unit)).tag(Optional(unit.id))
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                HStack(spacing: 4) {
                    title
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Show another unit. PranaBar opens on the default unit each time.")
        } else {
            title
        }
    }

    /// Menus can't show coloured dots, so status goes in the text.
    private func menuTitle(_ unit: SavedUnit) -> String {
        var title = unit.name
        if unit.id == units.defaultID { title += " (default)" }
        if units.stores[unit.id]?.connection == .unreachable { title += " · offline" }
        return title
    }

    private func glance(_ state: PranaState) -> some View {
        HStack(spacing: 8) {
            fanTile(
                title: "In",
                arrow: "arrow.down",
                fan: state.bound ? state.bounded : state.supply,
                temperature: state.outsideTemperature,
                help: "Fresh air coming in. Temperature is outside."
            )
            fanTile(
                title: "Out",
                arrow: "arrow.up",
                fan: state.bound ? state.bounded : state.extract,
                temperature: state.insideTemperature,
                help: "Stale air going out. Temperature is the room."
            )
            Panel {
                VStack(alignment: .leading, spacing: 8) {
                    tileHeading(icon: AnyView(HumidityDrop(percent: state.humidity)), caption: "Air")
                    Text(state.humidity.map { "\($0)%" } ?? "–")
                        .font(.system(size: 15, weight: .medium, design: .rounded).monospacedDigit())
                        .frame(height: 16, alignment: .leading)
                        .fixedSize()
                    Label("Room", systemImage: "house")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .labelStyle(TightLabel())
                }
            }
            .help("Relative humidity in the room")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Humidity")
            .accessibilityValue(state.humidity.map { "\($0) percent" } ?? "Unknown")
        }
    }

    private func fanTile(title: String, arrow: String, fan: FanState, temperature: Double?, help: String) -> some View {
        Panel {
            VStack(alignment: .leading, spacing: 8) {
                tileHeading(icon: AnyView(FanGlyph(level: fan.speed, isOn: fan.isOn)), caption: title, arrow: arrow)
                LevelMeter(label: "Fan \(title.lowercased())", level: fan.speed, maxLevel: fan.maxLevel, isOn: fan.isOn, height: 16)
                Label(temperature.map { String(format: "%.1f°", $0) } ?? "–", systemImage: "thermometer.medium")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .labelStyle(TightLabel())
            }
        }
        .help("\(help) Fan \(fan.isOn ? "\(fan.speed) of \(fan.maxLevel)" : "off").")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Air \(title.lowercased())")
        .accessibilityValue(fan.isOn ? "Fan \(fan.speed) of \(fan.maxLevel), \(temperature.map { String(format: "%.1f degrees", $0) } ?? "")" : "Fan off")
    }

    private func tileHeading(icon: AnyView, caption: String, arrow: String? = nil) -> some View {
        HStack(spacing: 4) {
            icon
            Spacer(minLength: 0)
            if let arrow {
                Image(systemName: arrow)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.tertiary)
            }
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var placeholder: some View {
        VStack(spacing: 8) {
            Image(systemName: store.connection == .unreachable ? "wifi.exclamationmark" : "fan")
                .font(.system(size: 24))
                .foregroundStyle(.tertiary)
            Text(store.connection == .unreachable ? "Can't reach the unit at \(store.host)" : "Connecting…")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 100)
    }

    // MARK: Controls

    private var controlsToggle: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { showControls.toggle() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "slider.horizontal.3")
                Text("Controls")
                Spacer()
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .rotationEffect(.degrees(showControls ? 180 : 0))
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(showControls ? "Hide fan speed, modes and display brightness" : "Fan speed, modes and display brightness")
    }

    private func controls(_ state: PranaState) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            speed(state)
            modes(state)
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(title: "Display", symbol: "sun.max")
                BrightnessDots(level: state.brightness) { store.setBrightness(level: $0) }
            }
            moreReadings(state)
        }
    }

    private func speed(_ state: PranaState) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionLabel(title: "Fan speed", symbol: "fan")
                Spacer()
                linkToggle(state)
            }
            if state.bound {
                LevelMeter(label: "Fan speed", level: state.bounded.speed, maxLevel: state.bounded.maxLevel,
                           isOn: state.bounded.isOn, height: 28, barWidth: nil) { store.setLevel($0, fan: .bounded) }
            } else {
                speedRow(arrow: "arrow.down", label: "Fan in", fan: state.supply, type: .supply)
                speedRow(arrow: "arrow.up", label: "Fan out", fan: state.extract, type: .extract)
            }
        }
    }

    private func speedRow(arrow: String, label: String, fan: FanState, type: FanType) -> some View {
        HStack(spacing: 10) {
            Image(systemName: arrow)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 12)
                .help(label)
            LevelMeter(label: label, level: fan.speed, maxLevel: fan.maxLevel, isOn: fan.isOn,
                       height: 28, barWidth: nil) { store.setLevel($0, fan: type) }
        }
    }

    private func linkToggle(_ state: PranaState) -> some View {
        let blocker = state.linkBlockedBy
        return Button { store.set(.bound, !state.bound) } label: {
            Image(systemName: "link")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(state.bound ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
                .opacity(blocker == nil ? 1 : 0.4)
                .frame(width: 22, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(blocker != nil)
        .help(linkHelp(state, blocker: blocker))
        .accessibilityLabel("Same speed in and out")
        .accessibilityValue(state.bound ? "On" : "Off")
    }

    private func linkHelp(_ state: PranaState, blocker: PranaSwitch?) -> String {
        if let blocker {
            return "\(blocker.title) sets each fan's speed itself, so in and out can't be linked while it's on."
        }
        return state.bound
            ? "In and out run at the same speed. Click to set them separately."
            : "In and out are set separately. Click to link them."
    }

    private func modes(_ state: PranaState) -> some View {
        let switches: [PranaSwitch] = [.night, .boost, .auto, .autoPlus, .winter, .heater]
        return VStack(alignment: .leading, spacing: 8) {
            SectionLabel(title: "Mode", symbol: "circle.grid.2x2")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                ForEach(switches, id: \.self) { sw in
                    let on = state.isShownOn(sw)
                    ModeChip(symbol: sw.symbol, title: sw.title, isOn: on) { store.set(sw, !on) }
                }
            }
        }
    }

    /// Readings that aren't worth a glance: shown only when the model reports them.
    @ViewBuilder
    private func moreReadings(_ state: PranaState) -> some View {
        let items: [(String, String, String)] = [
            state.co2.map { ("carbon.dioxide.cloud", "CO₂", "\($0) ppm") },
            state.voc.map { ("aqi.medium", "VOC", "\($0)") },
        ].compactMap { $0 }
        if !items.isEmpty || store.info != nil {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(items, id: \.1) { symbol, name, value in
                    HStack {
                        Label(name, systemImage: symbol)
                        Spacer()
                        Text(value).monospacedDigit()
                    }
                }
                if let info = store.info {
                    Label("\(info.modelName) · firmware \(info.fwVersion) · \(store.host)", systemImage: "info.circle")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    /// The band and the trend, which is what a barometer tells you. The number
    /// itself is only in the hover hint.
    private func pressureRow(mmHg: Int, outside: Double?, trend: PressureTrend?) -> some View {
        let hPa = Pressure.seaLevel(hPa: Pressure.hectopascals(fromMmHg: mmHg),
                                    altitude: units.altitude, temperature: outside)
        // Without an altitude the reading isn't at sea level, so a band would mislead.
        let level = units.altitude == 0 ? nil : PressureLevel(seaLevelHPa: hPa)
        let basis = units.altitude == 0
            ? "\(Int(hPa.rounded())) hPa measured at the unit, which reads lower than forecasts. Set the altitude in Settings to see low, normal or high."
            : "\(Int(hPa.rounded())) hPa, corrected to sea level for \(Int(units.altitude)) m."

        return HStack(spacing: 6) {
            Label("Pressure", systemImage: "barometer")
            if let level {
                PressureTag(level: level)
            } else {
                Button("Set altitude…") {
                    NSApp.activate(ignoringOtherApps: true)
                    openSettings()
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
            }
            Spacer()
            if let trend {
                Label(trend.title, systemImage: trendSymbol(trend))
                    .labelStyle(TightLabel())
                    .fontWeight(.medium)
                    .foregroundStyle(trendTint(trend))
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .help([
            level.map { "\($0.title): \($0.meaning)" },
            trend.map { "\($0.title) over the last few hours. \($0.meaning)" }
                ?? "The trend appears after an hour of readings while PranaBar is running.",
            basis,
        ].compactMap { $0 }.joined(separator: " "))
    }

    /// Same colours as the band tag: falling heads towards Low (blue), rising
    /// towards High (orange), steady stays Normal (green).
    private func trendTint(_ trend: PressureTrend) -> Color {
        switch trend {
        case .fallingFast, .falling: .blue
        case .steady: .green
        case .rising, .risingFast: .orange
        }
    }

    private func trendSymbol(_ trend: PressureTrend) -> String {
        switch trend {
        case .fallingFast: "arrow.down.right.circle.fill"
        case .falling: "arrow.down.right"
        case .steady: "arrow.right"
        case .rising: "arrow.up.right"
        case .risingFast: "arrow.up.right.circle.fill"
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 14) {
            if let error = store.commandError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                    .help(error)
            } else if let error = store.lastError, store.connection != .ok {
                Text(error)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button("Settings…") {
                // The app has no Dock icon, so the window would open behind others.
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
            }
            .keyboardShortcut(",", modifiers: .command)
            .help("Units, altitude and launch at login")
            Button("Quit") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: .command)
            .help("Quit PranaBar. The unit keeps running.")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .font(.caption)
        .padding(.top, 2)
    }

    private var statusColor: Color {
        switch store.connection {
        case .ok: .green
        case .stale, .connecting: .yellow
        case .unreachable: .red
        }
    }

    private var statusText: String {
        switch store.connection {
        case .ok: runningText
        case .connecting: "Connecting"
        case .stale: "Reconnecting"
        case .unreachable: "Offline"
        }
    }

    /// "Running in Auto+ mode", or plain "Running" when no fan mode is on.
    private var runningText: String {
        guard let state = store.state else { return "Running" }
        guard state.isOn else { return "Off" }
        return state.activeFanMode.map { "Running in \($0.title) mode" } ?? "Running"
    }

    private var statusHelp: String {
        switch store.connection {
        case .ok: "Connected to \(store.host)"
        case .connecting: "Connecting to \(store.host)"
        case .stale: "Lost contact briefly; showing the last reading"
        case .unreachable: "Can't reach \(store.host)"
        }
    }
}

/// Icon and title with less space between them than the default label style.
private struct TightLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 2) {
            configuration.icon
            configuration.title
        }
    }
}

/// The popover before any unit is added: searching, or a pointer to Settings.
struct NoUnitsView: View {
    @Environment(Units.self) private var units
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "fan")
                .font(.system(size: 24))
                .foregroundStyle(.tertiary)
            Text(units.isSearching ? "Looking for Prana units…" : "No units added")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("Add a unit…") {
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            .font(.callout)
            Divider()
            HStack {
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
                    .keyboardShortcut("q", modifiers: .command)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
        }
        .padding(16)
        .frame(width: 320)
    }
}
