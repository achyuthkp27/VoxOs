import Foundation
import OSLog

enum OnboardingV2Migration {
    private static let logger = Logger(subsystem: "com.achyuthkp.voxos", category: "OnboardingV2Migration")
    private static let legacyCompletedKey = "hasCompletedOnboarding"
    private static let completedKey = DefaultsKeys.hasCompletedOnboardingV2
    private static let preparedKey = DefaultsKeys.hasPreparedOnboardingV2
    private static let legacyModeConfigurationsKey = "powerModeConfigurationsV2"
    private static let modeConfigurationsKey = "modeConfigurationsV2"
    private static let activeConfigurationIdKey = "activeConfigurationId"
    /// Values this reset removes are copied to `<key>.backupBeforeOnboardingV2` first, so a V1
    /// user's modes and shortcuts can still be recovered after the one-shot wipe.
    static let backupKeySuffix = ".backupBeforeOnboardingV2"

    static func prepareIfNeeded(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: legacyCompletedKey)

        guard !defaults.bool(forKey: completedKey),
            !defaults.bool(forKey: preparedKey)
        else {
            return
        }

        clearModeStorage(defaults: defaults)
        OnboardingStorageKeys.removeAll(from: defaults)
        defaults.set(true, forKey: preparedKey)
    }

    private static func clearModeStorage(defaults: UserDefaults) {
        let modeIds = modeConfigurationIds(forKey: modeConfigurationsKey, defaults: defaults)
            .union(modeConfigurationIds(forKey: legacyModeConfigurationsKey, defaults: defaults))
            .union(StarterModeCatalog.ids)

        var backedUpCount = 0
        for id in modeIds {
            backedUpCount += backUpValue(forKey: ShortcutAction.mode(id).userDefaultsKey, defaults: defaults)
            backedUpCount += backUpValue(forKey: legacyPowerModeShortcutKey(for: id), defaults: defaults)
            ShortcutStore.removeShortcutStorage(for: .mode(id))
            removeLegacyPowerModeShortcutStorage(for: id, defaults: defaults)
        }

        for key in [modeConfigurationsKey, legacyModeConfigurationsKey, activeConfigurationIdKey] {
            backedUpCount += backUpValue(forKey: key, defaults: defaults)
            defaults.removeObject(forKey: key)
        }

        if backedUpCount > 0 {
            logger.notice(
                "Onboarding V2 reset: backed up \(backedUpCount, privacy: .public) mode/shortcut value(s) under *\(backupKeySuffix, privacy: .public) before clearing"
            )
        }
    }

    /// Copies the stored value, if any, to its backup key. Returns 1 when a value was backed up.
    @discardableResult
    static func backUpValue(forKey key: String, defaults: UserDefaults) -> Int {
        guard let value = defaults.object(forKey: key) else { return 0 }
        defaults.set(value, forKey: key + backupKeySuffix)
        return 1
    }

    private static func modeConfigurationIds(forKey key: String, defaults: UserDefaults) -> Set<UUID> {
        guard let data = defaults.data(forKey: key) else {
            return []
        }

        if let configs = try? JSONDecoder().decode([ModeConfig].self, from: data) {
            return Set(configs.map(\.id))
        }

        guard
            let objects = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else {
            return []
        }

        return Set(
            objects.compactMap { object in
                (object["id"] as? String).flatMap(UUID.init(uuidString:))
            })
    }

    private static func legacyPowerModeShortcutKey(for id: UUID) -> String {
        "Shortcut_powerMode_\(id.uuidString)"
    }

    private static func removeLegacyPowerModeShortcutStorage(for id: UUID, defaults: UserDefaults) {
        let key = legacyPowerModeShortcutKey(for: id)
        defaults.removeObject(forKey: key)
        defaults.removeObject(forKey: "\(key)_cleared")
    }
}
