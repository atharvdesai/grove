import Foundation
import Observation
import GroveKit
import SwiftUI

/// User preferences, backed by `UserDefaults`.
///
/// Deliberately not `@AppStorage`: that only works inside a `View`, and both
/// `MeetingSession` and `MeetingLibrary` need the storage location too. One
/// observable object keeps a single answer to "where do meetings live", rather
/// than three views each resolving it slightly differently.
@MainActor
@Observable
final class AppSettings {
    enum Appearance: String, CaseIterable, Identifiable, Sendable {
        case system, light, dark
        var id: String { rawValue }

        var label: String {
            switch self {
            case .system: return "System"
            case .light: return "Light"
            case .dark: return "Dark"
            }
        }

        var colorScheme: ColorScheme? {
            switch self {
            case .system: return nil
            case .light: return .light
            case .dark: return .dark
            }
        }
    }

    private enum Key {
        static let appearance = "appearance"
        static let defaultTemplate = "defaultTemplateID"
        static let storagePath = "storagePath"
        static let showTranscriptWhileRecording = "showTranscriptWhileRecording"
        static let completedOnboarding = "hasCompletedOnboarding"
        static let showRecordingOverlay = "showRecordingOverlay"
    }

    private let defaults: UserDefaults

    var appearance: Appearance {
        didSet { defaults.set(appearance.rawValue, forKey: Key.appearance) }
    }

    var defaultTemplateID: String {
        didSet { defaults.set(defaultTemplateID, forKey: Key.defaultTemplate) }
    }

    var showTranscriptWhileRecording: Bool {
        didSet {
            defaults.set(showTranscriptWhileRecording, forKey: Key.showTranscriptWhileRecording)
        }
    }

    /// Empty means "wherever `MeetingStore` defaults to", so the preference
    /// survives the default itself changing.
    var storagePath: String {
        didSet { defaults.set(storagePath, forKey: Key.storagePath) }
    }

    var hasCompletedOnboarding: Bool {
        didSet { defaults.set(hasCompletedOnboarding, forKey: Key.completedOnboarding) }
    }

    /// The floating pill shown over other apps while recording.
    var showRecordingOverlay: Bool {
        didSet { defaults.set(showRecordingOverlay, forKey: Key.showRecordingOverlay) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.appearance =
            Appearance(rawValue: defaults.string(forKey: Key.appearance) ?? "") ?? .system
        self.defaultTemplateID =
            defaults.string(forKey: Key.defaultTemplate) ?? NoteTemplate.general.id
        self.storagePath = defaults.string(forKey: Key.storagePath) ?? ""
        self.showTranscriptWhileRecording =
            defaults.object(forKey: Key.showTranscriptWhileRecording) as? Bool ?? true
        self.hasCompletedOnboarding = defaults.bool(forKey: Key.completedOnboarding)
        self.showRecordingOverlay =
            defaults.object(forKey: Key.showRecordingOverlay) as? Bool ?? true
    }

    var storageURL: URL {
        storagePath.isEmpty
            ? MeetingStore().baseDirectory
            : URL(fileURLWithPath: (storagePath as NSString).expandingTildeInPath)
    }

    var store: MeetingStore {
        MeetingStore(baseDirectory: storagePath.isEmpty ? nil : storageURL)
    }

    func resetStorageLocation() { storagePath = "" }

    var appVersion: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        return short ?? "dev"
    }
}
