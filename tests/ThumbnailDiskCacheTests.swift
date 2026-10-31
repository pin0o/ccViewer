import Foundation
import CryptoKit

private actor DecodeProbe {
    private var active = 0
    private(set) var peak = 0
    func enter() { active += 1; peak = max(peak, active) }
    func leave() { active -= 1 }
}

@main
struct ThumbnailDiskCacheTests {
    static var passed = 0
    static func check(_ condition: Bool, _ message: String) {
        precondition(condition, message)
        passed += 1
    }

    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let secret = Data(repeating: 0x73, count: 32)
        let gate = ThumbnailDiskGate()
        func enable(root: String = "root", groups: Set<String> = ["standard", "encrypted"]) {
            gate.update(root: root, groups: ["standard": "v1", "encrypted": "v1"],
                        storages: ["storage": "v1"], enabled: groups)
        }
        func key(_ id: String = "image", pixels: Int = 144, root: String = "root", group: String = "encrypted") -> ThumbnailDiskKey {
            ThumbnailDiskKey(root: root, group: group, groupVersion: "v1", storage: "storage",
                             storageVersion: "v1", identifier: id, pixels: pixels)
        }
        func path(_ key: ThumbnailDiskKey) -> URL {
            key.directory.reduce(directory) { $0.appendingPathComponent($1) }.appendingPathComponent(key.identifier + ".thumb")
        }
        let now = Date()
        let marker = Data("private decrypted thumbnail pixels: never write this in plaintext".utf8)
        func record(pixels: Int = 512, bytes: Data? = nil, expires: Date? = nil) -> ThumbnailDiskRecord {
            ThumbnailDiskRecord(pixels: pixels, expires: expires ?? now.addingTimeInterval(3600), png: bytes ?? marker)
        }
        enable()
        var cache = ThumbnailDiskCache(directory: directory, gate: gate) { _ in secret }
        check(await cache.store(record(), for: key()), "Encrypted storage saves successfully")
        let ciphertext = try Data(contentsOf: path(key()))
        check(ciphertext.range(of: marker) == nil, "Disk contains no plaintext payload")
        let rootRecord = try AES.GCM.open(AES.GCM.SealedBox(combined: ciphertext), using: SymmetricKey(data: secret),
                                        authenticating: key().authentication)
        check(try PropertyListDecoder().decode(ThumbnailDiskRecord.self, from: rootRecord).png == marker,
              "Payload is authenticated AES-GCM, not an obfuscation")

        // No shared actor memory survives: the new instance must recover from disk.
        cache = ThumbnailDiskCache(directory: directory, gate: gate) { _ in secret }
        check(await cache.read(key())?.png == marker, "A new cache instance recovers the thumbnail")
        check(await cache.read(key(pixels: 512))?.pixels == 512, "Large thumbnails satisfy large requests")
        check(await cache.read(key(pixels: 96))?.pixels == 512, "Large thumbnails also satisfy small requests")
        check(await cache.store(record(pixels: 144), for: key()), "A smaller late result is accepted without replacing larger data")
        check(await cache.read(key())?.pixels == 512, "Larger cached image survives a late smaller result")
        check(await cache.read(key("changedmetadata")) == nil, "Changed file identity misses the old thumbnail")
        check(await cache.store(record(pixels: 96), for: key("small", pixels: 96)), "Small thumbnail can be cached")
        check(await cache.read(key("small", pixels: 144)) == nil, "Insufficient resolution requires regeneration")
        check(await cache.read(key("small", pixels: 96)) != nil, "An insufficient resolution read does not discard usable data")
        check(await cache.store(record(), for: key("standard", group: "standard")), "Standard storage can cache too")
        check(try Data(contentsOf: path(key("standard", group: "standard"))).range(of: marker) == nil,
              "Standard thumbnails are encrypted on disk as well")

        enable(groups: ["standard"])
        check(await cache.read(key()) == nil, "Disabled encrypted group cannot read")
        check(await cache.store(record(), for: key("late")) == false, "Disabled group rejects late writes")
        check(await cache.read(key("standard", group: "standard")) != nil, "Disabling one group preserves the other")
        enable()

        let unavailable = ThumbnailDiskCache(directory: directory, gate: gate) { _ in nil }
        check(await unavailable.read(key()) == nil, "Unavailable Keychain causes a safe cache miss")
        check(await unavailable.store(record(), for: key("unavailable")) == false, "Unavailable Keychain never writes plaintext")
        check(await cache.read(key()) != nil, "An unavailable key does not destroy a recoverable encrypted record")

        var tampered = ciphertext
        tampered[tampered.count - 1] ^= 1
        try tampered.write(to: path(key()))
        check(await cache.read(key()) == nil, "Tampering is rejected")
        check(!FileManager.default.fileExists(atPath: path(key()).path), "Tampered entry is discarded")
        check(await cache.store(record(), for: key("expired")), "An unexpired entry can be saved")
        check(await cache.read(key("expired"), now: now.addingTimeInterval(7200)) == nil, "Expired thumbnails are not returned")

        // A purge revokes old queued requests before deletion, and delayed deletion cannot erase new writes.
        enable(root: "nextroot")
        check(await cache.store(record(), for: key("late-after-purge")) == false, "A purge revokes old queued writers")
        check(await cache.read(key("small", pixels: 96)) == nil, "A purge revokes old readers immediately")
        check(await cache.store(record(), for: key("new", root: "nextroot")), "New generation can save")
        await cache.removeDirectory(["root"])
        check(await cache.read(key("new", root: "nextroot")) != nil, "Delayed old-directory deletion preserves new generation")
        check(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("root").path), "Purge deletes old files")
        check(await cache.store(record(), for: key("../escape", root: "nextroot")) == false, "Path traversal is rejected")

        enable()
        let quotaDirectory = directory.appendingPathComponent("quota")
        let quota = ThumbnailDiskCache(directory: quotaDirectory, gate: gate, maximumBytes: 10_000, maximumEntries: 2) { _ in secret }
        for id in 0..<3 {
            check(await quota.store(record(), for: key("q\(id)"), now: now.addingTimeInterval(Double(id))), "Quota test entry saves")
        }
        check(await quota.read(key("q0")) == nil, "Entry limit evicts the least recently used file")
        check(await quota.read(key("q2")) != nil, "Newest entry survives pruning")
        let byteDirectory = directory.appendingPathComponent("bytes")
        let bytes = ThumbnailDiskCache(directory: byteDirectory, gate: gate, maximumBytes: 1400, maximumEntries: 100) { _ in secret }
        for id in 0..<3 {
            _ = await bytes.store(record(bytes: Data(repeating: 0x5a, count: 600)), for: key("b\(id)"), now: now.addingTimeInterval(Double(id)))
        }
        let files = FileManager.default.enumerator(at: byteDirectory, includingPropertiesForKeys: [.fileSizeKey])!
        var total = 0
        for case let url as URL in files where url.pathExtension == "thumb" { total += try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0 }
        check(total <= 1400, "Disk byte quota is enforced")
        check(await bytes.read(key("b2")) != nil, "Byte quota preserves the newest entry")

        let mib: Int64 = 1024 * 1024
        check(ThumbnailWorkPolicy.canStart(activeCount: 3, activeBytes: 3 * mib, videoActive: false, size: mib, video: false, suspendVideo: false), "Four small images can load concurrently")
        check(!ThumbnailWorkPolicy.canStart(activeCount: 4, activeBytes: 4 * mib, videoActive: false, size: mib, video: false, suspendVideo: false), "A fifth image waits")
        check(ThumbnailWorkPolicy.canStart(activeCount: 1, activeBytes: 20 * mib, videoActive: false, size: 20 * mib, video: false, suspendVideo: false), "Two maximum-size images fit the input budget")
        check(!ThumbnailWorkPolicy.canStart(activeCount: 2, activeBytes: 40 * mib, videoActive: false, size: mib, video: false, suspendVideo: false), "Input budget prevents an additional large allocation")
        check(!ThumbnailWorkPolicy.canStart(activeCount: 1, activeBytes: 16 * mib, videoActive: true, size: mib, video: true, suspendVideo: false), "Two video decoders never run together")
        check(!ThumbnailWorkPolicy.canStart(activeCount: 0, activeBytes: 0, videoActive: false, size: mib, video: true, suspendVideo: true), "Playback suspends new thumbnail video work")
        check(ThumbnailWorkPolicy.canStart(activeCount: 0, activeBytes: 0, videoActive: false, size: mib, video: false, suspendVideo: true), "Playback still permits image thumbnails")

        let decoders = ThumbnailDecodeSlots()
        let probe = DecodeProbe()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<12 {
                group.addTask {
                    await decoders.acquire()
                    await probe.enter()
                    for _ in 0..<10 { await Task.yield() }
                    await probe.leave()
                    await decoders.release()
                }
            }
        }
        check(await probe.peak <= 2, "Parallel downloads cannot start more than two ImageIO decoders")

        var window = ThumbnailBlockWindow()
        let block = Int(mib)
        var sizes: [Int64: Int] = [0: block]
        _ = window.retain(slot: 0, sizes: sizes)
        sizes[100] = block
        check(window.retain(slot: 100, sizes: sizes) == [0, 100], "Video header and tail remain available without another download")
        _ = window.retain(slot: 0, sizes: sizes)
        for id in [Int64(1), 2, 3] {
            sizes[id] = block
            let kept = window.retain(slot: id, sizes: sizes)
            sizes = sizes.filter { kept.contains($0.key) }
        }
        check(sizes.values.reduce(0, +) <= 4 * block, "Decrypted block window stays within four MiB")
        check(sizes[100] == nil && sizes[0] != nil, "LRU evicts the older tail before the recently reused header")
        print("Thumbnail cache tests passed: \(passed)")
    }
}
