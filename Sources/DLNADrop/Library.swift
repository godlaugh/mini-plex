import CryptoKit
import Foundation

/// One entry in the ContentDirectory tree.
struct MediaObject {
    enum Kind { case root, folder, video }
    let id: String
    let parentID: String
    let title: String
    let kind: Kind
    let url: URL?
    let size: Int64
}

/// Thread-safe view of what is shared. The UI writes roots; the HTTP server reads.
final class Library: @unchecked Sendable {
    static let shared = Library()
    static let rootID = "0"

    private let lock = NSLock()
    private var roots: [URL] = []
    private var paths: [String: URL] = [:]  // object id -> file URL
    private(set) var systemUpdateID: UInt32 = 1

    func setRoots(_ urls: [URL]) {
        lock.lock()
        roots = urls.map { $0.standardizedFileURL }
        for url in roots { paths[Self.objectID(for: url)] = url }
        systemUpdateID &+= 1
        lock.unlock()
    }

    static func objectID(for url: URL) -> String {
        let digest = SHA256.hash(data: Data(url.standardizedFileURL.path.utf8))
        return digest.prefix(10).map { String(format: "%02x", $0) }.joined()
    }

    /// Only paths that are a shared root, or inside a shared folder, are ever served.
    private func isAllowed(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        return roots.contains { root in
            let rootPath = root.resolvingSymlinksInPath().path
            return path == rootPath || path.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/")
        }
    }

    func url(forID id: String) -> URL? {
        lock.lock(); defer { lock.unlock() }
        guard let url = paths[id], isAllowed(url) else { return nil }
        return url
    }

    func object(forID id: String) -> MediaObject? {
        if id == Self.rootID {
            return MediaObject(id: id, parentID: "-1", title: "Root", kind: .root, url: nil, size: 0)
        }
        guard let url = url(forID: id) else { return nil }
        return makeObject(url)
    }

    func children(ofID id: String) -> [MediaObject]? {
        if id == Self.rootID {
            lock.lock(); let current = roots; lock.unlock()
            return current.compactMap(makeObject)
        }
        guard let url = url(forID: id), isDirectory(url) else { return nil }
        let keys: [URLResourceKey] = [.isDirectoryKey, .isHiddenKey]
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        let folders = entries.filter(isDirectory)
            .filter { !$0.pathExtension.lowercased().hasSuffix("bundle") && $0.pathExtension.lowercased() != "app" }
        let videos = entries.filter { !isDirectory($0) && Media.isVideo($0) }
        let sort: (URL, URL) -> Bool = {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }
        return (folders.sorted(by: sort) + videos.sorted(by: sort)).compactMap(makeObject)
    }

    private func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
    }

    private func makeObject(_ url: URL) -> MediaObject? {
        let url = url.standardizedFileURL
        let id = Self.objectID(for: url)
        lock.lock()
        paths[id] = url
        let isRoot = roots.contains(url)
        lock.unlock()
        let parent = isRoot ? Self.rootID : Self.objectID(for: url.deletingLastPathComponent())
        if isDirectory(url) {
            return MediaObject(id: id, parentID: parent, title: url.lastPathComponent, kind: .folder, url: url, size: 0)
        }
        guard Media.isVideo(url) else { return nil }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        return MediaObject(id: id, parentID: parent, title: url.deletingPathExtension().lastPathComponent,
                           kind: .video, url: url, size: size)
    }
}
