import CoreAudio
import Foundation

/// An app Grove recognises as one that hosts calls.
public struct MeetingApp: Sendable, Equatable, Hashable {
    /// The main app's bundle identifier. Helper processes (`.helper`,
    /// `.WebContent` and the like) are matched by prefix, because that is
    /// usually where the microphone is actually opened — Chrome takes the mic in
    /// "Google Chrome Helper", not in Chrome itself.
    public let bundleID: String
    public let name: String
    /// A browser holding the mic might be Google Meet, or might be a voice-memo
    /// site. Grove asks rather than recording on its own for these.
    public let isBrowser: Bool

    public init(bundleID: String, name: String, isBrowser: Bool = false) {
        self.bundleID = bundleID
        self.name = name
        self.isBrowser = isBrowser
    }

    public static let known: [MeetingApp] = [
        MeetingApp(bundleID: "us.zoom.xos", name: "Zoom"),
        MeetingApp(bundleID: "com.microsoft.teams2", name: "Microsoft Teams"),
        MeetingApp(bundleID: "com.microsoft.teams", name: "Microsoft Teams"),
        MeetingApp(bundleID: "com.cisco.webexmeetingsapp", name: "Webex"),
        MeetingApp(bundleID: "Cisco-Systems.Spark", name: "Webex"),
        MeetingApp(bundleID: "com.apple.FaceTime", name: "FaceTime"),
        MeetingApp(bundleID: "com.tinyspeck.slackmacgap", name: "Slack"),
        MeetingApp(bundleID: "com.hnc.Discord", name: "Discord"),
        MeetingApp(bundleID: "net.whatsapp.WhatsApp", name: "WhatsApp"),
        MeetingApp(bundleID: "com.google.Chrome", name: "Google Chrome", isBrowser: true),
        MeetingApp(bundleID: "com.apple.Safari", name: "Safari", isBrowser: true),
        MeetingApp(bundleID: "com.apple.WebKit", name: "Safari", isBrowser: true),
        MeetingApp(bundleID: "company.thebrowser.Browser", name: "Arc", isBrowser: true),
        MeetingApp(bundleID: "org.mozilla.firefox", name: "Firefox", isBrowser: true),
        MeetingApp(bundleID: "com.microsoft.edgemac", name: "Microsoft Edge", isBrowser: true),
        MeetingApp(bundleID: "com.brave.Browser", name: "Brave", isBrowser: true),
    ]

    /// The known app a process belongs to, if any.
    public static func matching(bundleID: String) -> MeetingApp? {
        known.first { bundleID == $0.bundleID || bundleID.hasPrefix($0.bundleID + ".") }
    }
}

/// Notices when a call starts by watching who holds the microphone.
///
/// Every call app opens the mic for the length of the call — muting usually
/// silences the stream without closing it — so "a known call app is taking
/// microphone input" is a good signal that a meeting is on, and it needs no
/// integration with any of them, no screen recording permission, and nothing
/// beyond Core Audio's own process list.
public enum MeetingDetector {
    /// Call apps taking microphone input right now, Grove excluded.
    ///
    /// Grove's own recording holds the mic too; without excluding it, the
    /// meeting would never appear to end.
    public static func activeMeetingApps() -> [MeetingApp] {
        let ownPID = getpid()
        var found: [MeetingApp] = []
        for process in processObjects() {
            guard isRunningInput(process), pid(of: process) != ownPID,
                let bundleID = bundleID(of: process),
                let app = MeetingApp.matching(bundleID: bundleID),
                !found.contains(where: { $0.name == app.name })
            else { continue }
            found.append(app)
        }
        return found
    }

    /// Bundle IDs of every process taking microphone input, for `grove detect`.
    /// Shows what an unrecognised call app looks like, so it can be added.
    public static func processesUsingMicrophone() -> [String] {
        processObjects()
            .filter(isRunningInput)
            .map { bundleID(of: $0) ?? "pid \(pid(of: $0))" }
    }

    // MARK: - Core Audio

    private static func processObjects() -> [AudioObjectID] {
        var addr = address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr, size > 0
        else { return [] }
        var objects = [AudioObjectID](
            repeating: AudioObjectID(kAudioObjectUnknown),
            count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &objects) == noErr
        else { return [] }
        return objects
    }

    private static func isRunningInput(_ process: AudioObjectID) -> Bool {
        var addr = address(kAudioProcessPropertyIsRunningInput)
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(process, &addr, 0, nil, &size, &running) == noErr
            && running != 0
    }

    private static func pid(of process: AudioObjectID) -> pid_t {
        var addr = address(kAudioProcessPropertyPID)
        var pid: pid_t = -1
        var size = UInt32(MemoryLayout<pid_t>.size)
        _ = AudioObjectGetPropertyData(process, &addr, 0, nil, &size, &pid)
        return pid
    }

    private static func bundleID(of process: AudioObjectID) -> String? {
        var addr = address(kAudioProcessPropertyBundleID)
        var bundleID: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &bundleID) {
            AudioObjectGetPropertyData(process, &addr, 0, nil, &size, $0)
        }
        let value = bundleID as String
        return status == noErr && !value.isEmpty ? value : nil
    }
}
