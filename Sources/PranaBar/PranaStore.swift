import Foundation
import Observation
import PranaKit

enum Connection: Equatable {
    case connecting
    case ok
    case stale        // recent failures, showing last known state
    case unreachable  // several failures in a row
}

@MainActor
@Observable
final class PranaStore {
    private(set) var state: PranaState?
    private(set) var info: DeviceInfo?
    private(set) var connection: Connection = .connecting {
        didSet { if connection != oldValue { onConnectionChange?(connection) } }
    }
    private(set) var lastError: String?
    /// Why the most recent command failed. Kept until a command succeeds, because a
    /// successful poll straight after a rejected command would otherwise hide it.
    private(set) var commandError: String?
    /// The last 3 hours of pressure readings, for the trend. Lost on quit.
    private(set) var pressureHistory = PressureHistory()

    /// The unit's address. Changing it reconnects; `Units` does this when Bonjour
    /// reports the unit at a new address.
    var host: String {
        didSet {
            guard host != oldValue else { return }
            info = nil
            state = nil
            connection = .connecting
            makeClient()
            startPolling()
        }
    }

    /// Called once the unit's `/info` has loaded, so `Units` can record its device
    /// ID and name.
    var onInfo: ((DeviceInfo) -> Void)?
    /// Called when the connection changes, so `Units` can look for a unit that's
    /// gone missing (it may have a new address).
    var onConnectionChange: ((Connection) -> Void)?

    /// Poll fast while the popover is showing, slowly otherwise.
    var isPopoverOpen = false {
        didSet {
            guard isPopoverOpen != oldValue else { return }
            startPolling()
        }
    }

    var openInterval: Double = 3
    var closedInterval: Double = 45

    private var client: PranaClient?
    private var pollTask: Task<Void, Never>?
    private var failures = 0
    /// Bumped when a command starts and when it finishes. A read that began under an
    /// older value may carry the state from before the command, so it's discarded.
    private var commandEpoch = 0
    private var commandsInFlight = 0

    init(host: String) {
        self.host = host
        makeClient()
        startPolling()
    }

    /// Stops polling, for a unit that's been removed.
    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    // MARK: Polling

    private func makeClient() {
        do {
            client = try PranaClient(host: host)
            lastError = nil
        } catch {
            client = nil
            lastError = error.localizedDescription
            connection = .unreachable
        }
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                let interval = self.isPopoverOpen ? self.openInterval : self.closedInterval
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    /// Re-reads the unit. Returns whether the reading was applied, which it isn't
    /// when a command started or finished while it was in flight.
    @discardableResult
    func refresh() async -> Bool {
        guard let client else { return false }
        let epoch = commandEpoch
        do {
            let newState = try await client.state()
            guard epoch == commandEpoch, commandsInFlight == 0 else { return false }
            state = newState
            if let mmHg = newState.airPressure {
                pressureHistory.add(hPa: Pressure.hectopascals(fromMmHg: mmHg), at: .now)
            }
            connection = .ok
            failures = 0
            lastError = nil
            if info == nil, let loaded = try? await client.info() {
                info = loaded
                onInfo?(loaded)
            }
            return true
        } catch let error as PranaError where error.isCancellation {
            return false
        } catch is CancellationError {
            return false
        } catch {
            failures += 1
            connection = failures >= 3 ? .unreachable : .stale
            lastError = error.localizedDescription
            return false
        }
    }

    // MARK: Commands

    /// Update local state right away, send the command, then re-read the device.
    /// The unit answers "ok" even to commands it ignores, so `ignored` checks the
    /// re-read state and returns a message to show when the command didn't take.
    private func perform(
        _ mutate: (inout PranaState) -> Void,
        ignored: ((PranaState) -> String?)? = nil,
        _ command: @escaping @Sendable (PranaClient) async throws -> Void
    ) {
        if var s = state {
            mutate(&s)
            state = s
        }
        guard let client else { return }
        commandEpoch += 1
        commandsInFlight += 1
        Task {
            var sent = false
            do {
                try await command(client)
                commandError = nil
                sent = true
            } catch {
                commandError = error.localizedDescription
            }
            commandsInFlight -= 1
            commandEpoch += 1
            try? await Task.sleep(for: .milliseconds(600))
            if await refresh(), sent, let ignored, let state, let message = ignored(state) {
                commandError = message
            }
        }
    }

    func setLevel(_ level: Int, fan: FanType) {
        let target: FanType = (state?.bound ?? true) ? .bounded : fan
        perform({ $0.setFan(target) { $0.speed = level } }) {
            try await $0.setSpeed(level: level, fan: target)
        }
    }

    func setPower(_ on: Bool) {
        let bound = state?.bound ?? true
        let fans: [FanType] = bound ? [.bounded] : [.supply, .extract]
        perform({ s in fans.forEach { s.setFan($0) { $0.isOn = on } } }) { client in
            for fan in fans {
                try await client.setPower(on, fan: fan)
            }
        }
    }

    /// Turning a fan mode on switches the other fan modes off first, so the
    /// chosen mode is the last command the unit receives.
    func set(_ sw: PranaSwitch, _ on: Bool) {
        let offs = on ? (state?.conflictingModes(for: sw) ?? []) : []
        perform({ $0.setSwitch(sw, on) }, ignored: { state in
            guard !state.applied(sw, on) else { return nil }
            if sw == .bound {
                return on ? "The unit didn't link the fans" : "The unit didn't unlink the fans"
            }
            return "The unit didn't turn \(sw.title) \(on ? "on" : "off")"
        }) { client in
            for other in offs {
                try await client.setSwitch(other, false)
            }
            try await client.setSwitch(sw, on)
        }
    }

    /// `level` is 0...6, matching what the unit reports.
    func setBrightness(level: Int) {
        perform({ $0.brightness = level }) {
            try await $0.setBrightness(level: level)
        }
    }
}
