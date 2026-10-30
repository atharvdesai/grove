import AppKit
import GroveKit
import SwiftUI

/// Where a check's switch lives in System Settings.
///
/// Needed because macOS will not let an app re-ask once a permission has been
/// denied — the only route back is the Privacy pane, and making the user find it
/// themselves is how a permission stays broken.
enum PrivacyPane {
    static func url(for checkID: String) -> URL? {
        let anchor: String?
        switch checkID {
        case "microphone": anchor = "Privacy_Microphone"
        // System-audio capture is listed under Screen & System Audio Recording.
        case "systemAudio": anchor = "Privacy_ScreenCapture"
        // Apple Intelligence is not under Privacy at all, and its pane
        // identifier has moved between releases; opening System Settings and
        // saying where to look beats a link that lands nowhere.
        default: anchor = nil
        }

        if let anchor {
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")
        }
        return URL(string: "x-apple.systempreferences:")
    }

    static func open(for checkID: String) {
        guard let url = url(for: checkID) else { return }
        NSWorkspace.shared.open(url)
    }
}

/// Requests whatever a check needs, if macOS still allows asking.
@MainActor
enum PermissionRequest {
    static func perform(for check: SystemCheck) async {
        switch check.id {
        case "microphone":
            _ = await MicrophoneCapture.requestAccess()
        case "systemAudio":
            // Building the tap is the request; there is no other API.
            _ = Diagnostics.systemAudio()
        default:
            break
        }
    }
}

/// The permissions list, shared by Settings and onboarding so the two cannot
/// describe the same state differently.
struct PermissionsList: View {
    let checks: [SystemCheck]
    let refresh: () async -> Void

    @ViewState private var working: String?

    var body: some View {
        VStack(spacing: 10) {
            ForEach(checks) { check in
                PermissionRow(check: check, working: working == check.id) {
                    working = check.id
                    await PermissionRequest.perform(for: check)
                    await refresh()
                    working = nil
                }
            }
        }
    }
}

struct PermissionRow: View {
    let check: SystemCheck
    var working: Bool = false
    let request: () async -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: check.isReady ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(check.isReady ? Color.green : .orange)
                .font(.title3)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(check.name).font(.callout.weight(.medium))
                    Text(check.detail).font(.caption).foregroundStyle(.tertiary)
                }
                if let why {
                    Text(why)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 8)

            if !check.isReady {
                HStack(spacing: 8) {
                    if check.canRequest {
                        Button {
                            Task { await request() }
                        } label: {
                            if working {
                                ProgressView().controlSize(.small)
                            } else {
                                Text("Grant")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(working)
                    }
                    Button("System Settings") { PrivacyPane.open(for: check.id) }
                        .controlSize(.small)
                }
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))
    }

    private var why: String? {
        switch check.state {
        case .ready: return nil
        case .actionNeeded(let text), .unavailable(let text): return text
        }
    }
}
