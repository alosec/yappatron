import Foundation

enum AssistantSpeechCapturePhase: String {
    case idle
    case active
    case cooldown
}

struct AssistantSpeechCaptureDecision {
    let sendToSTT: Bool
    let interruptLocalPlayback: Bool
    let retainForLocalBargeIn: Bool
    let phase: AssistantSpeechCapturePhase
    let audioLevel: Double
    let reason: String?

    static func send(
        phase: AssistantSpeechCapturePhase = .idle,
        audioLevel: Double,
        reason: String? = nil,
        interruptLocalPlayback: Bool = false
    ) -> AssistantSpeechCaptureDecision {
        AssistantSpeechCaptureDecision(
            sendToSTT: true,
            interruptLocalPlayback: interruptLocalPlayback,
            retainForLocalBargeIn: false,
            phase: phase,
            audioLevel: audioLevel,
            reason: reason
        )
    }

    static func hold(
        phase: AssistantSpeechCapturePhase,
        audioLevel: Double,
        reason: String,
        retainForLocalBargeIn: Bool = false
    ) -> AssistantSpeechCaptureDecision {
        AssistantSpeechCaptureDecision(
            sendToSTT: false,
            interruptLocalPlayback: false,
            retainForLocalBargeIn: retainForLocalBargeIn,
            phase: phase,
            audioLevel: audioLevel,
            reason: reason
        )
    }
}

private struct AssistantSpeechRemoteState: Decodable {
    let ok: Bool?
    let active: Bool?
    let phase: String?
    let activeUntil: Double?
    let cooldownUntil: Double?
}

actor AssistantSpeechStateClient {
    typealias LocalSpeechProbe = () -> Bool

    private let localSpeechProbe: LocalSpeechProbe
    private var localSpeechIsActive = false
    private var localSpeechCooldownUntil = Date.distantPast
    private var nextLocalSpeechPollAt = Date.distantPast
    private var localBargeInStartedAt: Date?
    private var localBargeInTriggered = false

    private var cachedPhase: AssistantSpeechCapturePhase = .idle
    private var cachedActiveUntil: Date?
    private var cachedCooldownUntil: Date?
    private var cachedValidUntil = Date.distantPast
    private var nextPollAt = Date.distantPast
    private var lastEndpoint: URL?

    private var loudAudioStartedAt: Date?
    private var bargeInOpenUntil = Date.distantPast

    private let localSpeechPollInterval: TimeInterval = 0.10
    private let localSpeechCooldown: TimeInterval = 0.25
    private let localBargeInLevel = 0.12
    private let localBargeInSustain: TimeInterval = 0.12
    private let pollInterval: TimeInterval = 0.15
    private let failureBackoff: TimeInterval = 1.0
    private let activeBargeInLevel = 0.82
    private let cooldownBargeInLevel = 0.68
    private let bargeInSustain: TimeInterval = 0.24
    private let bargeInOpenWindow: TimeInterval = 2.5

    init(localSpeechProbe: @escaping LocalSpeechProbe = LocalAssistantSpeechMonitor.isAssistantSpeechProcessRunning) {
        self.localSpeechProbe = localSpeechProbe
    }

    func captureDecision(
        audioLevel: Double,
        webhookOutputEnabled: Bool,
        webhookOutputURL: String,
        acousticEchoCancellationEnabled: Bool = false,
        now: Date = Date()
    ) async -> AssistantSpeechCaptureDecision {
        let localPhase = localSpeechPhase(now: now)
        if localPhase != .idle {
            resetBargeIn()

            if acousticEchoCancellationEnabled {
                // Voice Processing I/O can leak a brief playback transient while
                // its echo model converges. Keep low-level residual audio away
                // from STT, but monitor it for a sustained near-field voice.
                // Once detected, interrupt SAG and pass the user's speech through.
                if localPhase == .active, !localBargeInTriggered {
                    let shouldInterrupt = shouldInterruptLocalPlayback(audioLevel: audioLevel, now: now)
                    if shouldInterrupt {
                        return .send(
                            phase: localPhase,
                            audioLevel: audioLevel,
                            reason: "voice barge-in during local sag playback",
                            interruptLocalPlayback: true
                        )
                    }
                    return .hold(
                        phase: localPhase,
                        audioLevel: audioLevel,
                        reason: "waiting for echo-cancelled voice barge-in",
                        retainForLocalBargeIn: true
                    )
                }

                return .send(
                    phase: localPhase,
                    audioLevel: audioLevel,
                    reason: "echo-cancelled barge-in continuation"
                )
            }

            resetLocalBargeIn()
            return .hold(
                phase: localPhase,
                audioLevel: audioLevel,
                reason: "local sag playback \(localPhase.rawValue)"
            )
        }

        resetLocalBargeIn()

        guard webhookOutputEnabled, let endpoint = stateURL(from: webhookOutputURL) else {
            resetGate()
            return .send(audioLevel: audioLevel)
        }

        if endpoint != lastEndpoint {
            resetRemoteState()
            lastEndpoint = endpoint
        }

        await refreshIfNeeded(endpoint: endpoint, now: now)

        let phase = effectivePhase(now: now)
        guard phase != .idle else {
            resetBargeIn()
            return .send(phase: phase, audioLevel: audioLevel)
        }

        if shouldAllowBargeIn(audioLevel: audioLevel, phase: phase, now: now) {
            return .send(phase: phase, audioLevel: audioLevel, reason: "barge-in candidate")
        }

        return .hold(phase: phase, audioLevel: audioLevel, reason: "assistant speech \(phase.rawValue)")
    }

    private func localSpeechPhase(now: Date) -> AssistantSpeechCapturePhase {
        if now >= nextLocalSpeechPollAt {
            nextLocalSpeechPollAt = now.addingTimeInterval(localSpeechPollInterval)
            localSpeechIsActive = localSpeechProbe()
            if localSpeechIsActive {
                localSpeechCooldownUntil = now.addingTimeInterval(localSpeechCooldown)
            }
        }

        if localSpeechIsActive {
            return .active
        }
        if now < localSpeechCooldownUntil {
            return .cooldown
        }
        return .idle
    }

    private func shouldInterruptLocalPlayback(audioLevel rawLevel: Double, now: Date) -> Bool {
        guard !localBargeInTriggered else { return false }
        let audioLevel = rawLevel.isFinite ? max(0, rawLevel) : 0

        if audioLevel >= localBargeInLevel {
            if localBargeInStartedAt == nil {
                localBargeInStartedAt = now
            }
            if let startedAt = localBargeInStartedAt,
               now.timeIntervalSince(startedAt) >= localBargeInSustain {
                localBargeInStartedAt = nil
                localBargeInTriggered = true
                return true
            }
        } else if audioLevel < localBargeInLevel * 0.65 {
            localBargeInStartedAt = nil
        }

        return false
    }

    private func resetLocalBargeIn() {
        localBargeInStartedAt = nil
        localBargeInTriggered = false
    }

    private func refreshIfNeeded(endpoint: URL, now: Date) async {
        guard now >= nextPollAt else { return }
        nextPollAt = now.addingTimeInterval(pollInterval)

        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = 0.35
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                nextPollAt = now.addingTimeInterval(failureBackoff)
                return
            }

            let state = try JSONDecoder().decode(AssistantSpeechRemoteState.self, from: data)
            apply(remote: state, now: now)
        } catch {
            nextPollAt = now.addingTimeInterval(failureBackoff)
        }
    }

    private func apply(remote: AssistantSpeechRemoteState, now: Date) {
        cachedActiveUntil = date(fromMilliseconds: remote.activeUntil)
        cachedCooldownUntil = date(fromMilliseconds: remote.cooldownUntil)
        cachedValidUntil = now.addingTimeInterval(0.5)

        if let phase = remote.phase.flatMap({ AssistantSpeechCapturePhase(rawValue: $0) }) {
            cachedPhase = phase
        } else if remote.active == true {
            cachedPhase = .active
        } else {
            cachedPhase = .idle
        }
    }

    private func effectivePhase(now: Date) -> AssistantSpeechCapturePhase {
        if let activeUntil = cachedActiveUntil, activeUntil > now {
            return .active
        }
        if let cooldownUntil = cachedCooldownUntil, cooldownUntil > now {
            return .cooldown
        }
        guard now < cachedValidUntil else { return .idle }
        return cachedPhase
    }

    private func shouldAllowBargeIn(audioLevel rawLevel: Double, phase: AssistantSpeechCapturePhase, now: Date) -> Bool {
        let audioLevel = rawLevel.isFinite ? max(0, rawLevel) : 0

        if now < bargeInOpenUntil {
            return true
        }

        let threshold = phase == .active ? activeBargeInLevel : cooldownBargeInLevel
        if audioLevel >= threshold {
            if loudAudioStartedAt == nil {
                loudAudioStartedAt = now
            }
            if let startedAt = loudAudioStartedAt, now.timeIntervalSince(startedAt) >= bargeInSustain {
                loudAudioStartedAt = nil
                bargeInOpenUntil = now.addingTimeInterval(bargeInOpenWindow)
                return true
            }
        } else if audioLevel < threshold * 0.65 {
            loudAudioStartedAt = nil
        }

        return false
    }

    private func resetGate() {
        resetRemoteState()
        resetBargeIn()
        lastEndpoint = nil
    }

    private func resetRemoteState() {
        cachedPhase = .idle
        cachedActiveUntil = nil
        cachedCooldownUntil = nil
        cachedValidUntil = Date.distantPast
        nextPollAt = Date.distantPast
    }

    private func resetBargeIn() {
        loudAudioStartedAt = nil
        bargeInOpenUntil = Date.distantPast
    }

    private func date(fromMilliseconds value: Double?) -> Date? {
        guard let value, value.isFinite, value > 0 else { return nil }
        return Date(timeIntervalSince1970: value / 1000.0)
    }

    private func stateURL(from webhookURL: String) -> URL? {
        let trimmed = webhookURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host,
              isLoopbackHost(host) else {
            return nil
        }

        components.path = "/audio/assistant-state"
        components.query = nil
        components.fragment = nil
        return components.url
    }

    private func isLoopbackHost(_ host: String) -> Bool {
        let lower = host.lowercased()
        return lower == "localhost"
            || lower == "::1"
            || lower == "0:0:0:0:0:0:0:1"
            || lower == "127.0.0.1"
            || lower.hasPrefix("127.")
    }
}
