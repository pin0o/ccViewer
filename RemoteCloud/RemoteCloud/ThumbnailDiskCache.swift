import Foundation
import CryptoKit
import Security

public struct ThumbnailDiskKey: Sendable {
    public let root: String
    public let group: String
    public let groupVersion: String
    public let storage: String
    public let storageVersion: String
    public let identifier: String
    public let pixels: Int

    public init(root: String, group: String, groupVersion: String, storage: String,
                storageVersion: String, identifier: String, pixels: Int) {
        self.root = root; self.group = group; self.groupVersion = groupVersion
        self.storage = storage; self.storageVersion = storageVersion
        self.identifier = identifier; self.pixels = pixels
    }

    public var directory: [String] { [root, "\(group)-\(groupVersion)", "\(storage)-\(storageVersion)"] }
    var authentication: Data { Data((directory + [identifier]).joined(separator: "/").utf8) }
}

/// Synchronous revocation prevents queued reads/writes from reviving disabled caches.
public final class ThumbnailDiskGate: @unchecked Sendable {
    private let lock = NSLock()
    private var root = ""
    private var groups: [String: String] = [:]
    private var storages: [String: String] = [:]
    private var enabled: Set<String> = []

    public init() {}
    public func update(root: String, groups: [String: String], storages: [String: String], enabled: Set<String>) {
        lock.lock(); defer { lock.unlock() }
        self.root = root; self.groups = groups; self.storages = storages; self.enabled = enabled
    }
    public func allows(_ key: ThumbnailDiskKey) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return root == key.root && groups[key.group] == key.groupVersion &&
            storages[key.storage] == key.storageVersion && enabled.contains(key.group)
    }
}

public struct ThumbnailDiskRecord: Codable, Sendable {
    public let pixels: Int
    public let expires: Date
    public let png: Data
    public init(pixels: Int, expires: Date, png: Data) {
        self.pixels = pixels; self.expires = expires; self.png = png
    }
}

public enum ThumbnailDiskKeychain {
    /// No plaintext-key fallback: an unavailable Keychain simply disables disk access.
    public static func load(service: String, create: Bool) -> Data? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: "thumbnail.disk.key.v1",
            kSecReturnData as String: true]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data, data.count == 32 { return data }
        guard status == errSecItemNotFound, create else { return nil }
        var data = Data(count: 32)
        guard data.withUnsafeMutableBytes({ SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }) == errSecSuccess else { return nil }
        var add = query
        add.removeValue(forKey: kSecReturnData as String)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let added = SecItemAdd(add as CFDictionary, nil)
        if added == errSecDuplicateItem { return load(service: service, create: false) }
        return added == errSecSuccess ? data : nil
    }
}

/// Payloads in both storage groups are authenticated-encrypted before any file write.
public actor ThumbnailDiskCache {
    private struct Entry { var bytes: Int; var accessed: Date }
    private let directory: URL
    private let gate: ThumbnailDiskGate
    private let keyProvider: @Sendable (Bool) -> Data?
    private let maximumBytes: Int
    private let maximumEntries: Int
    private var index: [URL: Entry]?
    private static let maximumRecordBytes = 2 * 1024 * 1024

    public init(directory: URL, gate: ThumbnailDiskGate, maximumBytes: Int = 256 * 1024 * 1024,
                maximumEntries: Int = 2000, keyProvider: @escaping @Sendable (Bool) -> Data?) {
        self.directory = directory; self.gate = gate; self.keyProvider = keyProvider
        self.maximumBytes = maximumBytes; self.maximumEntries = maximumEntries
    }

    private func url(for key: ThumbnailDiskKey) -> URL? {
        let parts = key.directory + [key.identifier]
        guard parts.allSatisfy({ !$0.isEmpty && $0.count <= 160 &&
            $0.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "-" } }) else { return nil }
        return key.directory.reduce(directory) { $0.appendingPathComponent($1, isDirectory: true) }
            .appendingPathComponent(key.identifier + ".thumb")
    }

    public func read(_ key: ThumbnailDiskKey, now: Date = Date()) -> ThumbnailDiskRecord? {
        guard !Task.isCancelled, gate.allows(key), let url = url(for: key) else { return nil }
        // Protected / temporarily unreadable files remain reusable after unlocking.
        guard let attributes = try? url.resourceValues(forKeys: [.fileSizeKey]),
              let size = attributes.fileSize else { return nil }
        guard size > 0, size <= Self.maximumRecordBytes else { removeFile(url); return nil }
        guard let rawKey = keyProvider(false), let combined = try? Data(contentsOf: url) else { return nil }
        do {
            let box = try AES.GCM.SealedBox(combined: combined)
            let decoded = try AES.GCM.open(box, using: SymmetricKey(data: rawKey), authenticating: key.authentication)
            let record = try PropertyListDecoder().decode(ThumbnailDiskRecord.self, from: decoded)
            guard record.expires > now, record.pixels > 0, record.pixels <= 512,
                  record.png.count <= Self.maximumRecordBytes else { removeFile(url); return nil }
            guard record.pixels >= key.pixels, !Task.isCancelled, gate.allows(key) else { return nil }
            try? FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: url.path)
            if index?[url] != nil { index?[url]?.accessed = now }
            return record
        } catch {
            removeFile(url)
            return nil
        }
    }

    @discardableResult
    public func store(_ record: ThumbnailDiskRecord, for key: ThumbnailDiskKey, now: Date = Date()) -> Bool {
        guard !Task.isCancelled, gate.allows(key), record.pixels >= key.pixels, record.pixels <= 512,
              record.expires > now, record.png.count <= Self.maximumRecordBytes,
              let url = url(for: key), let rawKey = keyProvider(true) else { return false }
        if let current = read(key, now: now), current.pixels >= record.pixels { return true }
        do {
            let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
            let encoded = try encoder.encode(record)
            let sealed = try AES.GCM.seal(encoded, using: SymmetricKey(data: rawKey), authenticating: key.authentication)
            guard let data = sealed.combined, data.count <= Self.maximumRecordBytes,
                  gate.allows(key), !Task.isCancelled else { return false }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            var parent = directory
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            try? parent.setResourceValues(values)
#if os(iOS)
            try data.write(to: url, options: [.atomic, .completeFileProtection])
#else
            try data.write(to: url, options: .atomic)
#endif
            guard gate.allows(key), !Task.isCancelled else { removeFile(url); return false }
            loadIndex()
            index?[url] = Entry(bytes: data.count, accessed: now)
            prune()
            return true
        } catch { return false }
    }

    /// Callers rotate the directory version before scheduling deletion.
    public func removeDirectory(_ components: [String]) {
        guard !components.isEmpty, components.allSatisfy({ !$0.isEmpty && !$0.contains("/") && $0 != ".." }) else { return }
        let url = components.reduce(directory) { $0.appendingPathComponent($1, isDirectory: true) }
        try? FileManager.default.removeItem(at: url)
        index = index?.filter { !$0.key.path.hasPrefix(url.path + "/") }
    }

    private func removeFile(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        index?.removeValue(forKey: url)
    }
    private func loadIndex() {
        guard index == nil else { return }
        index = [:]
        guard let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey], options: .skipsHiddenFiles) else { return }
        for case let url as URL in files where url.pathExtension == "thumb" {
            if let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) {
                index?[url] = Entry(bytes: values.fileSize ?? 0, accessed: values.contentModificationDate ?? .distantPast)
            }
        }
    }
    private func prune() {
        guard let entries = index else { return }
        var total = entries.values.reduce(0) { $0 + $1.bytes }
        guard total > maximumBytes || entries.count > maximumEntries else { return }
        for (url, entry) in entries.sorted(by: { $0.value.accessed < $1.value.accessed }) {
            removeFile(url); total -= entry.bytes
            if total <= maximumBytes * 9 / 10 && (index?.count ?? 0) <= maximumEntries { break }
        }
    }
}

public enum ThumbnailWorkPolicy {
    public static let maximumJobs = 4
    public static let maximumInputBytes: Int64 = 40 * 1024 * 1024
    public static func inputCost(size: Int64, video: Bool) -> Int64 {
        video ? 16 * 1024 * 1024 : min(20 * 1024 * 1024, max(0, size))
    }
    public static func canStart(activeCount: Int, activeBytes: Int64, videoActive: Bool,
                                size: Int64, video: Bool, suspendVideo: Bool) -> Bool {
        activeCount < maximumJobs && activeBytes + inputCost(size: size, video: video) <= maximumInputBytes &&
            (!video || (!videoActive && !suspendVideo))
    }
}

public struct ThumbnailBlockWindow: Sendable {
    private var recent: [Int64] = []
    public init() {}
    public mutating func retain(slot: Int64, sizes: [Int64: Int], maximumBytes: Int = 4 * 1024 * 1024) -> Set<Int64> {
        recent.removeAll { $0 == slot || sizes[$0] == nil }
        recent.append(slot)
        var bytes = recent.reduce(0) { $0 + (sizes[$1] ?? 0) }
        while bytes > maximumBytes, recent.count > 1 {
            bytes -= sizes[recent.removeFirst()] ?? 0
        }
        return Set(recent)
    }
}
