import SwiftUI
internal import UniformTypeIdentifiers
import RemoteCloud
import ffplayer
import ffconverter
import ImageIO

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
    private let diskPolicy: ThumbnailDiskPolicy
    private let disk: ThumbnailDiskCache
    private var diskMaintenance: Task<Void, Never>?
    var blocked = false

    private init() {
        let policy = ThumbnailDiskPolicy()
        diskPolicy = policy
        let service = PoCAppIdentity.keychainService
        disk = ThumbnailDiskCache(directory: policy.directory, gate: policy.gate) { create in
            ThumbnailDiskKeychain.load(service: service, create: create)
        }
        observers.append(NotificationCenter.default.addObserver(forName: .thumbnailInvalidated, object: nil, queue: .main) { notification in
            let storage = notification.userInfo?["storage"] as? String
            let preserve = notification.userInfo?["preserveDiskCache"] as? Bool ?? false
            Task { @MainActor in ThumbnailService.shared.invalidate(storage: storage, purgeDisk: !preserve) }
        })
        observers.append(NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in ThumbnailService.shared.invalidate(purgeDisk: false) }
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
            if !display { removeDisk(diskPolicy.rotate(group: group)) }
        }
        diskPolicy.updateGate()
    }

    func invalidate(storage: String? = nil, purgeDisk: Bool = true) {
        identifiedText = identifiedText.filter { storage != nil && $0.storage != storage }
        if let storage { storageGenerations[storage, default: 0] += 1 }
        else { globalGeneration += 1 }
        cache = cache.filter { storage != nil && $0.key.item.storage != storage }
        failures = failures.filter { storage != nil && $0.key.item.storage != storage }
        for job in Array(jobs.values) where storage == nil || job.key.item.storage == storage { cancel(job) }
        if purgeDisk { removeDisk(diskPolicy.rotate(storage: storage)) }
    }

    private func removeDisk(_ directories: [[String]]) {
        let previous = diskMaintenance
        diskMaintenance = Task { [disk] in
            await previous?.value
            for directory in directories { await disk.removeDirectory(directory) }
        }
    }

    func purgePersistentCache() async {
        invalidate()
        await diskMaintenance?.value
    }

    func setLocked(_ locked: Bool) {
        blocked = locked
        diskPolicy.setSuspended(locked)
        if locked { invalidate(purgeDisk: false) }
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
            let reusable = cache.keys.filter { $0.item == storedKey.item && $0.group == storedKey.group &&
                $0.generation == storedKey.generation && $0.pixels >= storedKey.pixels && cache[$0]!.expiry > Date() }
                .min { $0.pixels < $1.pixels }
            if let reusable, var entry = cache[reusable] {
                entry.touched = Date(); cache[reusable] = entry
                trace("memory", key)
                return entry.image
            }
            cache.removeValue(forKey: storedKey)
            if let until = failures[storedKey], until > Date() { return nil }
            failures.removeValue(forKey: storedKey)
            if let request = await persistentKey(key), let record = await disk.read(request),
               let image = await Task.detached(priority: .utility, operation: { Self.decodePNG(record.png) }).value,
               !Task.isCancelled, valid(key), ThumbnailSettings.shared.cache(key.group), diskPolicy.gate.allows(request) {
                let stored = Key(item: key.item, group: key.group, pixels: record.pixels, generation: key.generation)
                store(image, for: stored)
                trace("disk", key)
                return image
            }
        }
        guard !Task.isCancelled, valid(key) else { return nil }
        let consumer = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled, valid(key) else { continuation.resume(returning: nil); return }
                let job: Job
                if let existing = jobs.values.filter({ $0.key.item == key.item && $0.key.group == key.group &&
                    $0.key.generation == key.generation && $0.key.pixels >= key.pixels })
                    .min(by: { $0.key.pixels < $1.key.pixels }) { job = existing }
                else { job = Job(key); jobs[key] = job; pending.append(key) }
                job.waiters[consumer] = continuation
                pump()
            }
        } onCancel: {
            Task { @MainActor in
                guard let job = self.jobs.values.first(where: { $0.waiters[consumer] != nil }) else { return }
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
        while active.count < ThumbnailWorkPolicy.maximumJobs {
            let videoBusy = active.values.contains { FileIconKind($0.key.item) == .video }
            let activeBytes = active.values.reduce(Int64(0)) {
                $0 + ThumbnailWorkPolicy.inputCost(size: $1.key.item.size, video: FileIconKind($1.key.item) == .video)
            }
            let suspendVideo = Converter.IsCasting() || PiPManager.shared.isActive
            guard let index = pending.firstIndex(where: { key in
                ThumbnailWorkPolicy.canStart(activeCount: active.count, activeBytes: activeBytes,
                    videoActive: videoBusy, size: key.item.size, video: FileIconKind(key.item) == .video,
                    suspendVideo: suspendVideo)
            }) else {
                if !pending.isEmpty, active.isEmpty, wakeup == nil {
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
                    trace("source", key)
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
                        if let image {
                            store(image, for: key)
                            Task { await persist(image, for: key) }
                        }
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
        let storedKey = cacheKey(key)
        let matching = cache.keys.filter { $0.item == storedKey.item && $0.group == storedKey.group && $0.generation == storedKey.generation }
        if matching.contains(where: { $0.pixels > storedKey.pixels }) { return }
        for old in matching { cache.removeValue(forKey: old) }
        let cost = image.bytesPerRow * image.height
        let ttl: TimeInterval = key.item.mdate == nil ? 60 : 600
        cache[cacheKey(key)] = Cached(image: image, expiry: now.addingTimeInterval(ttl), cost: cost, touched: now)
        var total = cache.values.reduce(0) { $0 + $1.cost }
        for (oldKey, entry) in cache.sorted(by: { $0.value.touched < $1.value.touched }) {
            if total <= 20 * 1024 * 1024 { break }
            cache.removeValue(forKey: oldKey); total -= entry.cost
        }
    }

    private func persistentKey(_ key: Key) async -> ThumbnailDiskKey? {
        guard valid(key), ThumbnailSettings.shared.cache(key.group),
              let storage = key.item.storage,
              let service = await CloudFactory.shared.storageList.get(storage) as? RemoteStorageBase else { return nil }
        return diskPolicy.key(item: key.item, namespace: service.thumbnailNamespace, group: key.group, pixels: key.pixels)
    }

    private func persist(_ image: CGImage, for key: Key) async {
        guard let request = await persistentKey(key),
              let png = await Task.detached(priority: .utility, operation: { Self.encodePNG(image) }).value,
              valid(key), ThumbnailSettings.shared.cache(key.group), diskPolicy.gate.allows(request) else { return }
        let ttl: TimeInterval = key.item.mdate == nil ? 600 : 7 * 24 * 60 * 60
        let record = ThumbnailDiskRecord(pixels: key.pixels, expires: Date().addingTimeInterval(ttl), png: png)
        _ = await disk.store(record, for: request)
    }

    private nonisolated static func encodePNG(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
    private nonisolated static func decodePNG(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              width.intValue > 0, width.intValue <= 512, height.intValue > 0, height.intValue <= 512 else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }
    private func trace(_ source: String, _ key: Key) {
#if DEBUG
        print("Thumbnail cache: \(source) pixels=\(key.pixels)")
#endif
    }
}
