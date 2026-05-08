import Foundation
import FluidAudio

/// One contiguous span of audio attributed to a single speaker by the local
/// diarizer. The `name` is non-nil when the embedding matched an enrolled
/// speaker; otherwise it falls back to the diarizer's internal speaker ID.
struct LocalSpeakerSegment {
    let startSec: Double
    let endSec: Double
    let embedding: [Float]
    let name: String?           // matched enrolled name, if any
    let fallbackId: String      // FluidAudio's internal speaker ID
}

/// Streaming local diarizer. Owns a rolling audio buffer (anchored to the same
/// t=0 as Deepgram, so segment timestamps line up with Deepgram's word
/// timestamps), and periodically runs FluidAudio's full diarization on the
/// accumulated audio. Segment results are cached and queried by timestamp.
///
/// Ground truth for speaker boundaries replaces Deepgram's per-word IDs.
actor SpeakerSegmenter {

    private var diarizer: DiarizerManager?
    private var ready = false

    private var samples: [Float] = []
    private var anchored = false

    /// All segments produced by the most recent diarization pass. Re-diarizing
    /// the entire accumulated audio each time keeps results consistent (no
    /// dedup logic needed) at the cost of redundant work; FluidAudio runs on
    /// ANE so it's tractable for typical conversation lengths.
    private var segments: [LocalSpeakerSegment] = []

    /// Match threshold for the embedding-to-enrolled comparison. Lower = stricter.
    /// We're forgiving by default because the segmenter operates on cleaner
    /// per-segment audio than the per-Deepgram-run slices we used previously.
    var enrolledMatchThreshold: Float = 0.6

    private let sampleRate: Int = 16000
    private let maxBufferSeconds: Int = 240   // hard cap for very long sessions

    /// Set whenever a fresh diarization pass completes. Used to bound how often
    /// we re-run (we re-run on demand from `lookupSpeaker(atSec:)`, throttled).
    private var lastDiarizationTime: Date?
    private let minRediarizeInterval: TimeInterval = 0.4

    func loadIfNeeded() async throws {
        if ready { return }
        log("SpeakerSegmenter: loading FluidAudio diarizer models...")
        let models = try await DiarizerModels.downloadIfNeeded()
        let manager = DiarizerManager()
        manager.initialize(models: consume models)
        self.diarizer = manager
        self.ready = true
        log("SpeakerSegmenter: ready")
    }

    /// Anchor at the moment the first audio buffer is sent to the STT provider,
    /// matching Deepgram's t=0. Subsequent diarization timestamps will use the
    /// same timeline as Deepgram's word.start / word.end fields.
    func anchor() {
        anchored = true
        samples.removeAll()
        segments.removeAll()
        lastDiarizationTime = nil
    }

    /// Append a chunk of 16kHz mono Float32 audio. Must be called in capture order.
    func append(_ chunk: [Float]) {
        guard anchored else { return }
        samples.append(contentsOf: chunk)
        let maxSamples = sampleRate * maxBufferSeconds
        if samples.count > maxSamples {
            samples.removeFirst(samples.count - maxSamples)
        }
    }

    /// Re-run full diarization over the buffered audio if we haven't recently.
    /// Updates `segments` and matches each against the enrolled registry.
    func rediarizeIfStale(enrolled: [EnrolledSpeaker]) async {
        guard ready, let diarizer else { return }
        guard !samples.isEmpty else { return }
        if let last = lastDiarizationTime, Date().timeIntervalSince(last) < minRediarizeInterval { return }
        lastDiarizationTime = Date()

        do {
            let result = try await diarizer.performCompleteDiarization(samples, sampleRate: sampleRate)
            segments = result.segments.map { seg in
                let name = bestEnrolledMatch(embedding: seg.embedding, enrolled: enrolled)
                return LocalSpeakerSegment(
                    startSec: Double(seg.startTimeSeconds),
                    endSec: Double(seg.endTimeSeconds),
                    embedding: seg.embedding,
                    name: name,
                    fallbackId: seg.speakerId
                )
            }
            HybridDiagLog.shared.write("SpeakerSegmenter: rediarized — \(segments.count) segments, \(enrolled.count) enrolled")
            for seg in segments {
                let nameOrId = seg.name ?? seg.fallbackId
                HybridDiagLog.shared.write("  segment [\(String(format: "%.2f", seg.startSec))→\(String(format: "%.2f", seg.endSec))] -> \(nameOrId)")
            }
        } catch {
            HybridDiagLog.shared.write("SpeakerSegmenter: diarization failed: \(error.localizedDescription)")
        }
    }

    /// Look up which speaker was active at a given timestamp. Returns the
    /// enrolled name if matched, else falls back to a "Speaker N" label
    /// derived from the diarizer's internal speaker ID. Returns nil if we
    /// have no segment covering that time (should be rare after anchor).
    func speakerLabel(atSec t: Double, fallbackPrefix: String = "Speaker") -> String? {
        // Find the segment whose [start, end] contains t. If multiple overlap,
        // prefer the one with the closer start.
        var bestSeg: LocalSpeakerSegment?
        for seg in segments {
            if t >= seg.startSec, t <= seg.endSec {
                if bestSeg == nil || abs(t - seg.startSec) < abs(t - bestSeg!.startSec) {
                    bestSeg = seg
                }
            }
        }
        // If no exact match, take the closest segment whose end is just before t,
        // up to 0.5s away. Helps with off-by-rounding cases at boundaries.
        if bestSeg == nil {
            var nearest: (LocalSpeakerSegment, Double)?
            for seg in segments {
                let dist = min(abs(t - seg.startSec), abs(t - seg.endSec))
                if dist < 0.5 {
                    if nearest == nil || dist < nearest!.1 {
                        nearest = (seg, dist)
                    }
                }
            }
            bestSeg = nearest?.0
        }
        guard let seg = bestSeg else { return nil }
        return seg.name ?? "\(fallbackPrefix) \(seg.fallbackId)"
    }

    func reset() {
        samples.removeAll()
        segments.removeAll()
        anchored = false
        lastDiarizationTime = nil
    }

    private func bestEnrolledMatch(embedding: [Float], enrolled: [EnrolledSpeaker]) -> String? {
        guard !enrolled.isEmpty else { return nil }
        var best: (name: String, distance: Float)?
        for e in enrolled {
            let d = SpeakerEmbedder.cosineDistance(embedding, e.embedding)
            if best == nil || d < best!.distance {
                best = (e.name, d)
            }
        }
        if let best = best, best.distance <= enrolledMatchThreshold {
            return best.name
        }
        return nil
    }
}
