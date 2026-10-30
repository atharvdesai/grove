import AppKit
import AuthenticationServices
import GroveKit
import Observation

/// The signed-in Google account: calendar for naming meetings and showing
/// what's next, Gmail for sending notes when a meeting ends.
///
/// Entirely optional. Grove's transcription and writing never go near Google;
/// this is the only part of the app that talks to anyone, and only after the
/// user signs in.
@MainActor
@Observable
final class GoogleConnection {
    private(set) var account: GoogleAccount?
    /// Today's and tomorrow's events, refreshed every few minutes.
    private(set) var events: [CalendarEvent] = []
    private(set) var isSigningIn = false
    var lastError: String?
    /// What happened to the last automatic summary email, for the meeting view.
    private(set) var lastEmail: (meetingID: UUID, result: String)?

    private let settings: AppSettings
    @ObservationIgnored private var tokens: GoogleTokens?
    @ObservationIgnored private var authSession: ASWebAuthenticationSession?
    @ObservationIgnored private var anchor: AuthAnchor?
    @ObservationIgnored private var poller: Task<Void, Never>?
    /// The library, for the Friday digest. Set by the app.
    @ObservationIgnored var meetingsProvider: (@MainActor () -> [Meeting])?

    private static let accountKey = "googleAccount"

    init(settings: AppSettings) {
        self.settings = settings
        tokens = GoogleKeychain.load()
        if tokens != nil, let data = UserDefaults.standard.data(forKey: Self.accountKey) {
            account = try? JSONDecoder().decode(GoogleAccount.self, from: data)
        }
        startPolling()
    }

    /// Whether this build has a Google client ID at all.
    var isConfigured: Bool { GoogleConfig.fromBundle != nil }
    var isSignedIn: Bool { account != nil }

    // MARK: - Sign in

    func signIn() async {
        guard let config = GoogleConfig.fromBundle else {
            lastError = GoogleError.notConfigured.localizedDescription
            return
        }
        isSigningIn = true
        defer { isSigningIn = false }
        lastError = nil

        let verifier = PKCE.verifier()
        let state = UUID().uuidString
        let url = GoogleOAuth.authorizationURL(
            config: config, challenge: PKCE.challenge(for: verifier), state: state)
        do {
            let callback = try await browserSignIn(url: url, scheme: config.callbackScheme)
            let code = try GoogleOAuth.code(from: callback, expectedState: state)
            let tokens = try await GoogleOAuth.exchange(code: code, verifier: verifier, config: config)
            GoogleKeychain.save(tokens)
            self.tokens = tokens
            let account = try await GoogleOAuth.account(accessToken: tokens.accessToken)
            self.account = account
            UserDefaults.standard.set(try? JSONEncoder().encode(account), forKey: Self.accountKey)
            await refreshEvents()
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            // Closing the sign-in sheet is a choice, not an error.
        } catch {
            lastError = error.localizedDescription
        }
    }

    func signOut() {
        GoogleKeychain.delete()
        UserDefaults.standard.removeObject(forKey: Self.accountKey)
        tokens = nil
        account = nil
        events = []
    }

    private func browserSignIn(url: URL, scheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callback: .customScheme(scheme)) {
                callback, error in
                if let callback {
                    continuation.resume(returning: callback)
                } else {
                    continuation.resume(
                        throwing: error ?? GoogleError.server("Sign-in didn't finish."))
                }
            }
            let anchor = AuthAnchor(
                window: NSApp.keyWindow ?? NSApp.windows.first { $0.isVisible } ?? NSWindow())
            session.presentationContextProvider = anchor
            self.anchor = anchor
            authSession = session
            session.start()
        }
    }

    private func accessToken() async throws -> String {
        guard let config = GoogleConfig.fromBundle else { throw GoogleError.notConfigured }
        guard var tokens else { throw GoogleError.notSignedIn }
        if !tokens.isFresh {
            tokens = try await GoogleOAuth.refresh(tokens, config: config)
            GoogleKeychain.save(tokens)
            self.tokens = tokens
        }
        return tokens.accessToken
    }

    // MARK: - Calendar

    /// The event happening now: Google's if signed in, otherwise the Mac's own
    /// calendar when that is turned on.
    func currentEvent(at date: Date = Date()) -> CalendarEvent? {
        if isSignedIn { return CalendarEvents.current(in: events, at: date) }
        return settings.useCalendar ? CalendarEvents.current(at: date) : nil
    }

    /// What's left of today, for the home screen.
    var upcomingToday: [CalendarEvent] {
        let now = Date()
        let endOfDay = Calendar.current.startOfDay(for: now).addingTimeInterval(86_400)
        return events.filter { !$0.isAllDay && $0.end > now && $0.start < endOfDay }
    }

    func refreshEvents() async {
        guard isSignedIn else { return }
        do {
            let start = Calendar.current.startOfDay(for: Date())
            events = try await GoogleCalendar.events(
                from: start, to: start.addingTimeInterval(2 * 86_400),
                accessToken: try await accessToken())
        } catch {
            // A failed refresh keeps the last good list; the next poll retries.
        }
    }

    private func startPolling() {
        poller = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshEvents()
                await self?.sendWeeklyDigestIfDue()
                try? await Task.sleep(for: .seconds(300))
            }
        }
    }

    // MARK: - Gmail

    /// Friday from 4pm, once a week: "This week" to the user's own inbox.
    private func sendWeeklyDigestIfDue() async {
        guard settings.weeklyDigestEmail, let account, let meetings = meetingsProvider?() else { return }
        let calendar = Calendar.current
        let now = Date()
        guard calendar.component(.weekday, from: now) == 6, calendar.component(.hour, from: now) >= 16
        else { return }
        let week = "\(calendar.component(.yearForWeekOfYear, from: now))-\(calendar.component(.weekOfYear, from: now))"
        let key = "lastDigestWeek"
        guard UserDefaults.standard.string(forKey: key) != week else { return }
        let recent = MeetingDigest.meetings(meetings)
        guard !recent.isEmpty else { return }
        // Marked before writing, so a slow or failed run never sends twice.
        UserDefaults.standard.set(week, forKey: key)
        guard let digest = try? await MeetingDigest(model: settings.writingModel).write(for: recent)
        else { return }
        try? await send(SummaryEmail(
            to: [account.email], subject: "Your week in meetings",
            markdown: digest + "\n\n—\nWritten by Grove from this week's notes."))
    }

    func send(_ email: SummaryEmail) async throws {
        try await Gmail.send(email, accessToken: try await accessToken())
    }

    /// Called when a meeting is saved: emails the notes to the user, when
    /// they asked for that, and only when there are written-up notes to send.
    func meetingSaved(_ meeting: Meeting) {
        guard settings.emailSummaries, let account, meeting.enhancedNotes != nil,
            let email = SummaryEmail(meeting: meeting, to: [account.email])
        else { return }
        Task {
            do {
                try await send(email)
                lastEmail = (meeting.id, "Notes emailed to \(account.email)")
            } catch {
                lastEmail = (meeting.id, "Couldn't email the notes: \(error.localizedDescription)")
            }
        }
    }
}

/// Where the Google sign-in sheet attaches. The window is chosen up front, on
/// the main actor, so the callback itself touches no AppKit state.
private final class AuthAnchor: NSObject, ASWebAuthenticationPresentationContextProviding {
    private let window: NSWindow

    init(window: NSWindow) {
        self.window = window
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        window
    }
}
