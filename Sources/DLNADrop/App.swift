import AppKit
import SwiftUI

@main
struct DLNADropApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("DLNA Drop", id: "main") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 420, minHeight: 360)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 480, height: 560)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    // Closing the window must not stop sharing; quit with ⌘Q.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { sender.windows.first?.makeKeyAndOrderFront(nil) }
        return true
    }
}

enum AppIcon {
    /// PNG served as the device icon so TVs show something recognizable.
    nonisolated(unsafe) static var png: Data?

    @MainActor static func render() {
        let size = NSSize(width: 256, height: 256)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.systemIndigo.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 56, yRadius: 56).fill()
            let config = NSImage.SymbolConfiguration(pointSize: 130, weight: .semibold)
                .applying(.init(paletteColors: [.white]))
            if let symbol = NSImage(systemSymbolName: "play.tv.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(config) {
                let s = symbol.size
                symbol.draw(in: NSRect(x: (rect.width - s.width) / 2, y: (rect.height - s.height) / 2, width: s.width, height: s.height))
            }
            return true
        }
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return }
        png = rep.representation(using: .png, properties: [:])
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var items: [URL] = []
    @Published private(set) var isSharing = false
    @Published private(set) var error: String?
    let name: String

    private let defaults = UserDefaults.standard
    private var server: MediaServer?
    static let port: UInt16 = 52_100

    init() {
        name = (Host.current().localizedName ?? "Mac") + " 的视频"
        items = (defaults.stringArray(forKey: "sharedPaths") ?? [])
            .map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        Library.shared.setRoots(items)
        AppIcon.render()
        setSharing(true)
    }

    private var uuid: String {
        if let id = defaults.string(forKey: "deviceUUID") { return id }
        let id = UUID().uuidString.lowercased()
        defaults.set(id, forKey: "deviceUUID")
        return id
    }

    func setSharing(_ on: Bool) {
        if on, server == nil {
            let server = MediaServer(uuid: uuid, port: Self.port, friendlyName: name)
            do {
                try server.start()
                self.server = server
                error = nil
            } catch {
                server.stop()
                self.error = "端口 \(Self.port) 或 1900 被占用，无法开始共享"
            }
        } else if !on, let server {
            server.stop()
            self.server = nil
        }
        isSharing = server != nil
    }

    func add(_ urls: [URL]) {
        var changed = false
        for url in urls.map(\.standardizedFileURL) where !items.contains(url) {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
                  isDir.boolValue || Media.isVideo(url) else { continue }
            items.append(url)
            changed = true
        }
        if changed { save() }
    }

    func remove(_ url: URL) {
        items.removeAll { $0 == url }
        save()
    }

    private func save() {
        defaults.set(items.map(\.path), forKey: "sharedPaths")
        Library.shared.setRoots(items)
    }

    func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.folder, .movie, .video, .mpeg4Movie, .quickTimeMovie, .avi, .mpeg2TransportStream]
        panel.allowsOtherFileTypes = true
        if panel.runModal() == .OK { add(panel.urls) }
    }
}
