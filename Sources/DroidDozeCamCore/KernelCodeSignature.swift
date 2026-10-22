#if os(macOS)
import Darwin

/// Code-signing state held by the kernel for a running process (see <sys/codesign.h>).
public struct KernelCodeSignature {
    private typealias CSOps = @convention(c) (pid_t, UInt32, UnsafeMutableRawPointer?, Int) -> Int32
    private static let csops: CSOps? = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "csops").map { unsafeBitCast($0, to: CSOps.self) }
    private static let statusOp: UInt32 = 0, identityOp: UInt32 = 11, teamIDOp: UInt32 = 14, validationCategoryOp: UInt32 = 17
    private static let validFlag: UInt32 = 0x1
    /// CS_VALIDATION_CATEGORY_DEVELOPMENT (Apple Development) and CS_VALIDATION_CATEGORY_DEVELOPER_ID.
    private static let appleIssuedDeveloperCategories: Set<UInt32> = [3, 6]
    public let valid: Bool
    public let identifier: String?
    public let teamID: String?
    /// How AMFI classified the signature's certificate, or nil if the kernel would not say.
    public let validationCategory: UInt32?

    /// The identifier and team ID come from the binary's own signature and do not show who issued its certificate.
    /// The validation category does: ad-hoc and locally trusted certificates fall outside these categories.
    public var isAppleIssuedDeveloperCode: Bool { validationCategory.map(Self.appleIssuedDeveloperCategories.contains) ?? false }

    public init?(pid: pid_t) {
        guard pid > 0, let csops = Self.csops else { return nil }
        var flags: UInt32 = 0
        guard csops(pid, Self.statusOp, &flags, MemoryLayout<UInt32>.size) == 0 else { return nil }
        valid = flags & Self.validFlag != 0
        identifier = Self.string(csops, pid, Self.identityOp)
        teamID = Self.string(csops, pid, Self.teamIDOp)
        var category: UInt32 = 0
        validationCategory = csops(pid, Self.validationCategoryOp, &category, MemoryLayout<UInt32>.size) == 0 ? category : nil
    }
    /// Identity and team ID come back as a blob: 4-byte magic, 4-byte length, then a NUL-terminated string.
    private static func string(_ csops: CSOps, _ pid: pid_t, _ op: UInt32) -> String? {
        var blob = [UInt8](repeating: 0, count: 512)
        guard blob.withUnsafeMutableBytes({ csops(pid, op, $0.baseAddress, $0.count) }) == 0 else { return nil }
        let text = blob[8...].prefix { $0 != 0 }
        return text.isEmpty ? nil : String(decoding: text, as: UTF8.self)
    }
}
#endif
