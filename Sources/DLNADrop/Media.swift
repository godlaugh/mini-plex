import Foundation

/// File types served to renderers, and the DLNA metadata attached to each.
enum Media {
    /// Same flags Plex DLNA Server sends: streaming transfer mode, byte-range seek (OP=01), not converted.
    static let dlnaFeatures = "DLNA.ORG_OP=01;DLNA.ORG_CI=0;DLNA.ORG_FLAGS=01500000000000000000000000000000"

    static let videoMime: [String: String] = [
        "mp4": "video/mp4", "m4v": "video/mp4",
        "mov": "video/quicktime",
        "mkv": "video/x-matroska",
        "avi": "video/avi",
        "wmv": "video/x-ms-wmv", "asf": "video/x-ms-asf",
        "ts": "video/vnd.dlna.mpeg-tts", "m2ts": "video/vnd.dlna.mpeg-tts", "mts": "video/vnd.dlna.mpeg-tts",
        "mpg": "video/mpeg", "mpeg": "video/mpeg", "vob": "video/mpeg",
        "webm": "video/webm",
        "flv": "video/x-flv",
        "3gp": "video/3gpp",
        "rm": "application/vnd.rn-realmedia", "rmvb": "application/vnd.rn-realmedia-vbr",
    ]

    static let subtitleExtensions = ["srt", "ass", "ssa", "smi", "vtt"]

    static func isVideo(_ url: URL) -> Bool {
        videoMime[url.pathExtension.lowercased()] != nil
    }

    static func mime(for url: URL) -> String {
        videoMime[url.pathExtension.lowercased()] ?? "application/octet-stream"
    }

    static func subtitleMime(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "srt": return "text/srt"
        case "ass", "ssa": return "text/x-ssa"
        case "smi": return "smi/caption"
        case "vtt": return "text/vtt"
        default: return "text/plain"
        }
    }

    static func protocolInfo(for url: URL) -> String {
        "http-get:*:\(mime(for: url)):\(dlnaFeatures)"
    }

    /// Sidecar subtitle next to a video, e.g. `Movie.srt` or `Movie.zh.srt` for `Movie.mkv`.
    static func sidecarSubtitle(for video: URL) -> URL? {
        let dir = video.deletingLastPathComponent()
        let stem = video.deletingPathExtension().lastPathComponent
        for ext in subtitleExtensions {
            let exact = dir.appendingPathComponent(stem).appendingPathExtension(ext)
            if FileManager.default.fileExists(atPath: exact.path) { return exact }
        }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return nil }
        let match = names.sorted().first { name in
            let lower = name.lowercased()
            return name.hasPrefix(stem + ".") && subtitleExtensions.contains { lower.hasSuffix("." + $0) }
        }
        return match.map { dir.appendingPathComponent($0) }
    }
}
