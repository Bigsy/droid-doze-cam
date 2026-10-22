import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// launchd opens the login service's log as its stdout and stderr, so the service rotates it itself.
public enum LogRotation {
    /// When `descriptors` write to the file at `path` and it has grown past `limit` bytes, keeps it as
    /// `path.1` and points the descriptors at a new, empty file. Returns true when it rotated.
    @discardableResult
    public static func rotateIfNeeded(path: String, limit: Int, descriptors: [Int32] = [STDOUT_FILENO, STDERR_FILENO]) -> Bool {
        guard let first = descriptors.first else { return false }
        var current = stat(), onDisk = stat()
        guard fstat(first, &current) == 0, stat(path, &onDisk) == 0,
              current.st_dev == onDisk.st_dev, current.st_ino == onDisk.st_ino,
              Int(current.st_size) > limit, rename(path, path + ".1") == 0 else { return false }
        let fresh = open(path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o644)
        guard fresh >= 0 else { return false }
        for descriptor in descriptors { _ = dup2(fresh, descriptor) }
        close(fresh)
        return true
    }
}
