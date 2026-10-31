import SwiftUI
import RemoteCloud

enum FileBrowserLayout: String, CaseIterable, Identifiable {
    case list, grid
    var id: Self { self }
}

enum FileGridSize: String, CaseIterable, Identifiable {
    case small, medium, large
    var id: Self { self }
    var minimumWidth: CGFloat {
        switch self {
        case .small: 72
        case .medium: 104
        case .large: 152
        }
    }
    var title: LocalizedStringKey {
        switch self {
        case .small: "Small"
        case .medium: "Medium"
        case .large: "Large"
        }
    }
}

@Observable final class FileBrowserSettings {
    static let shared = FileBrowserSettings()
    var layout: FileBrowserLayout {
        didSet { UserDefaults.standard.set(layout.rawValue, forKey: "browser.layout") }
    }
    var gridSize: FileGridSize {
        didSet { UserDefaults.standard.set(gridSize.rawValue, forKey: "browser.gridSize") }
    }

    private init() {
        layout = FileBrowserLayout(rawValue: UserDefaults.standard.string(forKey: "browser.layout") ?? "") ?? .list
        gridSize = FileGridSize(rawValue: UserDefaults.standard.string(forKey: "browser.gridSize") ?? "") ?? .medium
    }

    func reset() {
        layout = .list
        gridSize = .medium
    }
}

struct FileBrowserDisplayMenu: View {
    @Bindable private var settings = FileBrowserSettings.shared

    var body: some View {
        Menu {
            Picker("View mode", selection: $settings.layout) {
                Label("List", systemImage: "list.bullet").tag(FileBrowserLayout.list)
                Label("Grid", systemImage: "square.grid.2x2").tag(FileBrowserLayout.grid)
            }
            if settings.layout == .grid {
                Picker("Grid size", selection: $settings.gridSize) {
                    ForEach(FileGridSize.allCases) { size in
                        Text(size.title).tag(size)
                    }
                }
            }
        } label: {
            Label("View options", systemImage: settings.layout == .list ? "list.bullet" : "square.grid.2x2")
        }
    }
}

struct FileBrowserSettingsSection: View {
    @Bindable private var settings = FileBrowserSettings.shared

    var body: some View {
        Section("File browser") {
            Picker("View mode", selection: $settings.layout) {
                Text("List").tag(FileBrowserLayout.list)
                Text("Grid").tag(FileBrowserLayout.grid)
            }
            Picker("Grid size", selection: $settings.gridSize) {
                ForEach(FileGridSize.allCases) { size in
                    Text(size.title).tag(size)
                }
            }
            .disabled(settings.layout != .grid)
        }
    }
}

struct FileBrowserGrid<Header: View, Cells: View>: View {
    let size: FileGridSize
    let title: String
    private let header: Header
    private let cells: Cells

    init(size: FileGridSize, title: String = "", @ViewBuilder header: () -> Header, @ViewBuilder cells: () -> Cells) {
        self.size = size
        self.title = title
        self.header = header()
        self.cells = cells()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if !title.isEmpty {
                    Text(verbatim: title).font(.footnote).foregroundStyle(.secondary)
                }
                header
                LazyVGrid(columns: [GridItem(.adaptive(minimum: size.minimumWidth), spacing: 12, alignment: .top)],
                          alignment: .leading, spacing: 16) {
                    cells
                }
            }
            .padding(12)
        }
        .scrollBounceBehavior(.always)
    }
}

extension FileBrowserGrid where Header == EmptyView {
    init(size: FileGridSize, title: String = "", @ViewBuilder cells: () -> Cells) {
        self.init(size: size, title: title, header: { EmptyView() }, cells: cells)
    }
}

struct FileGridCell: View {
    let item: RemoteDataDTO
    var selected: Bool? = nil
    var playedProgress: Double? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geometry in
                FileThumbnailView(item: item, side: geometry.size.width)
                    .overlay(alignment: .topTrailing) {
                        if let selected {
                            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                                .font(.title2)
                                .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                                .background(.background, in: Circle())
                                .padding(4)
                        }
                    }
            }
            .aspectRatio(1, contentMode: .fit)
            Text(verbatim: item.name ?? "")
                .font(.subheadline)
                .lineLimit(2, reservesSpace: true)
                .multilineTextAlignment(.leading)
                .foregroundStyle(.primary)
            Group {
                if item.folder {
                    Text("Folder")
                } else {
                    Text(verbatim: ByteCountFormatter.string(fromByteCount: Int64(item.size), countStyle: .file))
                }
            }
            .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            Group {
                if let playedProgress, playedProgress.isFinite {
                    ProgressView(value: min(1, max(0, playedProgress)))
                        .accessibilityLabel(Text("Playback progress"))
                } else {
                    Color.clear.accessibilityHidden(true)
                }
            }
            .frame(height: 4)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected == true ? .isSelected : [])
    }
}
