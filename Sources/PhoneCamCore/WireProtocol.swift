import Foundation

public extension Data {
    func bigEndianUInt32(at offset: Int) throws -> UInt32 {
        guard offset >= 0, count >= 4, offset <= count - 4 else { throw PhoneCamError.message("Truncated 32-bit field.") }
        return (0..<4).reduce(UInt32(0)) { ($0 << 8) | UInt32(self[index(startIndex, offsetBy: offset + $1)]) }
    }
    func bigEndianUInt64(at offset: Int) throws -> UInt64 {
        guard offset >= 0, count >= 8, offset <= count - 8 else { throw PhoneCamError.message("Truncated 64-bit field.") }
        return (0..<8).reduce(UInt64(0)) { ($0 << 8) | UInt64(self[index(startIndex, offsetBy: offset + $1)]) }
    }
}

public struct StreamHeader: Equatable {
    public let width: Int
    public let height: Int
    public init(data: Data) throws {
        guard data.count == 12 else { throw PhoneCamError.message("Invalid scrcpy video header length.") }
        let codec = try data.bigEndianUInt32(at: 0)
        guard codec == 0x68323634 else { throw PhoneCamError.message("Expected H.264 codec; received \(String(codec, radix: 16)).") }
        width = Int(try data.bigEndianUInt32(at: 4)); height = Int(try data.bigEndianUInt32(at: 8))
        guard (1...8192).contains(width), (1...8192).contains(height), width * height <= 33_554_432 else {
            throw PhoneCamError.message("Unsafe video dimensions \(width)x\(height).")
        }
    }
}

public struct PacketHeader: Equatable {
    public let isConfiguration: Bool
    public let isKeyFrame: Bool
    public let presentationTimeMicroseconds: UInt64
    public let size: Int
    public init(data: Data) throws {
        guard data.count == 12 else { throw PhoneCamError.message("Invalid scrcpy packet header length.") }
        let flags = try data.bigEndianUInt64(at: 0)
        isConfiguration = flags & (1 << 63) != 0
        isKeyFrame = flags & (1 << 62) != 0
        presentationTimeMicroseconds = flags & ((1 << 62) - 1)
        size = Int(try data.bigEndianUInt32(at: 8))
        guard size > 0, size <= Constants.maxPacketBytes else { throw PhoneCamError.message("Rejected packet length \(size).") }
    }
}

public enum AnnexB {
    /// A scrcpy packet is an access unit, not an arbitrary TCP chunk. Call only after readExact(size).
    public static func nalUnits(_ packet: Data) throws -> [Data] {
        guard !packet.isEmpty, packet.count <= Constants.maxPacketBytes else { throw PhoneCamError.message("Invalid H.264 packet size.") }
        return try packet.withUnsafeBytes { raw -> [Data] in
            let b = raw.bindMemory(to: UInt8.self)
            var starts: [(Int, Int)] = []
            var i = 0
            while i + 2 < b.count {
                if b[i] == 0 && b[i+1] == 0 {
                    if b[i+2] == 1 { starts.append((i, 3)); i += 3; continue }
                    if i + 3 < b.count && b[i+2] == 0 && b[i+3] == 1 { starts.append((i, 4)); i += 4; continue }
                }
                i += 1
            }
            guard let first = starts.first, b[0..<first.0].allSatisfy({ $0 == 0 }) else {
                throw PhoneCamError.message("H.264 packet has no Annex-B start code.")
            }
            var result: [Data] = []
            for (n, pair) in starts.enumerated() {
                let start = pair.0 + pair.1
                var end = n + 1 < starts.count ? starts[n+1].0 : b.count
                // trailing_zero_8bits are outside RBSP; RBSP ends with a stop bit.
                while end > start && b[end-1] == 0 { end -= 1 }
                guard end > start else { throw PhoneCamError.message("Empty H.264 NAL unit.") }
                guard b[start] & 0x80 == 0 else { throw PhoneCamError.message("Invalid H.264 forbidden_zero_bit.") }
                result.append(Data(b[start..<end]))
            }
            return result
        }
    }
    public static func avcc(_ nals: [Data]) throws -> Data {
        var result = Data()
        for nal in nals {
            guard !nal.isEmpty, nal.count <= Constants.maxPacketBytes,
                  result.count + nal.count + 4 <= Constants.maxPacketBytes else { throw PhoneCamError.message("Oversized H.264 access unit.") }
            var length = UInt32(nal.count).bigEndian
            withUnsafeBytes(of: &length) { result.append(contentsOf: $0) }
            result.append(nal)
        }
        return result
    }
}

/// scrcpy formats socket SCIDs as exactly eight lower-case hex digits (including leading zeros).
public struct ScrcpySessionID: Equatable, Sendable {
    public let raw: UInt32
    public init(_ raw: UInt32) throws {
        guard raw <= 0x7fffffff else { throw PhoneCamError.message("scrcpy session ID must be a positive signed 31-bit value.") }
        self.raw = raw
    }
    public var hex: String { String(format: "%08x", raw) }
    public var socketName: String { "scrcpy_" + hex }
}
