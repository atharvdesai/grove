import Foundation
import FoundationModels

public enum ModelAvailability: Sendable, Equatable {
    case available
    case unavailable(String)
}

/// A local text-generation engine that `NoteEnhancer` drives.
///
/// The seam exists because the engine is the part of Grove most likely to
/// change. Apple's on-device model is the right default — it is already on the
/// machine, so the app works the moment it launches, with nothing to download.
/// It is also small, lossy, and eager to please: it drops stated decisions and
/// will happily write confident notes about a meeting that did not happen.
///
/// A larger local model (Qwen3-4B class, via MLX) is the likely quality tier.
/// Adding one should mean writing a conformance here and nothing else — no
/// changes to prompting, chunking, the refusal floor, or any caller. Crucially
/// it must stay *optional*: multi-gigabyte weights are a real cost to a user who
/// only wanted to take notes, so the zero-download path has to keep working.
///
/// Nothing here may reach the network at inference time. That is the promise the
/// project is built on.
public protocol NoteWritingModel: Sendable {
    /// Whether this engine can run right now, and why not if it cannot.
    var availability: ModelAvailability { get }

    /// Transcript words this engine can take in a single pass.
    ///
    /// Drives chunking. Apple's model has a 4,096-token window covering prompt
    /// *and* completion, which is why long meetings are condensed first; an
    /// engine with a large context can raise this and skip that entirely.
    var singlePassWordLimit: Int { get }

    /// Words per chunk when a transcript exceeds `singlePassWordLimit`.
    var chunkWordLimit: Int { get }

    /// Human-readable engine name, for `grove doctor` and settings.
    var name: String { get }

    func generate(instructions: String, prompt: String) async throws -> String
}

/// Apple's on-device model, via the Foundation Models framework.
///
/// The zero-friction default: built into macOS 26, no download, no setup, no
/// account. `SystemLanguageModel.default` exposes no version identifier, so its
/// behaviour can shift under us with an OS update.
@available(macOS 26.0, *)
public struct FoundationModelsEngine: NoteWritingModel {
    public let name = "Apple on-device model"
    public let singlePassWordLimit = 1_500
    public let chunkWordLimit = 1_200

    public init() {}

    public var availability: ModelAvailability {
        switch SystemLanguageModel.default.availability {
        case .available:
            return .available
        case .unavailable(let reason):
            return .unavailable("\(reason)")
        @unknown default:
            return .unavailable("unknown")
        }
    }

    public func generate(instructions: String, prompt: String) async throws -> String {
        let session = LanguageModelSession(instructions: instructions)
        let response = try await session.respond(to: prompt)
        return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
