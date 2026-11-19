import Foundation
import Network
import Observation

/// A Prana unit announcing itself on the local network.
struct DiscoveredUnit: Identifiable, Equatable {
    /// The Bonjour instance name, which is the unit's `manufactureId`.
    let id: String
    /// The unit's own name, from the TXT record. The unit pads it with spaces.
    let label: String
    /// IPv4 address, once resolved.
    var host: String?

    var displayName: String { label.isEmpty ? id : label }
}

/// Finds Prana units with Bonjour. Each unit advertises `_prana._tcp` with
/// `label=` and `maxSpeed=` in its TXT record; the service needs
/// `NSBonjourServices` in Info.plist, or macOS refuses to browse for it.
///
/// The advertised port (12345 on fw 49) is closed. The HTTP API is on port 80, so
/// only the host is used. The host name is `<instance>.local`, which is resolved
/// to an IPv4 address up front: the unit doesn't answer over IPv6, and a client
/// trying IPv6 first can run out its 4 s timeout before falling back.
@MainActor
@Observable
final class UnitBrowser {
    private(set) var found: [DiscoveredUnit] = []
    private(set) var error: String?
    /// Called when a unit is found or its address resolves.
    @ObservationIgnored var onChange: ((DiscoveredUnit) -> Void)?

    private var browser: NWBrowser?

    func start() {
        guard browser == nil else { return }
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: "_prana._tcp", domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let seen = results.compactMap(Self.unit(from:))
            Task { @MainActor in self?.update(seen) }
        }
        browser.stateUpdateHandler = { [weak self] state in
            let message: String? = switch state {
            case .failed(let error), .waiting(let error): error.localizedDescription
            default: nil
            }
            Task { @MainActor in self?.error = message }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    var isRunning: Bool { browser != nil }

    func stop() {
        browser?.cancel()
        browser = nil
        found = []
        error = nil
    }

    private nonisolated static func unit(from result: NWBrowser.Result) -> DiscoveredUnit? {
        guard case .service(let name, _, _, _) = result.endpoint else { return nil }
        var label = ""
        if case .bonjour(let txt) = result.metadata, let value = txt["label"] {
            label = value.trimmingCharacters(in: .whitespaces)
        }
        return DiscoveredUnit(id: name, label: label)
    }

    private func update(_ seen: [DiscoveredUnit]) {
        let known = Dictionary(found.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        found = seen.map { unit in
            var unit = unit
            unit.host = known[unit.id]?.host
            return unit
        }
        for unit in found {
            onChange?(unit)
            resolve(unit.id)
        }
    }

    /// Looks up the unit's current IPv4 address. Run on every browse change, since a
    /// unit that reappears may have a new address.
    private func resolve(_ id: String) {
        Task.detached {
            let address = Self.ipv4Address(of: "\(id).local")
            await MainActor.run { [weak self] in
                guard let self, let address,
                      let i = self.found.firstIndex(where: { $0.id == id }),
                      self.found[i].host != address else { return }
                self.found[i].host = address
                self.onChange?(self.found[i])
            }
        }
    }

    private nonisolated static func ipv4Address(of hostName: String) -> String? {
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_STREAM
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(hostName, nil, &hints, &result) == 0, let first = result else { return nil }
        defer { freeaddrinfo(result) }
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard let sockaddr = first.pointee.ai_addr else { return nil }
        let ok = sockaddr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { sin in
            var addr = sin.pointee.sin_addr
            return inet_ntop(AF_INET, &addr, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil
        }
        return ok ? String(cString: buffer) : nil
    }
}
