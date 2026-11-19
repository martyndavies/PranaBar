import AppKit
import SwiftUI

@main
struct PranaBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var units = Units()

    var body: some Scene {
        MenuBarExtra {
            Group {
                if let store = units.shownStore {
                    PopoverView()
                        .environment(store)
                        // Fresh view state (Controls closed) when switching unit.
                        .id(units.shownUnit?.id)
                } else {
                    NoUnitsView()
                }
            }
            .environment(units)
            // Outside the per-unit view, so switching units doesn't trigger it.
            .onDisappear { units.showDefault() }
        } label: {
            MenuBarLabel(store: units.defaultStore)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(units)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // No Dock icon, even when launched with `swift run` outside a bundle.
        NSApp.setActivationPolicy(.accessory)
    }
}

struct MenuBarLabel: View {
    let store: PranaStore?

    var body: some View {
        if let store {
            label(store)
        } else {
            Image(systemName: "fan")
                .opacity(0.5)
        }
    }

    @ViewBuilder
    private func label(_ store: PranaStore) -> some View {
        switch store.connection {
        case .unreachable:
            Image(systemName: "exclamationmark.triangle")
        case .connecting:
            Image(systemName: "fan")
        case .ok, .stale:
            if let state = store.state, state.isOn {
                HStack(spacing: 2) {
                    Image(systemName: state.boost ? "fan.fill" : "fan")
                    Text(state.boost ? "B" : "\(state.primaryFan.speed)")
                }
            } else {
                Image(systemName: "fan")
                    .opacity(0.5)
            }
        }
    }
}
