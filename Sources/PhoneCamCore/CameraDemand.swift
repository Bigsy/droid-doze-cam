import Foundation

/// The camera extension publishes a short-lived lease while an app is using its source stream.
/// A stale lease is inactive, so a crashed extension cannot leave the phone camera running.
public struct CameraDemand: Codable, Equatable, Sendable {
    public let active: Bool
    public let updatedAt: TimeInterval

    public init(active: Bool, updatedAt: TimeInterval = Date().timeIntervalSince1970) {
        self.active = active
        self.updatedAt = updatedAt
    }

    public func isActive(at time: TimeInterval = Date().timeIntervalSince1970) -> Bool {
        active && updatedAt <= time + 1 && time - updatedAt < 4
    }
}

public struct CameraDemandFile: Sendable {
    public let url: URL

    public init(directory: URL) {
        url = directory.appendingPathComponent("camera-demand.json", isDirectory: false)
    }

    #if os(macOS)
    public init(appGroup: String) throws {
        guard let directory = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) else {
            throw PhoneCamError.message("The signed camera app group is unavailable: \(appGroup)")
        }
        self.init(directory: directory)
    }
    #endif

    public func publish(active: Bool) throws {
        let data = try JSONEncoder().encode(CameraDemand(active: active))
        try data.write(to: url, options: .atomic)
    }

    public func current(at time: TimeInterval = Date().timeIntervalSince1970) -> Bool {
        guard let data = try? Data(contentsOf: url),
              let demand = try? JSONDecoder().decode(CameraDemand.self, from: data) else { return false }
        return demand.isActive(at: time)
    }
}
