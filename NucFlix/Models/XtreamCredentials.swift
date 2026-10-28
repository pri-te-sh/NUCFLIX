import Foundation

enum LiveStreamFormat: String, Codable, CaseIterable, Identifiable {
    case hlsLive = "m3u8"        // /live/{user}/{pass}/{id}.m3u8 (Best for iOS AVPlayer)
    case hlsRoot = "m3u8_root"   // /{user}/{pass}/{id}.m3u8 (Legacy Xtream HLS path)
    case mpegTS = "ts"           // /live/{user}/{pass}/{id}.ts (Direct MPEG-TS stream)

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .hlsLive: return "HLS Stream (.m3u8)"
        case .hlsRoot: return "HLS Root (.m3u8)"
        case .mpegTS: return "Direct MPEG-TS (.ts)"
        }
    }
}

struct XtreamCredentials: Equatable, Identifiable {
    var id: String { "\(normalizedBaseURL)|\(username)" }
    var lineName: String
    var serverURL: String
    var username: String
    var password: String

    /// Normalized base URL without trailing slash or `player_api.php` suffix.
    /// A bare hostname defaults to **https** so the username/password embedded in every
    /// request URL are not sent in clear text; panels without TLS fall back to HTTP
    /// automatically at sign-in and the working scheme is what gets persisted.
    var normalizedBaseURL: String {
        var raw = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !raw.lowercased().hasPrefix("http://") && !raw.lowercased().hasPrefix("https://") {
            raw = "https://" + raw
        }
        if let range = raw.range(of: "/player_api.php", options: .caseInsensitive) {
            raw = String(raw[..<range.lowerBound])
        }
        if let range = raw.range(of: "/get.php", options: .caseInsensitive) {
            raw = String(raw[..<range.lowerBound])
        }
        while raw.hasSuffix("/") {
            raw.removeLast()
        }
        return raw
    }

    var encodedUsername: String {
        username.addingPercentEncoding(withAllowedCharacters: Self.pathSegmentAllowed) ?? username
    }

    var encodedPassword: String {
        password.addingPercentEncoding(withAllowedCharacters: Self.pathSegmentAllowed) ?? password
    }

    /// Path-segment-safe characters (unlike `.urlPathAllowed`, this also escapes `/`, `?`, `#`)
    private static let pathSegmentAllowed: CharacterSet = {
        var set = CharacterSet.urlPathAllowed
        set.remove(charactersIn: "/?#")
        return set
    }()

    func liveStreamURL(streamID: Int, format: LiveStreamFormat = .hlsLive) -> URL? {
        switch format {
        case .hlsLive:
            return URL(string: "\(normalizedBaseURL)/live/\(encodedUsername)/\(encodedPassword)/\(streamID).m3u8")
        case .hlsRoot:
            return URL(string: "\(normalizedBaseURL)/\(encodedUsername)/\(encodedPassword)/\(streamID).m3u8")
        case .mpegTS:
            return URL(string: "\(normalizedBaseURL)/live/\(encodedUsername)/\(encodedPassword)/\(streamID).ts")
        }
    }

    func vodStreamURL(streamID: Int, containerExtension: String?) -> URL? {
        let ext = (containerExtension?.isEmpty == false) ? containerExtension! : "mp4"
        return URL(string: "\(normalizedBaseURL)/movie/\(encodedUsername)/\(encodedPassword)/\(streamID).\(ext)")
    }

    func seriesEpisodeURL(episodeID: String, containerExtension: String?) -> URL? {
        let ext = (containerExtension?.isEmpty == false) ? containerExtension! : "mp4"
        return URL(string: "\(normalizedBaseURL)/series/\(encodedUsername)/\(encodedPassword)/\(episodeID).\(ext)")
    }
}
