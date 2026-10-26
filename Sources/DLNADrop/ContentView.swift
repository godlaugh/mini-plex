import AppKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @State private var isTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if model.items.isEmpty {
                emptyState
            } else {
                list
            }
            Divider()
            footer
        }
        .overlay {
            if isTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .background(Color.accentColor.opacity(0.08).clipShape(RoundedRectangle(cornerRadius: 12)))
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            model.add(urls.filter(\.isFileURL))
            return true
        } isTargeted: { isTargeted = $0 }
        .animation(.easeOut(duration: 0.15), value: isTargeted)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(model.isSharing ? Color.green : Color.secondary.opacity(0.5))
                .frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.name).font(.headline)
                Text(model.error ?? (model.isSharing ? "电视上打开「媒体播放器 / DLNA」即可看到" : "已暂停共享"))
                    .font(.caption)
                    .foregroundStyle(model.error == nil ? Color.secondary : Color.red)
            }
            Spacer()
            Toggle("", isOn: Binding(get: { model.isSharing }, set: { model.setSharing($0) }))
                .toggleStyle(.switch)
                .labelsHidden()
                .help(model.isSharing ? "暂停共享" : "开始共享")
        }
        .padding(.horizontal, 16)
        .padding(.top, 28)
        .padding(.bottom, 12)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "film.stack")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.secondary)
            Text("把视频或文件夹拖到这里")
                .font(.title3.weight(.medium))
            Text("拖进来就能在电视上播放")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { model.choose() }
    }

    private var list: some View {
        List {
            ForEach(model.items, id: \.self) { url in
                Row(url: url) { model.remove(url) }
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
    }

    private var footer: some View {
        HStack {
            Button { model.choose() } label: { Image(systemName: "plus") }
                .buttonStyle(.borderless)
                .help("添加视频或文件夹")
            Spacer()
            Text(model.items.isEmpty ? "" : "\(model.items.count) 项")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}

private struct Row: View {
    let url: URL
    let onRemove: () -> Void
    @State private var hovering = false

    private var isFolder: Bool { (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false }

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(isFolder ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent)
                    .lineLimit(1)
                Text(url.deletingLastPathComponent().path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button(action: onRemove) { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .opacity(hovering ? 1 : 0)
                .help("移除")
        }
        .padding(.vertical, 3)
        .onHover { hovering = $0 }
        .contextMenu {
            Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            Button("移除", role: .destructive, action: onRemove)
        }
    }
}
