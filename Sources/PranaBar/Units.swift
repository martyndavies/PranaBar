import Foundation
import Observation
import OSLog
import PranaKit

/// Every unit the user has added, one `PranaStore` each, plus Bonjour discovery
/// (only when needed; see `SearchReason`).
/// The default unit is the one the menu bar and popover show.
@MainActor
@Observable
final class Units {
    private(set) var saved: [SavedUnit] {
        didSet { save() }
    }
    private(set) var defaultID: SavedUnit.ID? {
        didSet { UserDefaults.standard.set(defaultID?.uuidString, forKey: Keys.defaultUnit) }
    }
    private(set) var stores: [SavedUnit.ID: PranaStore] = [:]
    let browser = UnitBrowser()

    /// Metres above sea level, used to correct pressure to what forecasts quote.
    /// 0 means no correction. One setting for all units, since they're in one house.
    var altitude: Double {
        didSet { UserDefaults.standard.set(altitude, forKey: Keys.altitude) }
    }

    /// First-launch discovery: units found are added without asking, so the app
    /// works straight away. Runs until shortly after the first unit is added, which
    /// gives the others in the house time to answer, and never again after that.
    private var autoAdd: Bool

    /// Why the network is being searched. Bonjour only runs while there's a reason:
    /// first launch, the user adding a unit, or a saved unit that can't be reached
    /// (it may have a new address).
    private enum SearchReason { case firstLaunch, adding, missingUnit }
    private var searchReasons: Set<SearchReason> = [] {
        didSet {
            guard searchReasons != oldValue else { return }
            Self.log.notice("Searching for: \(self.searchReasons.map { "\($0)" }.sorted(), privacy: .public)")
            searchReasons.isEmpty ? browser.stop() : browser.start()
        }
    }
    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "PranaBar", category: "discovery")
    var isSearching: Bool { browser.isRunning }

    private enum Keys {
        static let units = "units"
        static let defaultUnit = "defaultUnit"
        static let altitude = "altitude"
        static let discoveryDone = "initialDiscoveryDone"
        /// Written by an earlier build; no longer used.
        static let oldAutoAdd = "autoAddDiscovered"
        /// The single address used before multiple units.
        static let legacyHost = "host"
    }

    init() {
        let defaults = UserDefaults.standard
        altitude = defaults.double(forKey: Keys.altitude)

        let loaded: [SavedUnit]
        if let data = defaults.data(forKey: Keys.units),
           let units = try? JSONDecoder().decode([SavedUnit].self, from: data) {
            loaded = units
        } else if let host = defaults.string(forKey: Keys.legacyHost) {
            // Upgrading from one host: keep it. Its device ID and name fill in
            // once it answers.
            loaded = [SavedUnit(name: host, host: host)]
        } else {
            loaded = []
        }
        saved = loaded
        // Until a unit has been added, keep trying on each launch.
        autoAdd = loaded.isEmpty && !defaults.bool(forKey: Keys.discoveryDone)
        defaultID = defaults.string(forKey: Keys.defaultUnit).flatMap(UUID.init(uuidString:))
        if defaultID == nil || !saved.contains(where: { $0.id == defaultID }) {
            defaultID = saved.first?.id
        }
        save()
        defaults.removeObject(forKey: Keys.legacyHost)
        defaults.removeObject(forKey: Keys.oldAutoAdd)
        if !saved.isEmpty { defaults.set(true, forKey: Keys.discoveryDone) }

        saved.forEach(startStore)
        browser.onChange = { [weak self] in self?.discovered($0) }
        if autoAdd { searchReasons.insert(.firstLaunch) }
    }

    var defaultUnit: SavedUnit? { saved.first { $0.id == defaultID } }
    var defaultStore: PranaStore? { defaultID.flatMap { stores[$0] } }

    /// The unit the popover is showing: the default, unless the user picked another
    /// from the header menu. Back to the default whenever the popover closes, since
    /// other units are only looked at now and then.
    private(set) var shownID: SavedUnit.ID?
    var shownUnit: SavedUnit? { saved.first { $0.id == shownID } ?? defaultUnit }
    var shownStore: PranaStore? { shownUnit.flatMap { stores[$0.id] } }

    func show(_ id: SavedUnit.ID) {
        shownID = id == defaultID ? nil : id
    }

    func showDefault() {
        shownID = nil
    }

    /// Units on the network that haven't been added.
    var unsaved: [DiscoveredUnit] {
        browser.found.filter { !saved.contains(deviceID: $0.id, host: $0.host) }
    }

    // MARK: Editing

    func add(_ unit: DiscoveredUnit) {
        guard let host = unit.host, !saved.contains(deviceID: unit.id, host: host) else { return }
        insert(SavedUnit(deviceID: unit.id, name: unit.displayName, host: host))
    }

    /// Adds a unit by address, for one Bonjour can't see (another subnet, say).
    /// Asks the unit for its details first, so a typo fails here rather than
    /// leaving a unit that never connects.
    func add(host: String) async throws {
        let host = host.trimmingCharacters(in: .whitespaces)
        let info = try await PranaClient(host: host).info()
        guard !saved.contains(deviceID: info.manufactureId, host: host) else {
            throw AddError.alreadyAdded(info.label.isEmpty ? host : info.label)
        }
        insert(SavedUnit(deviceID: info.manufactureId, name: info.label.isEmpty ? host : info.label, host: host))
    }

    enum AddError: LocalizedError {
        case alreadyAdded(String)
        var errorDescription: String? {
            switch self {
            case .alreadyAdded(let name): "“\(name)” is already added"
            }
        }
    }

    func remove(_ id: SavedUnit.ID) {
        stores.removeValue(forKey: id)?.stop()
        saved.removeAll { $0.id == id }
        finishFirstLaunch() // don't re-add what the user just removed
        if defaultID == id { defaultID = saved.first?.id }
        if shownID == id { shownID = nil }
        updateMissingSearch()
    }

    /// Searching while the user adds a unit (the Settings sheet is open).
    func setAdding(_ adding: Bool) {
        if adding { searchReasons.insert(.adding) } else { searchReasons.remove(.adding) }
    }

    func makeDefault(_ id: SavedUnit.ID) {
        guard saved.contains(where: { $0.id == id }) else { return }
        defaultID = id
    }

    // MARK: Private

    private func insert(_ unit: SavedUnit) {
        saved.append(unit)
        startStore(unit)
        if defaultID == nil { defaultID = unit.id }
        UserDefaults.standard.set(true, forKey: Keys.discoveryDone)
        if autoAdd, firstLaunchEnd == nil {
            firstLaunchEnd = Task { [weak self] in
                try? await Task.sleep(for: .seconds(30))
                self?.finishFirstLaunch()
            }
        }
    }

    private var firstLaunchEnd: Task<Void, Never>?

    private func finishFirstLaunch() {
        autoAdd = false
        firstLaunchEnd?.cancel()
        searchReasons.remove(.firstLaunch)
    }

    /// Search while any saved unit is unreachable; `discovered` then moves it to
    /// its new address. A unit that's switched off keeps this running, which costs
    /// little.
    private func updateMissingSearch() {
        if stores.values.contains(where: { $0.connection == .unreachable }) {
            searchReasons.insert(.missingUnit)
        } else {
            searchReasons.remove(.missingUnit)
        }
    }

    private func startStore(_ unit: SavedUnit) {
        let store = PranaStore(host: unit.host)
        let id = unit.id
        store.onInfo = { [weak self] info in
            self?.saved.update(id, deviceID: info.manufactureId, name: info.label)
        }
        store.onConnectionChange = { [weak self] _ in self?.updateMissingSearch() }
        stores[id] = store
    }

    /// Bonjour saw a unit, or resolved its address. A saved unit at a new address
    /// is followed there; a new one is added only on a fresh install.
    private func discovered(_ unit: DiscoveredUnit) {
        guard let host = unit.host else { return }
        if let known = saved.unit(withDeviceID: unit.id) {
            if saved.update(known.id, host: host) {
                Self.log.notice("\(known.name, privacy: .public) moved to \(host, privacy: .public)")
                stores[known.id]?.host = host
            }
        } else if autoAdd {
            add(unit)
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(saved) {
            UserDefaults.standard.set(data, forKey: Keys.units)
        }
    }
}
