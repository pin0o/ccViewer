import SwiftUI
internal import UniformTypeIdentifiers
import RemoteCloud
import ffplayer
import ffconverter

enum FileIconKind: Equatable {
    case folder, image, video, audio, pdf, text, archive, file
    init(_ item: RemoteDataDTO) {
        let fallback = ((item.name ?? "") as NSString).pathExtension
        let ext = (item.ext?.isEmpty == false ? item.ext! : fallback).lowercased()
        let type = UTType(filenameExtension: ext)
        if item.folder { self = .folder }
        else if item.hasSubitems || item.subid != nil { self = .archive }
        else if ext == "ts", type?.conforms(to: .text) == true { self = .text }
        else if type?.conforms(to: .image) == true { self = .image }
        else if ["mkv", "mpeg", "mpg", "m2v", "m2ts", "mts", "ts", "avi", "wmv", "webm", "vob"].contains(ext) ||
                    type?.conforms(to: .movie) == true || type?.conforms(to: .video) == true { self = .video }
        else if type?.conforms(to: .audio) == true { self = .audio }
        else if type?.conforms(to: .pdf) == true { self = .pdf }
        else if type?.conforms(to: .text) == true || OpenfileUIView.codeExtensions.contains(ext) { self = .text }
        else if type?.conforms(to: .archive) == true { self = .archive }
        else { self = .file }
    }
    var symbol: String {
        switch self {
        case .folder: return "folder.fill"
        case .image: return "photo"
        case .video: return "film"
        case .audio: return "music.note"
        case .pdf: return "doc.richtext"
        case .text: return "doc.text"
        case .archive: return "archivebox"
        case .file: return "doc"
        }
    }
    var generatesImage: Bool { self == .image || self == .video }
}

@Observable final class ThumbnailService {
    static let shared = ThumbnailService()
    struct Generation: Hashable { let all: Int; let storage: Int; let group: Int }
    struct Key: Hashable {
        let item: RemoteDataDTO
        let group: ThumbnailGroup
        let pixels: Int
        let generation: Generation
    }
    private struct Cached {
        let image: CGImage
        let expiry: Date
        let cost: Int
        var touched: Date
    }
    private final class Job {
        let id = UUID()
        let key: Key
        var waiters: [UUID: CheckedContinuation<CGImage?, Never>] = [:]
        var task: Task<Void, Never>?
        init(_ key: Key) { self.key = key }
    }
    private var globalGeneration = 0
    private var storageGenerations: [String: Int] = [:]
    private var groupGenerations: [ThumbnailGroup: Int] = [:]
    private var cache: [Key: Cached] = [:]
    private var failures: [Key: Date] = [:]
    private var jobs: [Key: Job] = [:]
    private var pending: [Key] = []
    private var active: [UUID: Job] = [:]
    private var wakeup: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var identifiedText: Set<RemoteDataDTO> = []
    var blocked = false

    private init() {
        observers.append(NotificationCenter.default.addObserver(forName: .thumbnailInvalidated, object: nil, queue: .main) { notification in
            let storage = notification.userInfo?["storage"] as? String
            Task { @MainActor in ThumbnailService.shared.invalidate(storage: storage) }
        })
        observers.append(NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in ThumbnailService.shared.invalidate() }
        })
    }

    func generation(storage: String, group: ThumbnailGroup) -> Generation {
        Generation(all: globalGeneration, storage: storageGenerations[storage, default: 0], group: groupGenerations[group, default: 0])
    }

    func connectionVersion(_ storage: String) -> String {
        "\(globalGeneration):\(storageGenerations[storage, default: 0])"
    }

    func kind(_ item: RemoteDataDTO) -> FileIconKind {
        identifiedText.contains(item) ? .text : FileIconKind(item)
    }

    func settingsChanged(group: ThumbnailGroup, display: Bool) {
        if display, !ThumbnailSettings.shared.display(group) {
            groupGenerations[group, default: 0] += 1
            for job in Array(jobs.values) where job.key.group == group { cancel(job) }
        }
        if !ThumbnailSettings.shared.cache(group) {
            cache = cache.filter { $0.key.group != group }
            failures = failures.filter { $0.key.group != group }
        }
    }

    func invalidate(storage: String? = nil) {
        identifiedText = identifiedText.filter { storage != nil && $0.storage != storage }
        if let storage { storageGenerations[storage, default: 0] += 1 }
        else { globalGeneration += 1 }
        cache = cache.filter { storage != nil && $0.key.item.storage != storage }
        failures = failures.filter { storage != nil && $0.key.item.storage != storage }
        for job in Array(jobs.values) where storage == nil || job.key.item.storage == storage { cancel(job) }
    }

    func setLocked(_ locked: Bool) {
        blocked = locked
        if locked { invalidate() }
        else { pump() }
    }

    private func valid(_ key: Key) -> Bool {
        !blocked && ThumbnailSettings.shared.display(key.group) &&
        generation(storage: key.item.storage ?? "", group: key.group) == key.generation
    }

    private func cacheKey(_ key: Key) -> Key {
        // Display toggles cancel old jobs without invalidating reusable cached content.
        Key(item: key.item, group: key.group, pixels: key.pixels,
            generation: Generation(all: key.generation.all, storage: key.generation.storage, group: 0))
    }

    func image(for key: Key) async -> CGImage? {
        guard valid(key), kind(key.item).generatesImage, key.item.size > 0,
              key.item.id != nil, key.item.storage != nil else { return nil }
        if FileIconKind(key.item) == .image, key.item.size > 20 * 1024 * 1024 { return nil }
        if ThumbnailSettings.shared.cache(key.group) {
            let storedKey = cacheKey(key)
            if var entry = cache[storedKey], entry.expiry > Date() {
                entry.touched = Date(); cache[storedKey] = entry
                return entry.image
            }
            cache.removeValue(forKey: storedKey)
            if let until = failures[storedKey], until > Date() { return nil }
            failures.removeValue(forKey: storedKey)
        }
        let consumer = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled, valid(key) else { continuation.resume(returning: nil); return }
                let job: Job
                if let existing = jobs[key] { job = existing }
                else { job = Job(key); jobs[key] = job; pending.append(key) }
                job.waiters[consumer] = continuation
                pump()
            }
        } onCancel: {
            Task { @MainActor in
                guard let job = self.jobs[key] else { return }
                job.waiters.removeValue(forKey: consumer)?.resume(returning: nil)
                if job.waiters.isEmpty { self.cancel(job) }
            }
        }
    }

    private func cancel(_ job: Job) {
        guard jobs[job.key] === job else { return }
        jobs.removeValue(forKey: job.key)
        pending.removeAll { $0 == job.key }
        job.task?.cancel()
        let waiting = Array(job.waiters.values); job.waiters.removeAll()
        waiting.forEach { $0.resume(returning: nil) }
    }

    private func pump() {
        pending.removeAll { jobs[$0] == nil }
        while active.count < 2 {
            let videoBusy = active.values.contains { FileIconKind($0.key.item) == .video }
            let suspendVideo = Converter.IsCasting() || PiPManager.shared.isActive
            guard let index = pending.firstIndex(where: { key in
                FileIconKind(key.item) != .video || (!videoBusy && !suspendVideo)
            }) else {
                if !pending.isEmpty, wakeup == nil {
                    wakeup = Task {
                        try? await Task.sleep(for: .seconds(1))
                        wakeup = nil; pump()
                    }
                }
                return
            }
            let key = pending.remove(at: index)
            guard let job = jobs[key] else { continue }
            active[job.id] = job
            job.task = Task {
                var image: CGImage?
                var retry: TimeInterval = 30
                do {
                    try Task.checkCancellation()
                    guard valid(key), let item = await key.item.getItem() else { throw CancellationError() }
                    image = try await FileThumbnailGenerator.generate(item: item,
                        video: FileIconKind(key.item) == .video, maximumPixels: key.pixels)
                } catch ThumbnailReadError.textFile {
                    if !Task.isCancelled, valid(key) { identifiedText.insert(key.item) }
                    retry = 300
                }
                catch ThumbnailReadError.unsupported { retry = 300 }
                catch ThumbnailReadError.limitExceeded { retry = 300 }
                catch { }
                let cancelled = Task.isCancelled
                active.removeValue(forKey: job.id)
                if jobs[key] === job {
                    jobs.removeValue(forKey: key)
                    let accepted = !cancelled && valid(key)
                    if accepted, ThumbnailSettings.shared.cache(key.group) {
                        if let image { store(image, for: key) }
                        else { failures[cacheKey(key)] = Date().addingTimeInterval(retry) }
                    }
                    let waiters = Array(job.waiters.values); job.waiters.removeAll()
                    waiters.forEach { $0.resume(returning: accepted ? image : nil) }
                }
                pump()
            }
        }
    }

    private func store(_ image: CGImage, for key: Key) {
        let now = Date()
        cache = cache.filter { $0.value.expiry > now }
        failures = failures.filter { $0.value > now }
        let cost = image.bytesPerRow * image.height
        let ttl: TimeInterval = key.item.mdate == nil ? 60 : 600
        cache[cacheKey(key)] = Cached(image: image, expiry: now.addingTimeInterval(ttl), cost: cost, touched: now)
        var total = cache.values.reduce(0) { $0 + $1.cost }
        for (oldKey, entry) in cache.sorted(by: { $0.value.touched < $1.value.touched }) {
            if total <= 20 * 1024 * 1024 { break }
            cache.removeValue(forKey: oldKey); total -= entry.cost
        }
    }
}
