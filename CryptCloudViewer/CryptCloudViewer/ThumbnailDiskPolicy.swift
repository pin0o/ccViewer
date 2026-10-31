import Foundation
import CryptoKit
import RemoteCloud

/// Directory versions are durable; old queued cleanup cannot delete new writes.
final class ThumbnailDiskPolicy {
    let gate = ThumbnailDiskGate()
    let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Thumbnails-v1", isDirectory: true)
    private var root = UserDefaults.standard.string(forKey: "thumbnail.disk.root") ?? UUID().uuidString
    private var groups = UserDefaults.standard.dictionary(forKey: "thumbnail.disk.groups") as? [String: String] ?? [:]
    private var storages = UserDefaults.standard.dictionary(forKey: "thumbnail.disk.storages") as? [String: String] ?? [:]
    private var suspended = false

    init() { save() }
    private func save() {
        for group in ["standard", "encrypted"] where groups[group] == nil { groups[group] = UUID().uuidString }
        UserDefaults.standard.set(root, forKey: "thumbnail.disk.root")
        UserDefaults.standard.set(groups, forKey: "thumbnail.disk.groups")
        UserDefaults.standard.set(storages, forKey: "thumbnail.disk.storages")
        UserDefaults.standard.synchronize()
        updateGate()
    }
    func updateGate() {
        let settings = ThumbnailSettings.shared
        let enabled = Set([settings.standardCache ? "standard" : nil, settings.encryptedCache ? "encrypted" : nil].compactMap { $0 })
        gate.update(root: root, groups: groups, storages: storages, enabled: suspended ? [] : enabled)
    }
    func setSuspended(_ value: Bool) { suspended = value; updateGate() }
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private func storageID(_ name: String) -> String { Self.digest(Data(name.utf8)) }

    func key(item: RemoteDataDTO, namespace: String, group: ThumbnailGroup, pixels: Int) -> ThumbnailDiskKey? {
        let storage = storageID(item.storage ?? "")
        if storages[storage] == nil { storages[storage] = UUID().uuidString; save() }
        let identity = ["schema": "1", "namespace": namespace, "id": item.id ?? "", "size": String(item.size),
            "modified": item.mdate.map { String($0.timeIntervalSince1970.bitPattern) } ?? "unknown",
            "created": item.cdate.map { String($0.timeIntervalSince1970.bitPattern) } ?? "unknown",
            "hash": item.hashstr ?? "", "extension": item.ext ?? "", "subid": item.subid ?? "",
            "substart": String(item.substart), "subend": String(item.subend),
            "baseStorage": item.baseStorage ?? "", "baseId": item.baseId ?? ""]
        guard let data = try? JSONSerialization.data(withJSONObject: identity, options: .sortedKeys),
              let groupVersion = groups[group.rawValue], let storageVersion = storages[storage] else { return nil }
        return ThumbnailDiskKey(root: root, group: group.rawValue, groupVersion: groupVersion,
            storage: storage, storageVersion: storageVersion, identifier: Self.digest(data), pixels: pixels)
    }

    func rotate(storage: String? = nil, group: ThumbnailGroup? = nil) -> [[String]] {
        let paths: [[String]]
        if let storage {
            let id = storageID(storage)
            paths = groups.map { [root, "\($0.key)-\($0.value)", "\(id)-\(storages[id] ?? "unused")"] }
            storages[id] = UUID().uuidString
        } else if let group {
            paths = [[root, "\(group.rawValue)-\(groups[group.rawValue] ?? "unused")"]]
            groups[group.rawValue] = UUID().uuidString
        } else {
            paths = [[root]]
            root = UUID().uuidString
        }
        save()
        return paths
    }
}
