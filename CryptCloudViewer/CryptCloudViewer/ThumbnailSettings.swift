import SwiftUI
import RemoteCloud

enum ThumbnailGroup: String, Hashable {
    case standard, encrypted

    static func resolve(storage: String) async -> ThumbnailGroup? {
        guard let service = await CloudFactory.shared.storageList.get(storage) else { return nil }
        switch service.getStorageType() {
        case .CryptCarotDAV, .CryptRclone, .Cryptomator, .CryptGocryptfs, .Filen: return .encrypted
        default: return .standard
        }
    }
}

@Observable final class ThumbnailSettings {
    static let shared = ThumbnailSettings()
    var standardDisplay: Bool { didSet { save("thumbnail.standard.displayEnabled", standardDisplay, .standard, display: true) } }
    var standardCache: Bool { didSet { save("thumbnail.standard.cacheEnabled", standardCache, .standard, display: false) } }
    var encryptedDisplay: Bool { didSet { save("thumbnail.encrypted.displayEnabled", encryptedDisplay, .encrypted, display: true) } }
    var encryptedCache: Bool { didSet { save("thumbnail.encrypted.cacheEnabled", encryptedCache, .encrypted, display: false) } }

    private init() {
        standardDisplay = UserDefaults.standard.object(forKey: "thumbnail.standard.displayEnabled") as? Bool ?? true
        standardCache = UserDefaults.standard.object(forKey: "thumbnail.standard.cacheEnabled") as? Bool ?? true
        encryptedDisplay = UserDefaults.standard.object(forKey: "thumbnail.encrypted.displayEnabled") as? Bool ?? true
        encryptedCache = UserDefaults.standard.object(forKey: "thumbnail.encrypted.cacheEnabled") as? Bool ?? false
    }
    func display(_ group: ThumbnailGroup) -> Bool { group == .standard ? standardDisplay : encryptedDisplay }
    func cache(_ group: ThumbnailGroup) -> Bool { group == .standard ? standardCache : encryptedCache }

    private func save(_ key: String, _ value: Bool, _ group: ThumbnailGroup, display: Bool) {
        UserDefaults.standard.set(value, forKey: key)
        ThumbnailService.shared.settingsChanged(group: group, display: display)
    }

    func reset() {
        standardDisplay = true; standardCache = true
        encryptedDisplay = true; encryptedCache = false
    }
}

struct ThumbnailSettingsSection: View {
    let group: ThumbnailGroup
    @Bindable private var settings = ThumbnailSettings.shared

    var body: some View {
        Section {
            if group == .standard {
                Toggle("Show thumbnails", isOn: $settings.standardDisplay)
                Toggle("Enable thumbnail cache", isOn: $settings.standardCache)
            } else {
                Toggle("Show thumbnails", isOn: $settings.encryptedDisplay)
                Toggle("Enable thumbnail cache", isOn: $settings.encryptedCache)
            }
        } header: {
            Text(group == .standard ? LocalizedStringKey("Thumbnails: Standard storage") : LocalizedStringKey("Thumbnails: Encrypted storage"))
        } footer: {
            Text("Thumbnail caching speeds up redisplay. Thumbnails are regenerated after the app exits.")
        }
    }
}
