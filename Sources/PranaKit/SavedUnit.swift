import Foundation

/// A unit the user has added. `deviceID` is the `manufactureId` from `/info`, which
/// is also the unit's Bonjour instance name; it's nil until the unit has answered
/// once (a unit added by address while offline, or one carried over from the old
/// single-host setting).
public struct SavedUnit: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var deviceID: String?
    public var name: String
    public var host: String

    public init(id: UUID = UUID(), deviceID: String? = nil, name: String, host: String) {
        self.id = id
        self.deviceID = deviceID
        self.name = name
        self.host = host
    }

    /// Bonjour names and `/info` agree on this unit, but compare loosely anyway.
    public func matches(deviceID other: String) -> Bool {
        deviceID?.caseInsensitiveCompare(other) == .orderedSame
    }
}

extension Array where Element == SavedUnit {
    /// Whether a unit seen on the network is already saved.
    public func contains(deviceID: String, host: String?) -> Bool {
        contains { $0.matches(deviceID: deviceID) || (host != nil && $0.host == host) }
    }

    /// Records what Bonjour or `/info` reported about a saved unit: its device ID
    /// once known, and its current address, since routers hand out new ones.
    /// Returns whether anything changed.
    @discardableResult
    public mutating func update(_ id: SavedUnit.ID, deviceID: String? = nil, name: String? = nil, host: String? = nil) -> Bool {
        guard let i = firstIndex(where: { $0.id == id }) else { return false }
        var unit = self[i]
        if let deviceID, !deviceID.isEmpty { unit.deviceID = deviceID }
        if let name, !name.isEmpty { unit.name = name }
        if let host, !host.isEmpty { unit.host = host }
        guard unit != self[i] else { return false }
        self[i] = unit
        return true
    }

    /// The saved unit Bonjour is describing, matched by device ID.
    public func unit(withDeviceID deviceID: String) -> SavedUnit? {
        first { $0.matches(deviceID: deviceID) }
    }
}
