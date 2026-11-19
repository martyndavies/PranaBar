import PranaKit
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @Environment(Units.self) private var units
    @State private var showAdd = false
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Section {
                if units.saved.isEmpty {
                    if units.isSearching {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Looking for units on your network…")
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text("No units added yet.")
                            .foregroundStyle(.secondary)
                    }
                }
                ForEach(units.saved) { unit in
                    savedRow(unit)
                }
                Button(units.saved.isEmpty ? "Add a Unit…" : "Add Another Unit…") { showAdd = true }
            } header: {
                Text("Units")
            }

            if !units.saved.isEmpty {
                Section {
                    Picker("Default unit", selection: Binding(
                        get: { units.defaultID },
                        set: { if let id = $0 { units.makeDefault(id) } }
                    )) {
                        ForEach(units.saved) { unit in
                            Text(unit.name).tag(Optional(unit.id))
                        }
                    }
                } footer: {
                    Text("Shown in the menu bar and when you open PranaBar. The first unit found is the default until you pick another.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                HStack {
                    TextField("Altitude", value: Binding(
                        get: { units.altitude },
                        set: { units.altitude = min(max($0, -500), 9000) }
                    ), format: .number.precision(.fractionLength(0)))
                    .multilineTextAlignment(.trailing)
                    Text("m")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Pressure")
            } footer: {
                Text("The unit's height above sea level, so pressure matches weather forecasts. A maps app or an online elevation lookup will give it. Leave at 0 to show the raw reading.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("General") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        setLaunchAtLogin(enabled)
                    }
                if let loginError {
                    Text(loginError)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .sheet(isPresented: $showAdd) {
            AddUnitSheet()
        }
    }

    private func savedRow(_ unit: SavedUnit) -> some View {
        let isDefault = unit.id == units.defaultID
        let store = units.stores[unit.id]
        return HStack(spacing: 10) {
            Circle()
                .fill(statusColor(store?.connection))
                .frame(width: 7, height: 7)
                .help(store.map { statusText($0) } ?? "")
            VStack(alignment: .leading, spacing: 2) {
                Text(unit.name)
                Text(store?.info.map { "\($0.modelName) · \(unit.host)" } ?? unit.host)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isDefault, units.saved.count > 1 {
                Text("Default")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.15), in: Capsule())
            }
            Button {
                units.remove(unit.id)
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Remove \(unit.name)")
            .accessibilityLabel("Remove \(unit.name)")
        }
    }

    private func statusColor(_ connection: Connection?) -> Color {
        switch connection {
        case .ok: .green
        case .stale, .connecting, nil: .yellow
        case .unreachable: .red
        }
    }

    private func statusText(_ store: PranaStore) -> String {
        switch store.connection {
        case .ok: "Connected"
        case .connecting: "Connecting"
        case .stale: "Reconnecting"
        case .unreachable: store.lastError ?? "Can't reach the unit"
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginError = nil
        } catch {
            // Only works from the bundled .app (scripts/bundle.sh), not `swift run`.
            loginError = error.localizedDescription
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

/// Adds units after first launch: searches the network while open, and takes an
/// address for a unit Bonjour can't see (another network segment, say).
struct AddUnitSheet: View {
    @Environment(Units.self) private var units
    @Environment(\.dismiss) private var dismiss
    @State private var hostField = ""
    @State private var adding = false
    @State private var addError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    ForEach(units.unsaved) { unit in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(unit.displayName)
                                Text(unit.host ?? "Finding address…")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Add") { units.add(unit) }
                                .disabled(unit.host == nil)
                        }
                    }
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text(units.unsaved.isEmpty ? "Searching…" : "Searching for more…")
                            .foregroundStyle(.secondary)
                    }
                    if let error = units.browser.error {
                        Text("Can't search the network: \(error)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("On your network")
                }

                Section {
                    HStack {
                        TextField("Address", text: $hostField, prompt: Text("Host or IP"))
                            .labelsHidden()
                            .onSubmit(addByHost)
                        Button("Add", action: addByHost)
                            .disabled(adding || hostField.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    if adding || addError != nil {
                        Text(adding ? "Connecting…" : addError ?? "")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("By address")
                } footer: {
                    Text("For a unit on another network segment, which searching can't reach.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 400)
        .onAppear { units.setAdding(true) }
        .onDisappear { units.setAdding(false) }
    }

    private func addByHost() {
        let host = hostField.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty, !adding else { return }
        adding = true
        addError = nil
        Task {
            do {
                try await units.add(host: host)
                hostField = ""
            } catch {
                addError = error.localizedDescription
            }
            adding = false
        }
    }
}
