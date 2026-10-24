import Foundation

/// Persisted appearance only. Track IDs and sync offsets belong to the current video.
public struct SubtitleAppearance: Codable, Equatable, Sendable {
    public var size: Double = 100
    public var textColor: UInt32 = 0xFFFFFF
    public var backgroundColor: UInt32 = 0x000000
    public var backgroundOpacity: Double = 65
    public var verticalOffset: Double = 0
    public init() {}
    public var normalized: Self {
        var value = self
        value.size = size.isFinite ? min(200, max(50, size)) : 100
        value.backgroundOpacity = backgroundOpacity.isFinite ? min(100, max(0, backgroundOpacity)) : 65
        value.verticalOffset = verticalOffset.isFinite ? min(360, max(0, verticalOffset)) : 0
        value.textColor &= 0xFFFFFF; value.backgroundColor &= 0xFFFFFF
        return value
    }
    public var vlcOptions: [String] {
        let s = normalized
        return ["--text-renderer=freetype", "--freetype-rel-fontsize=20",
                "--sub-text-scale=\(Int(s.size.rounded()))", "--freetype-color=\(s.textColor)",
                "--freetype-background-color=\(s.backgroundColor)",
                "--freetype-background-opacity=\(Int((s.backgroundOpacity * 255 / 100).rounded()))",
                "--sub-margin=\(Int(s.verticalOffset.rounded()))"]
    }
    public static func delayMicroseconds(_ seconds: Double) -> Int {
        guard seconds.isFinite else { return 0 }
        return Int((min(60, max(-60, seconds)) * 1_000_000).rounded())
    }
}
