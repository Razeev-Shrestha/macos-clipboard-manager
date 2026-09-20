import Combine
import Foundation

/// User-editable retention values kept separate from the SQLite repository policy
/// so settings persistence does not depend on the repository actor.
public struct ClipboardRetentionSettings: Codable, Equatable, Sendable {
    public static let `default` = ClipboardRetentionSettings()

    public var maximumUnpinnedItems: Int
    public var maximumUnpinnedAge: TimeInterval

    public init(
        maximumUnpinnedItems: Int = 1_000,
        maximumUnpinnedAge: TimeInterval = 30 * 24 * 60 * 60
    ) {
        self.maximumUnpinnedItems = maximumUnpinnedItems
        self.maximumUnpinnedAge = maximumUnpinnedAge
    }

    public var isValid: Bool {
        maximumUnpinnedItems >= 0
            && maximumUnpinnedAge.isFinite
            && maximumUnpinnedAge >= 0
    }
}

/// A user preference independent of AppKit's native appearance objects.
public enum ClipboardAppearance: String, Codable, CaseIterable, Sendable {
    case system
    case light
    case dark
}

/// Persisted preferences that do not contain clipboard payloads.
public struct ClipboardManagerSettings: Codable, Equatable, Sendable {
    public static let `default` = ClipboardManagerSettings()

    public var retention: ClipboardRetentionSettings
    public var recordingPaused: Bool
    public var excludedBundleIdentifiers: Set<String>
    public var menuBarVisible: Bool
    public var launchAtLogin: Bool
    public var animationsEnabled: Bool
    public var appearance: ClipboardAppearance
    public var globalShortcut: GlobalClipboardShortcutConfiguration

    public init(
        retention: ClipboardRetentionSettings = .default,
        recordingPaused: Bool = false,
        excludedBundleIdentifiers: Set<String> = [],
        menuBarVisible: Bool = true,
        launchAtLogin: Bool = false,
        animationsEnabled: Bool = true,
        appearance: ClipboardAppearance = .system,
        globalShortcut: GlobalClipboardShortcutConfiguration = .default
    ) {
        self.retention = retention
        self.recordingPaused = recordingPaused
        self.excludedBundleIdentifiers = excludedBundleIdentifiers
        self.menuBarVisible = menuBarVisible
        self.launchAtLogin = launchAtLogin
        self.animationsEnabled = animationsEnabled
        self.appearance = appearance
        self.globalShortcut = globalShortcut
    }

    public var isValid: Bool {
        retention.isValid
            && excludedBundleIdentifiers.allSatisfy {
                !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            && globalShortcut.isValid
    }

    public var repositoryRetention: ClipboardHistoryRetention {
        ClipboardHistoryRetention(
            maximumUnpinnedItems: retention.maximumUnpinnedItems,
            maximumUnpinnedAge: retention.maximumUnpinnedAge
        )
    }

    private enum CodingKeys: String, CodingKey {
        case retention
        case recordingPaused
        case excludedBundleIdentifiers
        case menuBarVisible
        case launchAtLogin
        case animationsEnabled
        case appearance
        case globalShortcut
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        retention = try container.decodeIfPresent(ClipboardRetentionSettings.self, forKey: .retention) ?? .default
        recordingPaused = try container.decodeIfPresent(Bool.self, forKey: .recordingPaused) ?? false
        excludedBundleIdentifiers = try container.decodeIfPresent(Set<String>.self, forKey: .excludedBundleIdentifiers) ?? []
        menuBarVisible = try container.decodeIfPresent(Bool.self, forKey: .menuBarVisible) ?? true
        launchAtLogin = try container.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false
        animationsEnabled = try container.decodeIfPresent(Bool.self, forKey: .animationsEnabled) ?? true
        appearance = try container.decodeIfPresent(ClipboardAppearance.self, forKey: .appearance) ?? .system
        globalShortcut = try container.decodeIfPresent(
            GlobalClipboardShortcutConfiguration.self,
            forKey: .globalShortcut
        ) ?? .default
    }
}

public enum ClipboardSettingsError: Error, Equatable, Sendable {
    case invalidStoredSettings
}

/// Main-actor settings persistence with an explicit injected defaults store.
/// The callback is useful for wiring runtime settings without making this type own
/// the monitor, repository, or App UI.
@MainActor
public final class ClipboardSettingsStore: ObservableObject {
    public static let settingsKey = "clipboardManager.settings"

    @Published public private(set) var value: ClipboardManagerSettings
    @Published public private(set) var error: ClipboardSettingsError?
    public var onChange: ((ClipboardManagerSettings) -> Void)?

    private static let exclusionsRecoveryKey = "clipboardManager.settings.excludedBundleIdentifiers"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults) {
        self.defaults = defaults
        let loaded = Self.load(from: defaults)
        value = loaded.value
        error = loaded.error
    }

    public func update(_ newValue: ClipboardManagerSettings) {
        guard newValue.isValid else {
            var pausedValue = value
            pausedValue.recordingPaused = true
            value = pausedValue
            error = .invalidStoredSettings
            persist(pausedValue)
            onChange?(pausedValue)
            return
        }

        value = newValue
        error = nil
        persist(newValue)
        onChange?(newValue)
    }

    public func update(_ change: (inout ClipboardManagerSettings) -> Void) {
        var newValue = value
        change(&newValue)
        update(newValue)
    }

    public func clearError() {
        error = nil
    }

    private func persist(_ settings: ClipboardManagerSettings) {
        let encoder = JSONEncoder()
        if let data = try? encoder.encode(settings) {
            defaults.set(data, forKey: Self.settingsKey)
        }
        defaults.set(
            Array(settings.excludedBundleIdentifiers).sorted(),
            forKey: Self.exclusionsRecoveryKey
        )
    }

    private static func load(from defaults: UserDefaults) -> (
        value: ClipboardManagerSettings,
        error: ClipboardSettingsError?
    ) {
        guard let stored = defaults.object(forKey: settingsKey) else {
            return (.default, nil)
        }

        guard let data = stored as? Data else {
            var recovered = ClipboardManagerSettings.default
            recovered.recordingPaused = true
            recovered.excludedBundleIdentifiers = recoverExclusions(from: nil, defaults: defaults)
            return (recovered, .invalidStoredSettings)
        }

        do {
            let settings = try JSONDecoder().decode(ClipboardManagerSettings.self, from: data)
            guard settings.isValid else {
                throw ClipboardSettingsError.invalidStoredSettings
            }
            return (settings, nil)
        } catch {
            var recovered = ClipboardManagerSettings.default
            recovered.recordingPaused = true
            recovered.excludedBundleIdentifiers = recoverExclusions(from: data, defaults: defaults)
            return (recovered, .invalidStoredSettings)
        }
    }

    private static func recoverExclusions(from data: Data?, defaults: UserDefaults) -> Set<String> {
        if let saved = defaults.array(forKey: exclusionsRecoveryKey) as? [String] {
            return Set(saved.filter(validBundleIdentifier))
        }

        guard let data,
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any],
              let saved = dictionary["excludedBundleIdentifiers"] as? [String]
        else {
            return []
        }
        return Set(saved.filter(validBundleIdentifier))
    }

    private static func validBundleIdentifier(_ identifier: String) -> Bool {
        !identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

}
