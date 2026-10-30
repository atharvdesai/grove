import Foundation
import Observation
import GroveKit
import ServiceManagement
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

    /// What happens when a call app picks up the microphone.
    enum MeetingDetection: String, CaseIterable, Identifiable, Sendable {
        case off, ask, automatic
        var id: String { rawValue }

        var label: String {
            switch self {
            case .off: return "Do nothing"
            case .ask: return "Ask to take notes"
            case .automatic: return "Start recording"
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
        static let meetingDetection = "meetingDetection"
        static let autoOrganize = "autoOrganizeMeetings"
        static let setUpOpenAtLogin = "hasSetUpOpenAtLogin"
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
        didSet {
            defaults.set(hasCompletedOnboarding, forKey: Key.completedOnboarding)
            if hasCompletedOnboarding { setUpOpenAtLoginOnce() }
        }
    }

    /// The floating pill shown over other apps while recording.
    var showRecordingOverlay: Bool {
        didSet { defaults.set(showRecordingOverlay, forKey: Key.showRecordingOverlay) }
    }

    /// Asking is the default because recording a call is not a decision an app
    /// should make on its own: the other people on it may not have agreed.
    var meetingDetection: MeetingDetection {
        didSet { defaults.set(meetingDetection.rawValue, forKey: Key.meetingDetection) }
    }

    /// Name untitled meetings and file them into an existing folder, on-device.
    var autoOrganize: Bool {
        didSet { defaults.set(autoOrganize, forKey: Key.autoOrganize) }
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
        self.meetingDetection =
            MeetingDetection(rawValue: defaults.string(forKey: Key.meetingDetection) ?? "")
            ?? .ask
        self.autoOrganize = defaults.object(forKey: Key.autoOrganize) as? Bool ?? true
        if hasCompletedOnboarding { setUpOpenAtLoginOnce() }
    }

    /// Whether Grove starts, in the menu bar, when you log in.
    ///
    /// Read from the system every time rather than mirrored in UserDefaults:
    /// the user can remove the login item in System Settings, and a stored copy
    /// would go on claiming it was there.
    var openAtLogin: Bool {
        get {
            access(keyPath: \.openAtLogin)
            return SMAppService.mainApp.status == .enabled
        }
        set {
            withMutation(keyPath: \.openAtLogin) {
                try? newValue
                    ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
            }
        }
    }

    /// Call detection only works while Grove is running, so it opens at login
    /// unless told otherwise. Done once: switching it off in Settings sticks.
    private func setUpOpenAtLoginOnce() {
        guard !defaults.bool(forKey: Key.setUpOpenAtLogin) else { return }
        defaults.set(true, forKey: Key.setUpOpenAtLogin)
        openAtLogin = true
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
