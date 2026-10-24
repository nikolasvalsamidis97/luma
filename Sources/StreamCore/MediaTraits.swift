import Foundation

/// Positive evidence only: an absent field means unknown, never “not available”.
public struct MediaTraits: Hashable, Codable, Sendable {
    public var resolution: String?
    public var multipleSubtitles: Bool
    public init(resolution: String? = nil, multipleSubtitles: Bool = false) {
        self.resolution = resolution; self.multipleSubtitles = multipleSubtitles
    }
    public static func resolution(width: Int, height: Int) -> String? {
        if (width >= 3800 && width <= 4200) || height == 2160 { return "4K" }
        if width == 1920 || height == 1080 { return "1080p" }
        return nil
    }
    public static func from(name: String, metadata: JSONValue = .null) -> Self {
        func matches(_ pattern: String) -> Bool { name.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil }
        let video = metadata["video"].object != nil ? metadata["video"] : metadata
        let width = video["width"].string.flatMap(Int.init) ?? 0
        let height = video["height"].string.flatMap(Int.init) ?? 0
        let measured = resolution(width: width, height: height)
        let labeled = matches(#"(?<![\p{L}\p{N}])(4K|2160P|UHD)(?![\p{L}\p{N}])"#) ? "4K" :
            matches(#"(?<![\p{L}\p{N}])(1080P|FHD)(?![\p{L}\p{N}])"#) ? "1080p" : nil
        let subtitles = metadata["subtitles"].array ?? metadata["subtitle"].array ?? []
        let count = metadata["subtitle_count"].string.flatMap(Int.init) ?? subtitles.count
        return Self(resolution: measured ?? labeled,
                    multipleSubtitles: count > 1 || matches(#"(?<![\p{L}\p{N}])(MULTI[\s_-]*SUB(?:S|TITLE|TITLES)?|MSUB)(?![\p{L}\p{N}])"#))
    }
    public func supplemented(by other: Self) -> Self {
        Self(resolution: resolution ?? other.resolution, multipleSubtitles: multipleSubtitles || other.multipleSubtitles)
    }
}
