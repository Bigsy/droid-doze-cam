import Foundation

/// Device declarations are hints, not a guarantee that every reported mode works.
public struct AndroidCameraMode: Equatable, Codable, Sendable {
    public let size: VideoSize
    public let frameRates: [Int]
    public let highSpeed: Bool
}

public struct AndroidCameraInfo: Equatable, Codable, Sendable {
    public let id: String
    public let facing: String
    public var frameRates: [Int] = []
    public var minimumZoom: Double?
    public var maximumZoom: Double?
    public var modes: [AndroidCameraMode] = []

    public static func parse(_ output: String) -> [Self] {
        var cameras: [Self] = []
        var highSpeed = false
        for line in output.components(separatedBy: .newlines) {
            if let fields = captures(#"--camera-id=([A-Za-z0-9_.-]+)\s+\((front|back|external),"#, line) {
                var camera = Self(id: fields[0], facing: fields[1])
                camera.frameRates = rates(line)
                if let zoom = captures(#"zoom-range=\[([0-9.,]+),\s+([0-9.,]+)\]"#, line),
                   let lower = Double(zoom[0].replacingOccurrences(of: ",", with: ".")),
                   let upper = Double(zoom[1].replacingOccurrences(of: ",", with: ".")),
                   lower.isFinite, upper.isFinite, lower > 0, lower <= upper {
                    camera.minimumZoom = lower; camera.maximumZoom = upper
                }
                cameras.append(camera); highSpeed = false
            } else if line.contains("High speed capture") {
                highSpeed = true
            } else if !cameras.isEmpty, let fields = captures(#"^\s+- (\d+x\d+)"#, line),
                      let size = try? VideoSize(fields[0]) {
                let index = cameras.count - 1
                cameras[index].modes.append(AndroidCameraMode(size: size,
                    frameRates: highSpeed ? rates(line) : cameras[index].frameRates, highSpeed: highSpeed))
            }
        }
        return cameras
    }

    public func reports(size: VideoSize?, fps: Int) -> Bool? {
        let candidates = modes.filter { $0.highSpeed == (fps > 60) && (size == nil || $0.size == size) }
        if modes.isEmpty { return nil }
        guard !candidates.isEmpty else { return false }
        if candidates.contains(where: { $0.frameRates.contains(fps) }) { return true }
        return candidates.allSatisfy { !$0.frameRates.isEmpty } ? false : nil
    }

    private static func rates(_ line: String) -> [Int] {
        guard let fields = captures(#"fps=\{([^}]*)\}"#, line) else { return [] }
        return fields[0].split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }.filter { $0 > 0 }
    }
}

public struct AndroidVideoEncoder: Equatable, Codable, Sendable {
    public let name: String
    public let hardware: Bool

    public static func parse(_ output: String) -> [Self] {
        output.components(separatedBy: .newlines).compactMap { line in
            guard let fields = captures(#"--video-codec=h264\s+--video-encoder=([A-Za-z0-9_.-]+)(?:\s|$)"#, line) else { return nil }
            return Self(name: fields[0], hardware: line.contains("(hw)"))
        }
    }
}

private func captures(_ pattern: String, _ text: String) -> [String]? {
    guard let expression = try? NSRegularExpression(pattern: pattern),
          let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)) else { return nil }
    return (1..<match.numberOfRanges).compactMap { Range(match.range(at: $0), in: text).map { String(text[$0]) } }
}
