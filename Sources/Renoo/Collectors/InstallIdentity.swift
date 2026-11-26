import Foundation

/// The stable identity of this install.
///
/// The install ID and first-install date live in the Keychain, which survives an app reinstall,
/// and are mirrored into the SDK's UserDefaults, which does not. So:
/// - Keychain empty, UserDefaults empty → fresh install: new ID.
/// - Keychain has a record, UserDefaults empty → reinstall: reuse the ID, `isReinstall = true`.
/// - UserDefaults has an ID → a later launch of the same install: UserDefaults wins.
///
/// If the Keychain can't be used (error -34018 in test bundles without a host app, or the device
/// is locked since boot) the identity falls back to UserDefaults only and logs; it never crashes.
///
/// Resolved once, lazily, under a lock: the first access may be slow (Keychain), later ones are
/// cached. Safe from any thread.
final class InstallIdentity: @unchecked Sendable {
    enum Keys {
        static let installId = "install_id"
        static let firstInstallDate = "first_install_date"
        static let isReinstall = "is_reinstall"
        static let idSource = "install_id_source"
        static let currentInstallDate = "current_install_date"
    }

    /// `install.id_source`: where the install ID came from.
    enum IdSource: String {
        /// Saved in the Keychain: survives a reinstall.
        case keychain
        /// The Keychain couldn't be read: a random ID kept in UserDefaults only.
        case random
    }

    /// What is stored in the Keychain item.
    struct Record: Codable, Equatable {
        let installId: String
        let firstInstallDate: Date
    }

    private struct Resolved {
        let installId: String
        let firstInstallDate: Date
        let isReinstall: Bool
        let idSource: IdSource
        let currentInstallDate: Date
    }

    private let defaults: UserDefaults
    private let logger: SDKLogger
    private let keychain: KeychainStore
    private let now: () -> Date
    private let lock = NSLock()
    private var resolved: Resolved?

    convenience init(defaults: UserDefaults, logger: SDKLogger) {
        self.init(defaults: defaults, logger: logger, keychain: SystemKeychain())
    }

    init(defaults: UserDefaults, logger: SDKLogger, keychain: KeychainStore, now: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.logger = logger
        self.keychain = keychain
        self.now = now
    }

    /// Stable per device and app; survives reinstall when the Keychain is available.
    var installId: String { resolve().installId }

    /// When the app was first installed on this device, across reinstalls.
    var firstInstallDate: Date { resolve().firstInstallDate }

    /// True when this install follows an earlier one on the same device. Stays true for the
    /// whole life of this install.
    var isReinstall: Bool { resolve().isReinstall }

    /// `keychain`, or `random` when the Keychain couldn't be read when this install started.
    var idSource: IdSource { resolve().idSource }

    /// When this install (not the first one on the device) started. UserDefaults only, so a
    /// reinstall resets it. `days_since_install` counts from here.
    var currentInstallDate: Date { resolve().currentInstallDate }

    // MARK: Private

    private func resolve() -> Resolved {
        lock.lock()
        defer { lock.unlock() }
        if let resolved { return resolved }
        let value = load()
        resolved = value
        return value
    }

    private func load() -> Resolved {
        let keychainRecord: Result<Record?, Error> = Result { try readKeychain() }

        // A later launch of the same install: UserDefaults is the source of truth.
        if let storedId = defaults.string(forKey: Keys.installId) {
            var date = defaults.object(forKey: Keys.firstInstallDate) as? Date
            if date == nil {
                if case .success(let record?) = keychainRecord, record.installId == storedId {
                    date = record.firstInstallDate
                }
                defaults.set(date ?? now(), forKey: Keys.firstInstallDate)
            }
            let firstInstallDate = date ?? now()
            // The Keychain was unavailable when this install started, or its item was removed: repair it.
            if case .success(nil) = keychainRecord {
                writeKeychain(Record(installId: storedId, firstInstallDate: firstInstallDate))
            }
            let idSource = defaults.string(forKey: Keys.idSource).flatMap(IdSource.init(rawValue:)) ?? {
                // Saved by an SDK version without this key: the ID is in the Keychain unless it can't be read.
                if case .failure = keychainRecord { return .random }
                return .keychain
            }()
            let currentInstallDate = defaults.object(forKey: Keys.currentInstallDate) as? Date ?? {
                let date = defaults.bool(forKey: Keys.isReinstall) ? now() : firstInstallDate
                defaults.set(date, forKey: Keys.currentInstallDate)
                return date
            }()
            return Resolved(
                installId: storedId,
                firstInstallDate: firstInstallDate,
                isReinstall: defaults.bool(forKey: Keys.isReinstall),
                idSource: idSource,
                currentInstallDate: currentInstallDate
            )
        }

        // First launch of this install.
        let resolved: Resolved
        let date = now()
        switch keychainRecord {
        case .success(let record?):
            resolved = Resolved(
                installId: record.installId, firstInstallDate: record.firstInstallDate, isReinstall: true,
                idSource: .keychain, currentInstallDate: date
            )
        case .success(nil):
            let id = Self.newId()
            // If the write fails, the ID lives in UserDefaults only, like a random fallback.
            let saved = writeKeychain(Record(installId: id, firstInstallDate: date))
            resolved = Resolved(
                installId: id, firstInstallDate: date, isReinstall: false,
                idSource: saved ? .keychain : .random, currentInstallDate: date
            )
        case .failure(let error):
            logger.error("Keychain unavailable (\(error)); the install ID is kept in UserDefaults and won't survive a reinstall.")
            resolved = Resolved(
                installId: Self.newId(), firstInstallDate: date, isReinstall: false,
                idSource: .random, currentInstallDate: date
            )
        }
        defaults.set(resolved.installId, forKey: Keys.installId)
        defaults.set(resolved.firstInstallDate, forKey: Keys.firstInstallDate)
        defaults.set(resolved.isReinstall, forKey: Keys.isReinstall)
        defaults.set(resolved.idSource.rawValue, forKey: Keys.idSource)
        defaults.set(resolved.currentInstallDate, forKey: Keys.currentInstallDate)
        logger.info("install \(resolved.installId) (reinstall: \(resolved.isReinstall))")
        return resolved
    }

    /// The Keychain record, or `nil` when there is none (or it is unreadable garbage).
    private func readKeychain() throws -> Record? {
        guard let data = try keychain.read() else { return nil }
        guard let record = try? JSONDecoder().decode(Record.self, from: data), !record.installId.isEmpty else {
            logger.error("Keychain install record is corrupt; replacing it.")
            return nil
        }
        return record
    }

    @discardableResult
    private func writeKeychain(_ record: Record) -> Bool {
        do {
            try keychain.write(JSONEncoder().encode(record))
            return true
        } catch {
            logger.error("Could not save the install ID to the Keychain (\(error)); it won't survive a reinstall.")
            return false
        }
    }

    private static func newId() -> String { UUID().uuidString.lowercased() }
}
