import Foundation

/// What the login service is doing. `serve` writes it; the menu bar app shows it.
public struct ServiceStatus: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable { case idle, starting, streaming, reconnecting, problem }
    public let state: State
    /// The phone in use, or why it is unavailable.
    public let detail: String
    /// A status left by a process that has exited is stale.
    public let pid: Int32

    public init(state: State, detail: String, pid: Int32 = ProcessInfo.processInfo.processIdentifier) {
        self.state = state; self.detail = detail; self.pid = pid
    }
}

public struct ServiceStatusFile: Sendable {
    public let url: URL

    public init(directory: URL) {
        url = directory.appendingPathComponent("service-status.json", isDirectory: false)
    }

    public func publish(_ status: ServiceStatus) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(status).write(to: url, options: .atomic)
    }

    public func read() -> ServiceStatus? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ServiceStatus.self, from: data)
    }

    /// Leaves another process's status alone, such as a second `serve` that exits early.
    public func remove(ownedBy pid: Int32 = ProcessInfo.processInfo.processIdentifier) {
        if read()?.pid == pid { try? FileManager.default.removeItem(at: url) }
    }
}
