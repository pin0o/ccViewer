//
//  RootUIView.swift
//  CryptCloudViewer
//
//  Created by rei9 on 2025/10/19.
//

import SwiftUI
import Combine
internal import UniformTypeIdentifiers

import RemoteCloud
import ffconverter

struct PlayItem: Codable, Identifiable, Transferable {
    var id: String {
        "\(storage)\0\(fileid)\0\(path)"
    }
    var storage: String
    var fileid: String
    var path: String

    init(_ item: RemoteDataDTO) {
        self.storage = item.storage ?? ""
        self.fileid = item.id ?? ""
        self.path = item.path ?? ""
    }

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(for: PlayItem.self, contentType: .data)
    }
}

struct PlaylistUIView: View {
    let playlistName: String
    @Binding var env: UserEnvObject
    @State private var ids: [String] = []
    @State private var items: [String: RemoteDataDTO] = [:]
    private var searchedItems: [String] {
        searchText.isEmpty ? ids : ids.filter { items[$0]?.name?.localizedStandardContains(searchText) ?? false }
    }
    @State private var itemMark: [String: Double] = [:]
    private let presentation = FileBrowserSettings.shared
    @State private var searchText: String = ""
    @State var sortOrder = UserDefaults.standard.integer(forKey: "ItemSortOrder") {
        didSet {
            UserDefaults.standard.set(sortOrder, forKey: "ItemSortOrder")
        }
    }
    @State var isLoading = false
    @State var playlistFolder: [String] = []
    @State var newName = ""
    @State var isNewName = false
    @State var isDelete = false

    @State var downloading = false
    @State var uploading = false
    @State var cancellables = Set<AnyCancellable>()

    @State var isCasting = false
    @State var isLoopPlay = false
    @State var isShufflePlay = false

    let formatString = DateFormatter.dateFormat(fromTemplate: "yyyyMMdd", options: 0, locale: Locale.current)!
    var f: DateFormatter {
        let f = DateFormatter()
        f.dateFormat = formatString + " HH:mm:ss"
        return f
    }
    var formatter: NumberFormatter {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = ","
        formatter.groupingSize = 3
        return formatter
    }
    var formatter2: ByteCountFormatter {
        let formatter2 = ByteCountFormatter()
        formatter2.allowedUnits = [.useAll]
        formatter2.countStyle = .file
        return formatter2
    }

    func reload() async {
        let playitems = await CloudFactory.shared.data.getPlaylist(playlistName: playlistName)
        var newItems: [String: RemoteDataDTO] = [:]
        var newIds: [String] = []
        for (storage, fileid, _, uuid) in playitems {
            if let item = await CloudFactory.shared.data.getData(storage: storage, fileId: fileid) {
                newItems[uuid] = item
                newIds.append(uuid)
            }
            else {
                _ = await CloudFactory.shared.data.list(storage: storage, targetID: fileid, force: true)
                if let item = await CloudFactory.shared.data.getData(storage: storage, fileId: fileid) {
                    newItems[uuid] = item
                    newIds.append(uuid)
                }
            }
        }
        items = newItems
        ids = newIds
        playlistFolder = await CloudFactory.shared.data.getPlaylists()
    }
    
    func rowReplace(_ from: IndexSet, _ to: Int) {
        let visible = searchedItems
        guard !from.isEmpty, to >= 0, to <= visible.count,
              from.allSatisfy({ visible.indices.contains($0) }) else { return }
        var fixFrom: IndexSet = []
        for index in from {
            guard let fullIndex = ids.firstIndex(of: visible[index]) else { return }
            fixFrom.insert(fullIndex)
        }
        let destination = to < visible.count ? ids.firstIndex(of: visible[to]) :
            visible.last.flatMap { ids.firstIndex(of: $0) }.map { $0 + 1 }
        guard let fixTo = destination else { return }
        ids.move(fromOffsets: fixFrom, toOffset: fixTo)
        var playList: [(String, String, String, String)] = []
        for id in ids {
            playList.append((items[id]?.storage ?? "", items[id]?.id ?? "", items[id]?.path ?? "", id))
        }
        Task {
            await CloudFactory.shared.data.setPlaylist(playlistName: playlistName, items: playList)
        }
    }
    
    func rowRemove(from source: IndexSet) {
        var fixSource: IndexSet = []
        for s in source {
            fixSource.insert(ids.firstIndex(of: searchedItems[s])!)
        }
        ids.remove(atOffsets: fixSource)
        var playList: [(String, String, String, String)] = []
        for id in ids {
            playList.append((items[id]?.storage ?? "", items[id]?.id ?? "", items[id]?.path ?? "", id))
        }
        Task {
            await CloudFactory.shared.data.setPlaylist(playlistName: playlistName, items: playList)
        }
    }

    private var listContent: some View {
        List {
            Section {
                ForEach(searchedItems, id: \.self) { id in
                    HStack {
                        if let item = items[id] { FileThumbnailView(item: item) }
                        VStack(alignment: .leading) {
                            Text(verbatim: items[id]?.name ?? "")
                                .font(.headline)
                            if let mdate = items[id]?.mdate {
                                Text(verbatim: "\(f.string(from: mdate))\t\(formatter2.string(fromByteCount: Int64(items[id]!.size))) (\(formatter.string(from: items[id]!.size as NSNumber) ?? "0") bytes) \t\(items[id]?.subinfo ?? "")")
                                    .font(.footnote)
                            }
                            else {
                                Text(verbatim: "\t\(formatter2.string(fromByteCount: Int64(items[id]!.size))) (\(formatter.string(from: items[id]!.size as NSNumber) ?? "0") bytes) \t\(items[id]?.subinfo ?? "")")
                                    .font(.footnote)
                            }
                        }
                    }
                    .draggable(PlayItem(items[id]!)) {
                        Image(systemName: "music.note")
                            .font(.largeTitle)
                    }
                    .onTapGesture {
                        if Converter.IsCasting() {
                            isLoading = true
                            Task {
                                defer {
                                    isLoading = false
                                }
                                await playConverter(storages: [items[id]?.storage ?? ""], fileids: [items[id]?.id ?? ""], playlist: true)
                            }
                        }
                        else {
                            env.path.append(HomePath.open(storages: [items[id]?.storage ?? ""], fileids: [items[id]?.id ?? ""], playlist: true))
                        }
                    }
                }
                .onMove(perform: rowReplace)
                .onDelete(perform: rowRemove)
            }
        }
    }

    private var gridContent: some View {
        FileBrowserGrid(size: presentation.gridSize) {
            ForEach(searchedItems, id: \.self) { id in
                if let item = items[id] {
                    Button { playGridItem(item) } label: {
                        FileGridCell(item: item)
                    }
                    .buttonStyle(.plain)
                    .draggable(PlayItem(item)) {
                        Image(systemName: "music.note").font(.largeTitle)
                    }
                    .contextMenu {
                        if let index = searchedItems.firstIndex(of: id) {
                            Button {
                                moveGridItem(id, direction: -1)
                            } label: {
                                Label("Move earlier", systemImage: "arrow.up")
                            }
                            .disabled(index == 0)
                            Button {
                                moveGridItem(id, direction: 1)
                            } label: {
                                Label("Move later", systemImage: "arrow.down")
                            }
                            .disabled(index + 1 == searchedItems.count)
                            Button(role: .destructive) {
                                if let current = searchedItems.firstIndex(of: id) {
                                    rowRemove(from: IndexSet(integer: current))
                                }
                            } label: {
                                Label("Remove from playlist", systemImage: "trash")
                            }
                        }
                    }
                }
            }
        }
    }

    private func moveGridItem(_ id: String, direction: Int) {
        guard let current = searchedItems.firstIndex(of: id),
              searchedItems.indices.contains(current + direction) else { return }
        rowReplace(IndexSet(integer: current), direction > 0 ? current + 2 : current - 1)
    }

    private func playGridItem(_ item: RemoteDataDTO) {
        if Converter.IsCasting() {
            isLoading = true
            Task {
                defer { isLoading = false }
                await playConverter(storages: [item.storage ?? ""], fileids: [item.id ?? ""], playlist: true)
            }
        } else {
            env.path.append(HomePath.open(storages: [item.storage ?? ""], fileids: [item.id ?? ""], playlist: true))
        }
    }

    var body: some View {
        ZStack {
            VStack(alignment: .leading) {
                HStack {
                    FlowLayout(alignment: .leading) {
                        ForEach(playlistFolder, id: \.self) { item in
                            if item == playlistName {
                                if #available(iOS 26.0, *) {
                                    Button {
                                    } label: {
                                        Text(verbatim: item)
                                    }
                                    .buttonStyle(.glassProminent)
                                    .dropDestination(for: PlayItem.self) { (dropItems, dropSession) in
                                        Task {
                                            var newItems = await CloudFactory.shared.data.getPlaylist(playlistName: item)
                                            for drop in dropItems {
                                                newItems.append((drop.storage, drop.fileid, drop.path, UUID().uuidString))
                                            }
                                            await CloudFactory.shared.data.setPlaylist(playlistName: item, items: newItems)
                                            await reload()
                                        }
                                    }
                                } else {
                                    Button {
                                    } label: {
                                        Text(verbatim: item)
                                    }
                                    .dropDestination(for: PlayItem.self) { dropItems, location in 
                                        Task {
                                            var newItems = await CloudFactory.shared.data.getPlaylist(playlistName: item)
                                            for drop in dropItems {
                                                newItems.append((drop.storage, drop.fileid, drop.path, UUID().uuidString))
                                            }
                                            await CloudFactory.shared.data.setPlaylist(playlistName: item, items: newItems)
                                            await reload()
                                        }
                                        return true
                                    }
                                }
                            }
                            else {
                                if #available(iOS 26.0, *) {
                                    Button {
                                        env.path.append(.playlist(name: item))
                                    } label: {
                                        Text(verbatim: item)
                                    }
                                    .buttonStyle(.glass)
                                    .dropDestination(for: PlayItem.self) { (dropItems, dropSession) in
                                        Task {
                                            var newItems = await CloudFactory.shared.data.getPlaylist(playlistName: item)
                                            for drop in dropItems {
                                                newItems.append((drop.storage, drop.fileid, drop.path, UUID().uuidString))
                                            }
                                            await CloudFactory.shared.data.setPlaylist(playlistName: item, items: newItems)
                                        }
                                    }
                                } else {
                                    Button {
                                        env.path.append(.playlist(name: item))
                                    } label: {
                                        Text(verbatim: item)
                                    }
                                    .dropDestination(for: PlayItem.self) { dropItems, location in
                                        Task {
                                            var newItems = await CloudFactory.shared.data.getPlaylist(playlistName: item)
                                            for drop in dropItems {
                                                newItems.append((drop.storage, drop.fileid, drop.path, UUID().uuidString))
                                            }
                                            await CloudFactory.shared.data.setPlaylist(playlistName: item, items: newItems)
                                        }
                                        return true
                                    }
                                }
                            }
                        }
                    }
                    Spacer()
                    if #available(iOS 26.0, *) {
                        Button(role: .destructive) {
                            isDelete.toggle()
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.glassProminent)
                    } else {
                        Button(role: .destructive) {
                            isDelete.toggle()
                        } label: {
                            Image(systemName: "trash")
                        }
                    }
                }
                .padding()
                Group {
                    if presentation.layout == .grid {
                        gridContent
                    } else {
                        listContent
                    }
                }
                .searchable(text: $searchText)
                .refreshable {
                    ThumbnailService.shared.invalidate()
                    isLoading = true
                    await reload()
                    isLoading = false
                }
            }

            VStack {
                Spacer()
                HStack {
                    if isLoopPlay {
                        if #available(iOS 26.0, *) {
                            Button {
                                isLoopPlay.toggle()
                                UserDefaults.standard.set(isLoopPlay, forKey: "loop")
                            } label: {
                                Image("loop").renderingMode(.template)
                            }
                            .buttonStyle(.glassProminent)
                        } else {
                            Button {
                                isLoopPlay.toggle()
                                UserDefaults.standard.set(isLoopPlay, forKey: "loop")
                            } label: {
                                Image("loop").renderingMode(.template)
                            }
                        }
                    }
                    else {
                        if #available(iOS 26.0, *) {
                            Button {
                                isLoopPlay.toggle()
                                UserDefaults.standard.set(isLoopPlay, forKey: "loop")
                            } label: {
                                Image("loop").renderingMode(.template)
                            }
                            .buttonStyle(.glass)
                        } else {
                            Button {
                                isLoopPlay.toggle()
                                UserDefaults.standard.set(isLoopPlay, forKey: "loop")
                            } label: {
                                Image("loop").renderingMode(.template)
                            }
                        }
                    }
                    if isShufflePlay {
                        if #available(iOS 26.0, *) {
                            Button {
                                isShufflePlay.toggle()
                                UserDefaults.standard.set(isShufflePlay, forKey: "shuffle")
                            } label: {
                                Image("shuffle").renderingMode(.template)
                            }
                            .buttonStyle(.glassProminent)
                        } else {
                            Button {
                                isShufflePlay.toggle()
                                UserDefaults.standard.set(isShufflePlay, forKey: "shuffle")
                            } label: {
                                Image("shuffle").renderingMode(.template)
                            }
                        }
                    }
                    else {
                        if #available(iOS 26.0, *) {
                            Button {
                                isShufflePlay.toggle()
                                UserDefaults.standard.set(isShufflePlay, forKey: "shuffle")
                            } label: {
                                Image("shuffle").renderingMode(.template)
                            }
                            .buttonStyle(.glass)
                        }
                        else {
                            Button {
                                isShufflePlay.toggle()
                                UserDefaults.standard.set(isShufflePlay, forKey: "shuffle")
                            } label: {
                                Image("shuffle").renderingMode(.template)
                            }
                        }
                    }
                    Spacer()
                    if isCasting {
                        if #available(iOS 26.0, *) {
                            CastButton()
                                .frame(width: 20, height: 20)
                                .buttonStyle(.glass)
                        } else {
                            CastButton()
                                .frame(width: 20, height: 20)
                        }
                        Spacer()
                            .frame(width: 20)
                        if #available(iOS 26.0, *) {
                            Button {
                                Task {
                                    await Converter.Stop()
                                    isCasting = Converter.IsCasting()
                                }
                            } label: {
                                Image("cast_on").renderingMode(.template)
                            }
                            .buttonStyle(.glassProminent)
                        } else {
                            Button {
                                Task {
                                    await Converter.Stop()
                                    isCasting = Converter.IsCasting()
                                }
                            } label: {
                                Image("cast_on").renderingMode(.template)
                            }
                        }
                    }
                    else {
                        if #available(iOS 26.0, *) {
                            Button {
                                Converter.Start()
                                isCasting = Converter.IsCasting()
                            } label: {
                                Image("cast").renderingMode(.template)
                            }
                            .buttonStyle(.glass)
                        } else {
                            Button {
                                Converter.Start()
                                isCasting = Converter.IsCasting()
                            } label: {
                                Image("cast").renderingMode(.template)
                            }
                        }
                    }
                    if #available(iOS 26.0, *) {
                        Button {
                            var storages: [String] = []
                            var fileids: [String] = []
                            for id in searchedItems {
                                if !items[id]!.folder {
                                    storages.append(items[id]?.storage ?? "")
                                    fileids.append(items[id]?.id ?? "")
                                }
                            }
                            if storages.isEmpty { return }
                            if Converter.IsCasting() {
                                if isLoading { return }
                                isLoading = true
                                Task {
                                    defer {
                                        isLoading = false
                                    }
                                    await playConverter(storages: storages, fileids: fileids, playlist: true)
                                }
                            }
                            else {
                                env.path.append(.open(storages: storages, fileids: fileids, playlist: true))
                            }
                        } label: {
                            Image("playall").renderingMode(.template)
                        }
                        .buttonStyle(.glass)
                    }
                    else {
                        Button {
                            var storages: [String] = []
                            var fileids: [String] = []
                            for id in searchedItems {
                                if !items[id]!.folder {
                                    storages.append(items[id]?.storage ?? "")
                                    fileids.append(items[id]?.id ?? "")
                                }
                            }
                            if storages.isEmpty { return }
                            if Converter.IsCasting() {
                                if isLoading { return }
                                isLoading = true
                                Task {
                                    defer {
                                        isLoading = false
                                    }
                                    await playConverter(storages: storages, fileids: fileids, playlist: true)
                                }
                            }
                            else {
                                env.path.append(.open(storages: storages, fileids: fileids, playlist: true))
                            }
                        } label: {
                            Image("playall").renderingMode(.template)
                        }
                    }
                }
                .padding()
            }
            
            if isLoading {
                ProgressView()
                    .padding(30)
                    .background {
                        Color(uiColor: .systemBackground)
                            .opacity(0.9)
                    }
                    .scaleEffect(3)
                    .cornerRadius(10)
            }
        }
        .alert("New folder", isPresented: $isNewName) {
            TextField("", text: $newName)
            
            if #available(iOS 26.0, *) {
                Button(role: .confirm) {
                    if newName.isEmpty { return }
                    if playlistFolder.contains(newName) { return }
                    Task {
                        await CloudFactory.shared.data.setPlaylist(playlistName: newName, items: [])
                        await reload()
                    }
                }
                Button(role: .cancel) {
                }
            }
            else {
                Button("OK") {
                    if newName.isEmpty { return }
                    if playlistFolder.contains(newName) { return }
                    Task {
                        await CloudFactory.shared.data.setPlaylist(playlistName: newName, items: [])
                        await reload()
                    }
                }
                Button("Cancel", role: .cancel) {
                }
            }
        }
        .alert("Delete playlist", isPresented: $isDelete) {
            if #available(iOS 26.0, *) {
                Button(role: .destructive) {
                    Task {
                        await CloudFactory.shared.data.deletePlaylist(playlistName: playlistName)
                        env.path.removeLast()
                    }
                }
                Button(role: .cancel) {
                }
            } else {
                Button("Delete", role: .destructive) {
                    Task {
                        await CloudFactory.shared.data.deletePlaylist(playlistName: playlistName)
                        env.path.removeLast()
                    }
                }
                Button("Cancel", role: .cancel) {
                }
            }
        } message: {
            Text("Remove this playlist?")
        }
        .onAppear {
            isCasting = Converter.IsCasting()
            isLoopPlay = UserDefaults.standard.bool(forKey: "loop")
            isShufflePlay = UserDefaults.standard.bool(forKey: "shuffle")
        }
        .onDisappear {
            isCasting = false
        }
        .task {
            DownloadProgressManeger.shared.subject
                .sink { _ in
                    Task {
                        downloading = await DownloadProgressManeger.shared.progressManeger.isPresent()
                    }
                }
                .store(in: &cancellables)
            UploadProgressManeger.shared.subject
                .sink { _ in
                    Task {
                        uploading = await UploadProgressManeger.shared.progressManeger.isPresent()
                    }
                }
                .store(in: &cancellables)

            isLoading = true
            Task {
                defer {
                    isLoading = false
                }
                try? await Task.sleep(for: .milliseconds(300))
                await reload()
            }
        }
        .navigationTitle("")
        .toolbar {
            ToolbarItem { FileBrowserDisplayMenu() }
            ToolbarItem() {
                Button {
                    isNewName.toggle()
                } label: {
                    Image(systemName: "folder.badge.plus")
                }
            }
            ToolbarItem() {
                NavigationLink(value: HomePath.setting) {
                    Image(systemName: "gear")
                }
            }

            ToolbarItem(placement: .cancellationAction) {
                Button {
                    Task {
                        while !env.path.isEmpty {
                            env.path.removeLast()
                            await Task.yield()
                        }
                    }
                } label: {
                    Image(systemName: "house")
                }
            }

            if downloading {
                ToolbarItem(placement: .status) {
                    DownloadProgressUIView()
                }
            }
            if uploading {
                ToolbarItem(placement: .status) {
                    UploadProgressUIView()
                }
            }
        }
    }
}

#Preview {
    @Previewable @State var env = UserEnvObject()
    PlaylistUIView(playlistName: "", env: $env)
}
