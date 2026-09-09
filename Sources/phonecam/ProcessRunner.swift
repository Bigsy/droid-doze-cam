import Foundation
import Darwin
import PhoneCamCore

func log(_ message: String) { FileHandle.standardError.write(Data(("[phonecam] " + message + "\n").utf8)) }

struct CommandResult { let status: Int32; let text: String }
private final class BoundedOutput: @unchecked Sendable {
    let lock = NSLock(); var data = Data()
    func append(_ chunk: Data) { lock.lock(); defer { lock.unlock() }; if data.count < 1_048_576 { data.append(chunk.prefix(1_048_576 - data.count)) } }
    var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding:data,as:UTF8.self) }
}

enum ProcessRunner {
    static func executable(_ name: String, override: String? = nil) throws -> String {
        if let override {
            let p = (override as NSString).expandingTildeInPath
            guard FileManager.default.isExecutableFile(atPath:p) else { throw PhoneCamError.message("Executable not found: \(p)") }; return URL(fileURLWithPath:p).path
        }
        let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator:":").map(String.init) + ["/opt/homebrew/bin","/usr/local/bin","/usr/bin","/bin"]
        for directory in paths where !directory.isEmpty {
            let p = URL(fileURLWithPath:directory).appendingPathComponent(name).path
            if FileManager.default.isExecutableFile(atPath:p) { return p }
        }
        throw PhoneCamError.message("\(name) is not installed. For Android: brew install --cask android-platform-tools")
    }
    static func stop(_ process: Process) {
        guard process.isRunning else { return }; process.terminate()
        let deadline = ProcessInfo.processInfo.systemUptime + 1
        while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline { Thread.sleep(forTimeInterval:0.02) }
        if process.isRunning { _ = kill(process.processIdentifier,SIGKILL) }
        process.waitUntilExit()
    }
    static func run(_ path: String, _ arguments: [String], timeout: Double = 15, cancellation: Cancellation? = nil, allowFailure: Bool = false) throws -> CommandResult {
        let process = Process(), pipe = Pipe(), output = BoundedOutput(), finished = DispatchSemaphore(value:0)
        process.executableURL = URL(fileURLWithPath:path); process.arguments = arguments
        process.standardInput = FileHandle.nullDevice; process.standardOutput = pipe; process.standardError = pipe
        try process.run()
        try? pipe.fileHandleForWriting.close()
        DispatchQueue.global(qos:.utility).async {
            defer { try? pipe.fileHandleForReading.close(); finished.signal() }
            while let chunk = try? pipe.fileHandleForReading.read(upToCount:16384), !chunk.isEmpty { output.append(chunk) }
        }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var interrupted = false
        while process.isRunning {
            if cancellation?.isCancelled == true || ProcessInfo.processInfo.systemUptime > deadline { interrupted = true; stop(process); break }
            Thread.sleep(forTimeInterval:0.025)
        }
        process.waitUntilExit()
        _ = finished.wait(timeout:.now()+2)
        if interrupted { throw PhoneCamError.message("Command cancelled or timed out: \(URL(fileURLWithPath:path).lastPathComponent)") }
        let result = CommandResult(status:process.terminationStatus,text:output.text.trimmingCharacters(in:.whitespacesAndNewlines))
        if !allowFailure && result.status != 0 { throw PhoneCamError.message("\(URL(fileURLWithPath:path).lastPathComponent) exited \(result.status): \(result.text)") }
        return result
    }
}

final class InstanceLock {
    private var fd: Int32 = -1
    init() throws {
        let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/PhoneCam",isDirectory:true)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let path = directory.appendingPathComponent("capture.lock").path
        fd = open(path,O_RDWR|O_CREAT|O_CLOEXEC|O_NOFOLLOW,0o600)
        guard fd >= 0 else { throw PhoneCamError.message("Cannot open capture lock: \(String(cString:strerror(errno)))") }
        guard flock(fd,LOCK_EX|LOCK_NB) == 0 else { close(fd); fd = -1; throw PhoneCamError.message("Another phonecam capture process is already running for this user.") }
    }
    deinit { if fd >= 0 { _ = flock(fd,LOCK_UN); close(fd) } }
}
