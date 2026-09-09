import Foundation
import Darwin
import PhoneCamCore

/// Private loopback connection to an adb USB forward. No LAN addresses are accepted.
final class USBConnection {
    private var fd: Int32 = -1
    private let cancellation: Cancellation
    init(port: UInt16, cancellation: Cancellation) throws {
        self.cancellation = cancellation
        fd = socket(AF_INET,SOCK_STREAM,0)
        guard fd >= 0 else { throw PhoneCamError.message("socket() failed") }
        do {
            _ = fcntl(fd,F_SETFD,FD_CLOEXEC)
            let old = fcntl(fd,F_GETFL,0); guard old >= 0, fcntl(fd,F_SETFL,old|O_NONBLOCK) >= 0 else { throw PhoneCamError.message("fcntl() failed") }
            var yes: Int32 = 1
            _ = setsockopt(fd,SOL_SOCKET,SO_NOSIGPIPE,&yes,socklen_t(MemoryLayout.size(ofValue:yes)))
            _ = setsockopt(fd,Int32(IPPROTO_TCP),TCP_NODELAY,&yes,socklen_t(MemoryLayout.size(ofValue:yes)))
            var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET); address.sin_port = port.bigEndian
            address.sin_addr = in_addr(s_addr:inet_addr("127.0.0.1"))
            let result = withUnsafePointer(to:&address) { $0.withMemoryRebound(to:sockaddr.self,capacity:1) { connect(fd,$0,socklen_t(MemoryLayout<sockaddr_in>.size)) } }
            if result != 0 {
                guard errno == EINPROGRESS else { throw PhoneCamError.message("ADB forward is not accepting connections yet.") }
                try wait(event:Int16(POLLOUT),deadline:ProcessInfo.processInfo.systemUptime+2)
                var error: Int32 = 0, length = socklen_t(MemoryLayout<Int32>.size)
                guard getsockopt(fd,SOL_SOCKET,SO_ERROR,&error,&length) == 0, error == 0 else { throw PhoneCamError.message("ADB forward connection failed.") }
            }
        } catch { close(fd); fd = -1; throw error }
    }
    deinit { if fd >= 0 { close(fd) } }
    private func wait(event: Int16, deadline: Double) throws {
        while !cancellation.isCancelled {
            if ProcessInfo.processInfo.systemUptime >= deadline { throw PhoneCamError.message("USB stream timed out; reconnecting may be necessary.") }
            var p = pollfd(fd:fd,events:event,revents:0)
            let r = poll(&p,1,100)
            if r < 0 { if errno == EINTR { continue }; throw PhoneCamError.message("poll() failed") }
            // Drain bytes even when POLLHUP is also set.
            if p.revents & event != 0 { return }
            if p.revents & Int16(POLLERR|POLLHUP|POLLNVAL) != 0 { throw PhoneCamError.message("USB stream disconnected.") }
        }
        throw PhoneCamError.message("Capture cancelled.")
    }
    func readExact(_ count: Int, timeout: Double = 10) throws -> Data {
        guard count > 0, count <= Constants.maxPacketBytes else { throw PhoneCamError.message("Invalid socket read size.") }
        var data = Data(count:count)
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        try data.withUnsafeMutableBytes { raw in
            var offset = 0
            while offset < count {
                try wait(event:Int16(POLLIN),deadline:deadline)
                let n = recv(fd,raw.baseAddress!.advanced(by:offset),count-offset,0)
                if n == 0 { throw PhoneCamError.message("Phone closed its USB video stream.") }
                if n < 0 {
                    if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR { continue }
                    throw PhoneCamError.message("USB read failed: \(String(cString:strerror(errno)))")
                }
                offset += n
            }
        }
        return data
    }
}
