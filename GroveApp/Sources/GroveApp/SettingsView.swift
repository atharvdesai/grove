import AppKit
import GroveKit
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            AccountSettings()
                .tabItem { Label("Account", systemImage: "person.crop.circle") }
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            PermissionsSettings()
                .tabItem { Label("Permissions", systemImage: "lock.shield") }
            NotesSettings()
                .tabItem { Label("Notes", systemImage: "text.alignleft") }
            TemplatesSettings()
                .tabItem { Label("Templates", systemImage: "list.bullet.rectangle") }
            AboutSettings()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 520)
    }
}

private struct AccountSettings: View {
    @Environment(AppSettings.self) private var settings
    @Environment(GoogleConnection.self) private var google

    var body: some View {
        @Bindable var settings = settings

        Form {
            Section {
                if let account = google.account {
                    LabeledContent("Google") {
                        HStack {
                            VStack(alignment: .trailing) {
                                Text(account.name ?? account.email)
                                Text(account.email).font(.caption).foregroundStyle(.secondary)
                            }
                            Button("Sign Out") { google.signOut() }
                        }
                    }
                } else {
                    LabeledContent("Google") {
                        Button(google.isSigningIn ? "Waiting for Google…" : "Sign in with Google") {
                            Task { await google.signIn() }
                        }
                        .disabled(!google.isConfigured || google.isSigningIn)
                    }
                }
                if let error = google.lastError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
                Toggle("Email me the notes when a meeting ends", isOn: $settings.emailSummaries)
                    .disabled(!google.isSignedIn)
                TextField("Your first name", text: $settings.userName)
            } footer: {
                Text(
                    google.isConfigured
                        ? "Grove reads your Google Calendar to name meetings and show what's next, "
                            + "and sends mail only when you ask it to. It can't read your inbox. "
                            + "Transcription and note writing never leave this Mac."
                        : "This build has no Google client ID. See “Google sign-in” in the README.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                Button("Show the Welcome Screens Again") {
                    settings.hasCompletedOnboarding = false
                }
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, 8)
        .frame(width: 520)
    }
}

private struct GeneralSettings: View {
    @Environment(AppSettings.self) private var settings
    @Environment(MeetingLibrary.self) private var library

    var body: some View {
        @Bindable var settings = settings

        Form {
            Picker("Appearance", selection: $settings.appearance) {
                ForEach(AppSettings.Appearance.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)

            Toggle(
                "Show floating controls while recording",
                isOn: $settings.showRecordingOverlay)

            Section {
                Picker("When a call starts", selection: $settings.meetingDetection) {
                    ForEach(AppSettings.MeetingDetection.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Name and file meetings automatically", isOn: $settings.autoOrganize)
                Toggle("Open Grove at login", isOn: $settings.openAtLogin)
                Toggle("Use my calendar to name meetings", isOn: calendarBinding)
            } footer: {
                Text(
                    "Grove notices Zoom, Teams, Meet in your browser, FaceTime, Slack and "
                        + "other call apps when they start using the microphone. Calls in "
                        + "a browser always ask first. Untitled meetings are named, and "
                        + "filed into one of your existing folders, by the on-device model "
                        + "when they end. Grove can only notice calls while it is running, "
                        + "so it opens at login and waits in the menu bar. With the calendar "
                        + "on, meetings take the event's title and list who was invited.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                LabeledContent("Meetings are saved to") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(settings.storageURL.path)
                            .font(.callout)
                            .textSelection(.enabled)
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                        HStack {
                            Button("Choose…") { chooseFolder() }
                            Button("Reveal in Finder") {
                                NSWorkspace.shared.selectFile(
                                    nil, inFileViewerRootedAtPath: settings.storageURL.path)
                            }
                            if !settings.storagePath.isEmpty {
                                Button("Use Default") {
                                    settings.resetStorageLocation()
                                    library.reload()
                                }
                            }
                        }
                    }
                }
            } footer: {
                // Worth saying plainly: this is the whole "no lock-in" claim, and
                // it is the reason moving the folder is safe.
                Text(
                    "Meetings are plain Markdown and JSON, one folder each. "
                        + "Existing meetings are not moved when you change this.")
                // Without fixedSize the footer lays out at its natural width and
                // spills past the section, leaving fragments floating beside it.
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, 8)
        // Every tab is laid out, not just the visible one, so an unconstrained
        // width lets the hidden tabs' text paint fragments over the window.
        .frame(width: 520)
    }

    /// Turning it on asks macOS for calendar access first, and only sticks if
    /// that was granted — a switch that says "on" while nothing can be read
    /// would be the silent failure this app tries hardest to avoid.
    private var calendarBinding: Binding<Bool> {
        Binding(
            get: { settings.useCalendar && CalendarEvents.hasAccess },
            set: { wanted in
                guard wanted else {
                    settings.useCalendar = false
                    return
                }
                Task {
                    let granted = await CalendarEvents.requestAccess()
                    settings.useCalendar = granted
                    if !granted,
                        let url = URL(
                            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")
                    {
                        NSWorkspace.shared.open(url)
                    }
                }
            })
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = settings.storageURL
        panel.prompt = "Use Folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        settings.storagePath = url.path
        library.reload()
    }
}

/// The tab that was missing: the home screen said the microphone was blocked and
/// pointed here, and here had nothing to say about it.
private struct PermissionsSettings: View {
    @ViewState private var checks: [SystemCheck] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(
                "Grove hears a meeting through two separate streams — your microphone "
                    + "and the audio your Mac plays. That separation is what labels who "
                    + "said what."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            PermissionsList(checks: checks) { await load() }

            HStack {
                Button("Re-check") { Task { await load() } }
                    .controlSize(.small)
                Spacer()
                Text("Everything runs on this Mac. Nothing is uploaded.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(20)
        .frame(width: 520)
        .task { await load() }
        // macOS grants take effect while the app is open, so a user who fixes
        // something in System Settings and comes back should see it immediately.
        .onReceive(
            NotificationCenter.default.publisher(
                for: NSApplication.didBecomeActiveNotification)
        ) { _ in
            Task { await load() }
        }
    }

    private func load() async {
        checks = await Diagnostics.all()
    }
}

private struct NotesSettings: View {
    @Environment(AppSettings.self) private var settings
    @Environment(MeetingLibrary.self) private var library

    var body: some View {
        @Bindable var settings = settings

        Form {
            Picker("Default template", selection: $settings.defaultTemplateID) {
                ForEach(library.templates) { Text($0.name).tag($0.id) }
            }

            Toggle("Show the live transcript while recording", isOn: $settings.showTranscriptWhileRecording)

            Section {
                LabeledContent("Writing model") {
                    Text(NoteEnhancer().model.name).foregroundStyle(.secondary)
                }
                LabeledContent("Status") {
                    switch NoteEnhancer.availability {
                    case .available:
                        Label("Ready", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    case .unavailable(let reason):
                        Label(reason, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .lineLimit(2)
                    }
                }
            } footer: {
                Text(
                    "Notes are written on this Mac by Apple's on-device model. "
                        + "It needs Apple Intelligence enabled; without it you still "
                        + "get transcripts.")
                // Without fixedSize the footer lays out at its natural width and
                // spills past the section, leaving fragments floating beside it.
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, 8)
        // Every tab is laid out, not just the visible one, so an unconstrained
        // width lets the hidden tabs' text paint fragments over the window.
        .frame(width: 520)
    }
}

private struct AboutSettings: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        VStack(spacing: 12) {
            if let icon = NSApp.applicationIconImage {
                Image(nsImage: icon).resizable().frame(width: 72, height: 72)
            }
            Text("Grove").font(.title2.weight(.semibold))
            Text("Version \(settings.appVersion)")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("Locally sourced meeting notes.\nNothing leaves your Mac.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Link("github.com/yuvrajadhikari/grove", destination: URL(string: "https://github.com/yuvrajadhikari/grove")!)
                .font(.callout)
            Text("MIT licensed").font(.caption).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(28)
    }
}
