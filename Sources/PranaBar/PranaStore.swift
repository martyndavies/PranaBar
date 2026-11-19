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
    /// The last command sent. Each command waits for the one before, so a double
    /// click can't send two toggles that both read the same state.
    private var lastCommand: Task<Void, Never>?
    /// What the unit was doing before the app turned Boost on, to go back to when
    /// it's turned off. Nil if Boost was started elsewhere.
    private var beforeBoost: (level: Int, mode: PranaSwitch?)?
    /// The Auto mode that was on when the app turned the unit off, to turn back
    /// on with it.
    private var beforeOff: PranaSwitch?

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
        let previous = lastCommand
        lastCommand = Task {
            await previous?.value
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
        beforeBoost = nil // a speed change ends Boost
        perform({ $0.setLevel(level, fan: target) }) {
            try await $0.setSpeed(level: level, fan: target)
        }
    }

    func setPower(_ on: Bool) {
        on ? powerOn() : powerOff()
    }

    /// Auto and Auto+ block power-off: the unit answers "ok" and keeps running.
    /// So turn the mode off first, then the whole unit with `bounded`. auto=false
    /// is used for both, since it also ends Auto+ and, unlike auto_plus, honours
    /// its value. The mode is remembered, because the unit comes back without it.
    private func powerOff() {
        beforeOff = state?.powerOffBlockedBy
        beforeBoost = nil
        perform({ s in
            if s.powerOffBlockedBy != nil || s.bound {
                s.setPower(false, fan: .bounded)
            } else {
                s.setPower(false, fan: .supply)
                s.setPower(false, fan: .extract)
            }
        }, ignored: { $0.isOn ? "The unit didn't turn off" : nil }) { client in
            let fresh = try await client.state()
            if fresh.powerOffBlockedBy != nil {
                try await client.setSwitch(.auto, false)
                try await client.setPower(false, fan: .bounded)
            } else if fresh.bound {
                try await client.setPower(false, fan: .bounded)
            } else {
                // Unlinked fans stay unlinked this way when the unit comes back.
                try await client.setPower(false, fan: .supply)
                try await client.setPower(false, fan: .extract)
            }
        }
    }

    /// Turns the unit back on, then the Auto mode that was on when the app turned
    /// it off.
    private func powerOn() {
        let resume = beforeOff
        beforeOff = nil
        let fans: [FanType] = (state?.bound ?? true) ? [.bounded] : [.supply, .extract]
        perform({ s in
            fans.forEach { s.setPower(true, fan: $0) }
            if let resume { s.setSwitch(resume, true) }
        }, ignored: { state in
            if !state.isOn { return "The unit didn't turn on" }
            if let resume, !state.applied(resume, true) { return "The unit didn't turn \(resume.title) back on" }
            return nil
        }) { client in
            for fan in fans {
                try await client.setPower(true, fan: fan)
            }
            guard let resume else { return }
            let fresh = try await client.state()
            if !resume.isToggle || !fresh[keyPath: resume.keyPath] {
                try await client.setSwitch(resume, true)
            }
        }
    }

    /// Turning a fan mode on switches the other fan modes off first, so the
    /// chosen mode is the last command the unit receives. Auto+ and Winter toggle
    /// whatever value is sent, so the unit is read fresh and they're only sent when
    /// it isn't already in the target state.
    func set(_ sw: PranaSwitch, _ on: Bool) {
        if let s = state, s.boost, (sw == .boost && !on) || (on && sw.isFanMode && sw != .boost) {
            leaveBoost(for: sw == .boost ? nil : sw)
            return
        }
        if sw == .boost, on, let s = state {
            let mode = s.activeFanMode
            beforeBoost = (s.primaryFan.speed, mode == .auto || mode == .autoPlus ? mode : nil)
        }
        perform({ $0.setSwitch(sw, on) }, ignored: { state in
            guard !state.applied(sw, on) else { return nil }
            if sw == .bound {
                return on ? "The unit didn't link the fans" : "The unit didn't unlink the fans"
            }
            return "The unit didn't turn \(sw.title) \(on ? "on" : "off")"
        }) { client in
            let fresh = try await client.state()
            if on {
                for other in fresh.conflictingModes(for: sw) {
                    if other == .boost {
                        // Ignored by the unit; a speed change ends Boost.
                        try await client.setSpeed(level: 1, fan: .bounded)
                    } else {
                        try await client.setSwitch(other, false)
                    }
                }
            }
            if !sw.isToggle || fresh[keyPath: sw.keyPath] != on {
                try await client.setSwitch(sw, on)
            }
        }
    }

    /// The unit ignores boost=false, but any speed change ends Boost. So go back to
    /// the level from before Boost (or level 1, Night, if Boost was started
    /// elsewhere), then turn on `mode`, or the Auto mode that was on before.
    private func leaveBoost(for mode: PranaSwitch?) {
        let previous = beforeBoost
        beforeBoost = nil
        let resume = mode ?? previous?.mode
        let level = resume == .night ? 1 : (previous?.level ?? 1)
        perform({ s in
            s.setLevel(level, fan: .bounded)
            if let resume { s.setSwitch(resume, true) }
        }, ignored: { state in
            if state.boost { return "The unit didn't leave Boost" }
            if let resume, !state.applied(resume, true) { return "The unit didn't turn \(resume.title) on" }
            return nil
        }) { client in
            try await client.setSpeed(level: level, fan: .bounded)
            guard let resume, resume != .night else { return }
            let fresh = try await client.state()
            if !resume.isToggle || !fresh[keyPath: resume.keyPath] {
                try await client.setSwitch(resume, true)
            }
        }
    }

    /// `level` is 0...6, matching what the unit reports.
    func setBrightness(level: Int) {
        perform({ $0.brightness = level }) {
            try await $0.setBrightness(level: level)
        }
    }
}
