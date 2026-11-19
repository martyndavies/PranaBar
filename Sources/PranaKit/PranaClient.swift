import Foundation

public enum PranaError: Error, LocalizedError {
    case http(Int)
    case transport(Error)
    case decoding(Error)
    case invalidHost(String)
    case rejected(String)

    /// The request was cancelled, e.g. because polling restarted. Not a device failure.
    public var isCancellation: Bool {
        if case .transport(let error) = self {
            return error is CancellationError || (error as? URLError)?.code == .cancelled
        }
        return false
    }

    public var errorDescription: String? {
        switch self {
        case .http(let code): "Device returned HTTP \(code)"
        case .transport(let error): error.localizedDescription
        case .decoding: "Couldn't read the device's response"
        case .invalidHost(let host): "Invalid host: \(host)"
        case .rejected(let result): "Device rejected the command: \(result)"
        }
    }
}

/// Client for the Prana local HTTP API (firmware 47+). Plain HTTP on port 80, no auth.
public actor PranaClient {
    public let baseURL: URL
    private let session: URLSession
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    public init(host: String, port: Int = 80, timeout: TimeInterval = 4) throws {
        guard let url = URL(string: "http://\(host):\(port)") else {
            throw PranaError.invalidHost(host)
        }
        baseURL = url
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout * 2
        // Wait for the network path rather than failing at once. Right after launch
        // macOS briefly refuses local network connections ("Local network prohibited",
        // NSURLError -1009) until the app's Local Network permission takes effect.
        // An unreachable unit still fails via the timeouts above, since Wi-Fi is up.
        config.waitsForConnectivity = true
        session = URLSession(configuration: config)
    }

    // MARK: Reads

    public func info() async throws -> DeviceInfo {
        try await get("info")
    }

    /// The device sometimes drops a request, so retry once before failing.
    public func state() async throws -> PranaState {
        do {
            return try await get("getState")
        } catch PranaError.transport {
            try await Task.sleep(for: .milliseconds(300))
            return try await get("getState")
        }
    }

    // MARK: Writes

    /// `level` is 1...maxLevel (1...6 on a Prana 150). The device wants level * 10.
    public func setSpeed(level: Int, fan: FanType) async throws {
        try await post("setSpeed", SpeedBody(speed: level * 10, fanType: fan.rawValue))
    }

    public func setPower(_ on: Bool, fan: FanType) async throws {
        try await post("setSpeedIsOn", PowerBody(value: on, fanType: fan.rawValue))
    }

    public func setSwitch(_ sw: PranaSwitch, _ on: Bool) async throws {
        try await post("setSwitch", SwitchBody(switchType: sw.rawValue, value: on))
    }

    /// `level` is 0...6, the same scale `/getState` reports. The device wants 0, 1, 2, 4, 8, 16 or 32.
    public func setBrightness(level: Int) async throws {
        try await post("setBrightness", BrightnessBody(brightness: Brightness.raw(forLevel: level)))
    }

    // MARK: Plumbing

    private func get<T: Decodable>(_ path: String) async throws -> T {
        let data = try await send(URLRequest(url: baseURL.appending(path: path)))
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw PranaError.decoding(error)
        }
    }

    private func post<B: Encodable>(_ path: String, _ body: B) async throws {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(body)
        try Self.checkCommandResult(try await send(request))
    }

    /// Commands answer `{"result":"ok"}` with HTTP 200 (fw 49). Treat any other
    /// `result` as a rejection. A body without `result` is let through, because
    /// other firmware may reply differently and only `"ok"` has been observed.
    static func checkCommandResult(_ data: Data) throws {
        struct Reply: Decodable { let result: String? }
        guard let result = (try? JSONDecoder().decode(Reply.self, from: data))?.result else { return }
        if result.lowercased() != "ok" {
            throw PranaError.rejected(result)
        }
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw PranaError.transport(error)
        }
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw PranaError.http(http.statusCode)
        }
        return data
    }
}

// Request bodies. Field names match the device API exactly.
struct SpeedBody: Encodable { let speed: Int; let fanType: String }
struct PowerBody: Encodable { let value: Bool; let fanType: String }
struct SwitchBody: Encodable { let switchType: String; let value: Bool }
struct BrightnessBody: Encodable { let brightness: Int }
