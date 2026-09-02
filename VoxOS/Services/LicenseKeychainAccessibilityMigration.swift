import Foundation

enum LicenseKeychainKeys {
    static let licenseKey = "voxos.license.key"
    static let trialStartDate = "voxos.license.trialStartDate"
    static let activationId = "voxos.license.activationId"
}

struct LicenseKeychainAccessibilityMigration {
    private let keychain: KeychainService
    private let defaults: UserDefaults
    private let migrationKey = "VoxOSLicenseAccessibilityMigrationV1"
    private let accessibility = KeychainService.Accessibility.afterFirstUnlockThisDeviceOnly

    init(
        keychain: KeychainService = .shared,
        defaults: UserDefaults = .standard
    ) {
        self.keychain = keychain
        self.defaults = defaults
    }

    func runIfNeeded(for state: StoredLicenseState) -> Bool {
        guard !defaults.bool(forKey: migrationKey) else { return true }

        var succeeded = true

        if let licenseKey = state.licenseKey {
            succeeded = migrateAccessibility(
                licenseKey, forKey: LicenseKeychainKeys.licenseKey
            ) && succeeded
        }

        if let activationId = state.activationId {
            succeeded = migrateAccessibility(
                activationId, forKey: LicenseKeychainKeys.activationId
            ) && succeeded
        }

        if let trialStartDate = state.trialStartDate {
            succeeded = migrateAccessibility(
                String(trialStartDate.timeIntervalSince1970), forKey: LicenseKeychainKeys.trialStartDate
            ) && succeeded
        }

        guard succeeded else { return false }

        defaults.set(true, forKey: migrationKey)
        return true
    }

    // SecItemUpdate cannot change an existing item's kSecAttrAccessible — it either fails
    // or silently leaves the original accessibility class in place. Deleting and re-adding
    // is the only reliable way to move an item to a new accessibility class.
    private func migrateAccessibility(_ value: String, forKey key: String) -> Bool {
        keychain.delete(forKey: key, syncable: false)
        return keychain.save(
            value,
            forKey: key,
            syncable: false,
            accessibility: accessibility
        )
    }
}
