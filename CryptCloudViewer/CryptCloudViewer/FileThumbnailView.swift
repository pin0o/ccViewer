import SwiftUI
import RemoteCloud

struct FileThumbnailView: View {
    let item: RemoteDataDTO
    @Environment(\.displayScale) private var displayScale
    @State private var group: ThumbnailGroup?
    @State private var image: CGImage?
    @State private var resolvedVersion: String?
    @State private var visible = false
    private let settings = ThumbnailSettings.shared
    private let service = ThumbnailService.shared

    private struct Request: Hashable {
        let key: ThumbnailService.Key?
        let display: Bool
        let blocked: Bool
        let visible: Bool
    }
    private var request: Request {
        guard let group, resolvedVersion == service.connectionVersion(item.storage ?? "") else {
            return Request(key: nil, display: false, blocked: service.blocked, visible: visible)
        }
        return Request(key: ThumbnailService.Key(item: item, group: group,
            pixels: min(512, max(48, Int(48 * displayScale))),
            generation: service.generation(storage: item.storage ?? "", group: group)),
            display: settings.display(group), blocked: service.blocked, visible: visible)
    }

    var body: some View {
        let kind = service.kind(item)
        let current = request
        ZStack(alignment: .bottomTrailing) {
            RoundedRectangle(cornerRadius: 6).fill(.quaternary)
            if current.display, !current.blocked, let image {
                Image(decorative: image, scale: displayScale)
                    .resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 6))
                if kind == .video {
                    Image(systemName: "play.fill").font(.caption2)
                        .padding(3).foregroundStyle(.white).background(.black.opacity(0.65), in: Circle()).padding(2)
                }
            } else {
                Image(systemName: kind.symbol).font(.title2)
                    .foregroundStyle(kind == .folder ? Color.accentColor : .secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 48, height: 48)
        .accessibilityHidden(true)
        .task(id: "\(item.storage ?? ""):\(service.connectionVersion(item.storage ?? ""))") {
            image = nil
            let version = service.connectionVersion(item.storage ?? "")
            let resolved = await ThumbnailGroup.resolve(storage: item.storage ?? "")
            guard !Task.isCancelled else { return }
            group = resolved
            resolvedVersion = version
        }
        .onAppear { visible = true }
        .onDisappear { visible = false; image = nil }
        .task(id: current) {
            image = nil
            guard current.visible, current.display, !current.blocked, kind.generatesImage, let key = current.key else { return }
            let result = await service.image(for: key)
            guard !Task.isCancelled, request == current else { return }
            image = result
        }
    }
}

extension RemoteDataDTO {
    var thumbnailRowID: String { "\(storage ?? "")\u{0}\(id ?? "")\u{0}\(subid ?? "")\u{0}\(substart)\u{0}\(subend)" }
}
