import Foundation
import FluidAudio

/// What the gate should do with an audio window after looking at its embedding.
enum GateOutcome {
    /// Forward the buffered audio to the inner STT provider.
    /// The label (registered speaker name) is propagated for downstream consumers.
    case allow(speakerId: String, name: String)

    /// Drop the buffered audio. Used for known-but-not-allowed speakers.
    case deny

    /// New speaker — never seen before. The gate should drop the audio AND
    /// persist the embedding to the registry as an Unknown for the user to
    /// review later. Only emitted in capture mode.
    case captureUnknown(embedding: [Float])
}

/// Pluggable verification policy for the gate. Different modes (isolation vs
/// meeting vs capture) implement this differently while sharing the same
/// state machine in VoiceIsolationGate.
protocol SpeakerDecision {
    /// Decide what to do with a verified window's embedding.
    /// Implementations may consult a registry, a clustering manager, etc.
    func decide(embedding: [Float], speechDuration: Float) -> GateOutcome
}

// MARK: - FluidAudio-backed shared lookup

/// Shared SpeakerManager instance constructed from the current registry.
/// All decision implementations route through this so they share thresholds
/// and benefit from FluidAudio's optimized lookup.
final class RegistrySpeakerLookup: @unchecked Sendable {
    private let speakerManager: SpeakerManager
    private let registryById: [String: RegisteredSpeaker]
    private let threshold: Float

    init(registry: [RegisteredSpeaker], threshold: Float) {
        self.threshold = threshold
        self.speakerManager = SpeakerManager(
            speakerThreshold: threshold,
            embeddingThreshold: threshold * 0.7,
            minSpeechDuration: 1.0,
            minEmbeddingUpdateDuration: 2.0
        )

        var byId: [String: RegisteredSpeaker] = [:]
        var fluidSpeakers: [Speaker] = []
        for r in registry {
            byId[r.id] = r
            let s = Speaker(
                id: r.id,
                name: r.name,
                currentEmbedding: r.embedding,
                duration: 1.0,
                isPermanent: true
            )
            fluidSpeakers.append(s)
        }
        if !fluidSpeakers.isEmpty {
            speakerManager.initializeKnownSpeakers(fluidSpeakers)
        }
        self.registryById = byId
    }

    /// Returns the matched registry speaker if any, plus the cosine distance.
    func match(embedding: [Float]) -> (speaker: RegisteredSpeaker?, distance: Float) {
        let (id, distance) = speakerManager.findSpeaker(with: embedding)
        guard let id, let speaker = registryById[id] else {
            return (nil, distance)
        }
        return (speaker, distance)
    }
}

// MARK: - Concrete decisions

/// Isolation mode: only allow registered speakers whose `allowed` flag is true.
/// Unknowns are denied. Used for normal dictation.
struct RegistryAllowlistDecision: SpeakerDecision {
    let lookup: RegistrySpeakerLookup

    func decide(embedding: [Float], speechDuration: Float) -> GateOutcome {
        let (speaker, _) = lookup.match(embedding: embedding)
        guard let speaker else { return .deny }
        return speaker.allowed
            ? .allow(speakerId: speaker.id, name: speaker.name)
            : .deny
    }
}

/// Capture mode: like isolation, but unknown voices are persisted to the
/// registry as `Unknown N` (allowed=false) so the user can review and name
/// them later. Known speakers behave the same as in isolation.
struct RegistryCaptureDecision: SpeakerDecision {
    let lookup: RegistrySpeakerLookup

    func decide(embedding: [Float], speechDuration: Float) -> GateOutcome {
        let (speaker, _) = lookup.match(embedding: embedding)
        if let speaker {
            return speaker.allowed
                ? .allow(speakerId: speaker.id, name: speaker.name)
                : .deny
        }
        return .captureUnknown(embedding: embedding)
    }
}

/// Meeting mode: every registered speaker is forwarded with their label,
/// regardless of the `allowed` flag. Unknowns are still dropped (we don't
/// want strangers walking past your meeting to land in the transcript).
/// Use Capture mode beforehand to enroll the people you want labeled.
struct RegistryLabelDecision: SpeakerDecision {
    let lookup: RegistrySpeakerLookup

    func decide(embedding: [Float], speechDuration: Float) -> GateOutcome {
        let (speaker, _) = lookup.match(embedding: embedding)
        guard let speaker else { return .deny }
        return .allow(speakerId: speaker.id, name: speaker.name)
    }
}
