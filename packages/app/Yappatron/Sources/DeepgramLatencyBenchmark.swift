import AVFoundation
import Foundation

enum DeepgramLatencyBenchmarkCommand {
    static func shouldRun(arguments: [String]) -> Bool {
        arguments.contains("--deepgram-benchmark")
    }

    static func run(arguments: [String]) async -> Int {
        do {
            let config = try BenchmarkConfig(arguments: arguments)
            let result = try await DeepgramLatencyBenchmark(config: config).run()
            try result.writeOutputs(jsonURL: config.jsonURL, csvURL: config.csvURL)
            result.printSummary()
            return 0
        } catch BenchmarkConfig.ConfigError.helpRequested {
            BenchmarkConfig.printUsage()
            return 0
        } catch {
            fputs("Deepgram benchmark failed: \(error.localizedDescription)\n", stderr)
            BenchmarkConfig.printUsage()
            return 2
        }
    }
}

private struct BenchmarkConfig {
    enum ConfigError: LocalizedError {
        case helpRequested
        case missingValue(String)
        case missingAudio
        case invalidInteger(String)
        case invalidDouble(String)
        case missingAPIKey

        var errorDescription: String? {
            switch self {
            case .helpRequested:
                return nil
            case .missingValue(let flag):
                return "Missing value after \(flag)"
            case .missingAudio:
                return "Missing required --audio path"
            case .invalidInteger(let value):
                return "Invalid integer: \(value)"
            case .invalidDouble(let value):
                return "Invalid number: \(value)"
            case .missingAPIKey:
                return "Missing Deepgram API key"
            }
        }
    }

    let audioURL: URL
    let expectedURL: URL?
    let apiKey: String
    let chunkFrames: Int
    let postRollMs: UInt64
    let realtimeSpeed: Double
    let jsonURL: URL?
    let csvURL: URL?

    init(arguments: [String]) throws {
        var audioPath: String?
        var expectedPath: String?
        var chunkFrames = 1365
        var postRollMs: UInt64 = 3200
        var realtimeSpeed = 1.0
        var jsonPath: String?
        var csvPath: String?

        var index = 0
        while index < arguments.count {
            let arg = arguments[index]
            switch arg {
            case "--deepgram-benchmark":
                index += 1
            case "--help", "-h":
                throw ConfigError.helpRequested
            case "--audio":
                audioPath = try Self.value(after: arg, in: arguments, index: &index)
            case "--expected":
                expectedPath = try Self.value(after: arg, in: arguments, index: &index)
            case "--chunk-frames":
                let value = try Self.value(after: arg, in: arguments, index: &index)
                guard let parsed = Int(value), parsed > 0 else { throw ConfigError.invalidInteger(value) }
                chunkFrames = parsed
            case "--post-roll-ms":
                let value = try Self.value(after: arg, in: arguments, index: &index)
                guard let parsed = UInt64(value) else { throw ConfigError.invalidInteger(value) }
                postRollMs = parsed
            case "--speed":
                let value = try Self.value(after: arg, in: arguments, index: &index)
                guard let parsed = Double(value), parsed > 0 else { throw ConfigError.invalidDouble(value) }
                realtimeSpeed = parsed
            case "--json":
                jsonPath = try Self.value(after: arg, in: arguments, index: &index)
            case "--csv":
                csvPath = try Self.value(after: arg, in: arguments, index: &index)
            default:
                if audioPath == nil {
                    audioPath = arg
                    index += 1
                } else {
                    index += 1
                }
            }
        }

        guard let audioPath else { throw ConfigError.missingAudio }

        let envKey = ProcessInfo.processInfo.environment["DEEPGRAM_API_KEY"] ?? ""
        let storedKey = APIKeyStore.get(for: .deepgram) ?? ""
        let apiKey = (envKey.isEmpty ? storedKey : envKey).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else { throw ConfigError.missingAPIKey }

        self.audioURL = URL(fileURLWithPath: audioPath)
        self.expectedURL = expectedPath.map(URL.init(fileURLWithPath:))
        self.apiKey = apiKey
        self.chunkFrames = chunkFrames
        self.postRollMs = postRollMs
        self.realtimeSpeed = realtimeSpeed
        self.jsonURL = jsonPath.map(URL.init(fileURLWithPath:))
        self.csvURL = csvPath.map(URL.init(fileURLWithPath:))
    }

    private static func value(after flag: String, in arguments: [String], index: inout Int) throws -> String {
        let valueIndex = index + 1
        guard valueIndex < arguments.count else { throw ConfigError.missingValue(flag) }
        index += 2
        return arguments[valueIndex]
    }

    static func printUsage() {
        let usage = """

        Usage:
          Yappatron --deepgram-benchmark --audio file.wav [options]

        Options:
          --expected file.txt       Expected transcript for WER/CER scoring
          --chunk-frames N          16 kHz frames per provider chunk (default: 1365, about 85ms)
          --post-roll-ms N          Wait after audio end before explicit finalize (default: 3200)
          --speed N                 Realtime playback speed multiplier (default: 1.0)
          --json file.json          Write detailed events and summary JSON
          --csv file.csv            Append one summary row

        API key:
          DEEPGRAM_API_KEY must be set, or a Deepgram key must be saved in the Mac app.
        """
        fputs("\(usage)\n", stderr)
    }
}

private final class BenchmarkClock: @unchecked Sendable {
    private let startNs = DispatchTime.now().uptimeNanoseconds

    func elapsedMs() -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - startNs) / 1_000_000.0
    }
}

private actor BenchmarkRecorder {
    private var events: [BenchmarkEvent] = []

    func record(kind: String, at timeMs: Double, text: String? = nil, length: Int? = nil) {
        events.append(BenchmarkEvent(time_ms: timeMs, kind: kind, text: text, length: length))
    }

    func snapshot() -> [BenchmarkEvent] {
        events
    }
}

private struct BenchmarkEvent: Codable {
    let time_ms: Double
    let kind: String
    let text: String?
    let length: Int?
}

private struct BenchmarkSummary: Codable {
    let run_id: String
    let fixture: String
    let audio_path: String
    let chunk_frames: Int
    let chunk_ms: Double
    let audio_duration_ms: Double
    let provider_start_ms: Double
    let audio_start_ms: Double
    let first_audio_sent_ms: Double?
    let first_partial_ms: Double?
    let first_partial_after_audio_start_ms: Double?
    let first_locked_final_ms: Double?
    let first_final_ms: Double?
    let audio_end_ms: Double
    let final_after_audio_end_ms: Double?
    let partial_count: Int
    let locked_final_count: Int
    let final_count: Int
    let premature_final_count: Int
    let avg_partial_interval_ms: Double?
    let max_partial_gap_ms: Double?
    let churn_score: Double
    let wer: Double?
    let cer: Double?
    let final_text: String
}

private struct BenchmarkResult: Codable {
    let summary: BenchmarkSummary
    let events: [BenchmarkEvent]

    func writeOutputs(jsonURL: URL?, csvURL: URL?) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        if let jsonURL {
            let data = try encoder.encode(self)
            try FileManager.default.createDirectory(
                at: jsonURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: jsonURL)
        }

        if let csvURL {
            try FileManager.default.createDirectory(
                at: csvURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let row = summary.csvRow() + "\n"
            if FileManager.default.fileExists(atPath: csvURL.path) {
                let handle = try FileHandle(forWritingTo: csvURL)
                try handle.seekToEnd()
                try handle.write(contentsOf: Data(row.utf8))
                try handle.close()
            } else {
                let header = BenchmarkSummary.csvHeader() + "\n"
                try Data((header + row).utf8).write(to: csvURL)
            }
        }
    }

    func printSummary() {
        let s = summary
        print("Deepgram latency benchmark")
        print("  run_id: \(s.run_id)")
        print("  fixture: \(s.fixture)")
        print("  chunk: \(s.chunk_frames) frames (\(Self.format(s.chunk_ms))ms)")
        print("  audio_duration: \(Self.format(s.audio_duration_ms))ms")
        print("  provider_start: \(Self.format(s.provider_start_ms))ms")
        print("  first_partial: \(Self.formatOptional(s.first_partial_after_audio_start_ms))ms after audio start")
        print("  first_locked_final: \(Self.formatOptional(s.first_locked_final_ms))ms")
        print("  first_final: \(Self.formatOptional(s.first_final_ms))ms")
        print("  final_after_audio_end: \(Self.formatOptional(s.final_after_audio_end_ms))ms")
        print("  partials: \(s.partial_count), avg_interval: \(Self.formatOptional(s.avg_partial_interval_ms))ms, max_gap: \(Self.formatOptional(s.max_partial_gap_ms))ms")
        print("  churn_score: \(Self.format(s.churn_score))")
        if let wer = s.wer, let cer = s.cer {
            print("  wer: \(Self.format(wer)), cer: \(Self.format(cer))")
        }
        print("  final_text: \(s.final_text)")
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.1f", value)
    }

    private static func formatOptional(_ value: Double?) -> String {
        value.map(format) ?? "n/a"
    }
}

private extension BenchmarkSummary {
    static func csvHeader() -> String {
        [
            "run_id",
            "fixture",
            "audio_path",
            "chunk_frames",
            "chunk_ms",
            "audio_duration_ms",
            "provider_start_ms",
            "first_partial_ms",
            "first_partial_after_audio_start_ms",
            "first_locked_final_ms",
            "first_final_ms",
            "audio_end_ms",
            "final_after_audio_end_ms",
            "partial_count",
            "avg_partial_interval_ms",
            "max_partial_gap_ms",
            "churn_score",
            "wer",
            "cer",
            "final_text"
        ].joined(separator: ",")
    }

    func csvRow() -> String {
        [
            run_id,
            fixture,
            audio_path,
            String(chunk_frames),
            Self.format(chunk_ms),
            Self.format(audio_duration_ms),
            Self.format(provider_start_ms),
            Self.format(first_partial_ms),
            Self.format(first_partial_after_audio_start_ms),
            Self.format(first_locked_final_ms),
            Self.format(first_final_ms),
            Self.format(audio_end_ms),
            Self.format(final_after_audio_end_ms),
            String(partial_count),
            Self.format(avg_partial_interval_ms),
            Self.format(max_partial_gap_ms),
            Self.format(churn_score),
            Self.format(wer),
            Self.format(cer),
            final_text
        ].map(Self.csvEscape).joined(separator: ",")
    }

    private static func format(_ value: Double?) -> String {
        value.map { String(format: "%.3f", $0) } ?? ""
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.3f", value)
    }

    private static func csvEscape(_ value: String) -> String {
        if value.contains(",") || value.contains("\"") || value.contains("\n") {
            return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
        }
        return value
    }
}

private final class DeepgramLatencyBenchmark {
    private let config: BenchmarkConfig
    private let clock = BenchmarkClock()
    private let recorder = BenchmarkRecorder()
    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
    )!

    init(config: BenchmarkConfig) {
        self.config = config
    }

    func run() async throws -> BenchmarkResult {
        let samples = try Self.loadSamples(from: config.audioURL, targetFormat: targetFormat)
        let audioDurationMs = Double(samples.count) / targetFormat.sampleRate * 1000.0
        let provider = DeepgramSTTProvider(apiKey: config.apiKey)

        provider.onPartial = { [clock, recorder] text in
            let timeMs = clock.elapsedMs()
            Task { await recorder.record(kind: "partial", at: timeMs, text: text, length: text.count) }
        }
        provider.onLockedTextAdvanced = { [clock, recorder] length in
            let timeMs = clock.elapsedMs()
            Task { await recorder.record(kind: "locked_final", at: timeMs, length: length) }
        }
        provider.onFinal = { [clock, recorder] text in
            let timeMs = clock.elapsedMs()
            Task { await recorder.record(kind: "final", at: timeMs, text: text, length: text.count) }
        }
        provider.onDiarizedFinal = { [clock, recorder] runs in
            let timeMs = clock.elapsedMs()
            Task { await recorder.record(kind: "diarized_final", at: timeMs, length: runs.count) }
        }

        let startBeginMs = clock.elapsedMs()
        try await provider.start()
        let providerReadyMs = clock.elapsedMs()
        await recorder.record(kind: "provider_ready", at: providerReadyMs)

        let audioStartMs = clock.elapsedMs()
        await recorder.record(kind: "audio_start", at: audioStartMs)

        var firstAudioSentMs: Double?
        var offset = 0
        let audioStartNs = DispatchTime.now().uptimeNanoseconds
        while offset < samples.count {
            let frameCount = min(config.chunkFrames, samples.count - offset)
            let buffer = try makeBuffer(samples: samples, offset: offset, frameCount: frameCount)
            try await provider.processAudio(buffer)
            if firstAudioSentMs == nil {
                let sentMs = clock.elapsedMs()
                firstAudioSentMs = sentMs
                await recorder.record(kind: "first_audio_sent", at: sentMs)
            }

            offset += frameCount
            let targetElapsedSeconds = Double(offset) / targetFormat.sampleRate / config.realtimeSpeed
            let targetNs = audioStartNs + UInt64(targetElapsedSeconds * 1_000_000_000)
            let nowNs = DispatchTime.now().uptimeNanoseconds
            if targetNs > nowNs {
                try await Task.sleep(nanoseconds: targetNs - nowNs)
            }
        }

        let audioEndMs = clock.elapsedMs()
        await recorder.record(kind: "audio_end", at: audioEndMs)
        try await Task.sleep(nanoseconds: config.postRollMs * 1_000_000)

        if let flushText = try await provider.finishCurrentUtterance(), !flushText.isEmpty {
            let timeMs = clock.elapsedMs()
            await recorder.record(kind: "final_flush", at: timeMs, text: flushText, length: flushText.count)
        }

        try await Task.sleep(nanoseconds: 250_000_000)
        provider.cleanup()

        let events = await recorder.snapshot()
        let expectedText = try config.expectedURL.map { try String(contentsOf: $0, encoding: .utf8) }
        let summary = Self.makeSummary(
            runID: UUID().uuidString,
            config: config,
            events: events,
            audioDurationMs: audioDurationMs,
            chunkMs: Double(config.chunkFrames) / targetFormat.sampleRate * 1000.0,
            providerStartMs: providerReadyMs - startBeginMs,
            audioStartMs: audioStartMs,
            firstAudioSentMs: firstAudioSentMs,
            audioEndMs: audioEndMs,
            expectedText: expectedText
        )

        return BenchmarkResult(summary: summary, events: events)
    }

    private func makeBuffer(samples: [Float], offset: Int, frameCount: Int) throws -> AVAudioPCMBuffer {
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: AVAudioFrameCount(frameCount)
        ) else {
            throw NSError(domain: "DeepgramLatencyBenchmark", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Could not allocate audio buffer"
            ])
        }

        buffer.frameLength = AVAudioFrameCount(frameCount)
        guard let dst = buffer.floatChannelData?.pointee else {
            throw NSError(domain: "DeepgramLatencyBenchmark", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Could not access audio buffer channel data"
            ])
        }

        samples.withUnsafeBufferPointer { src in
            if let base = src.baseAddress {
                memcpy(dst, base.advanced(by: offset), frameCount * MemoryLayout<Float>.size)
            }
        }
        return buffer
    }

    private static func loadSamples(from url: URL, targetFormat: AVAudioFormat) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let sourceFormat = file.processingFormat
        guard let sourceBuffer = AVAudioPCMBuffer(
            pcmFormat: sourceFormat,
            frameCapacity: AVAudioFrameCount(file.length)
        ) else {
            throw NSError(domain: "DeepgramLatencyBenchmark", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "Could not allocate source audio buffer"
            ])
        }

        try file.read(into: sourceBuffer)

        let outputBuffer: AVAudioPCMBuffer
        if sourceFormat.sampleRate == targetFormat.sampleRate,
           sourceFormat.channelCount == targetFormat.channelCount,
           sourceFormat.commonFormat == targetFormat.commonFormat,
           !sourceFormat.isInterleaved {
            outputBuffer = sourceBuffer
        } else {
            guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
                throw NSError(domain: "DeepgramLatencyBenchmark", code: 4, userInfo: [
                    NSLocalizedDescriptionKey: "Could not create audio converter"
                ])
            }
            let ratio = targetFormat.sampleRate / sourceFormat.sampleRate
            let outputFrameCapacity = AVAudioFrameCount(Double(sourceBuffer.frameLength) * ratio + 64)
            guard let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputFrameCapacity) else {
                throw NSError(domain: "DeepgramLatencyBenchmark", code: 5, userInfo: [
                    NSLocalizedDescriptionKey: "Could not allocate converted audio buffer"
                ])
            }

            var suppliedInput = false
            var conversionError: NSError?
            let status = converter.convert(to: converted, error: &conversionError) { _, outStatus in
                if suppliedInput {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                suppliedInput = true
                outStatus.pointee = .haveData
                return sourceBuffer
            }
            guard status != .error, conversionError == nil else {
                throw conversionError ?? NSError(domain: "DeepgramLatencyBenchmark", code: 6, userInfo: [
                    NSLocalizedDescriptionKey: "Audio conversion failed"
                ])
            }
            outputBuffer = converted
        }

        guard let channelData = outputBuffer.floatChannelData else {
            throw NSError(domain: "DeepgramLatencyBenchmark", code: 7, userInfo: [
                NSLocalizedDescriptionKey: "Converted audio has no Float32 channel data"
            ])
        }
        let frameLength = Int(outputBuffer.frameLength)
        return Array(UnsafeBufferPointer(start: channelData[0], count: frameLength))
    }

    private static func makeSummary(
        runID: String,
        config: BenchmarkConfig,
        events: [BenchmarkEvent],
        audioDurationMs: Double,
        chunkMs: Double,
        providerStartMs: Double,
        audioStartMs: Double,
        firstAudioSentMs: Double?,
        audioEndMs: Double,
        expectedText: String?
    ) -> BenchmarkSummary {
        let partials = events.filter { $0.kind == "partial" }
        let lockedFinals = events.filter { $0.kind == "locked_final" }
        let finals = events.filter { $0.kind == "final" || $0.kind == "final_flush" }
        let firstPartialMs = partials.first?.time_ms
        let firstLockedFinalMs = lockedFinals.first?.time_ms
        let firstFinalMs = finals.first?.time_ms
        let partialIntervals = zip(partials, partials.dropFirst()).map { $1.time_ms - $0.time_ms }
        let avgPartialInterval = partialIntervals.isEmpty
            ? nil
            : partialIntervals.reduce(0, +) / Double(partialIntervals.count)
        let maxPartialGap = partialIntervals.max()
        let finalText = finals.compactMap(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        let churnScore = Self.churnScore(for: partials.compactMap(\.text))
        let prematureFinalCount = finals.filter { $0.time_ms < audioEndMs }.count
        let wer = expectedText.map { Self.wordErrorRate(expected: $0, actual: finalText) }
        let cer = expectedText.map { Self.characterErrorRate(expected: $0, actual: finalText) }

        return BenchmarkSummary(
            run_id: runID,
            fixture: config.expectedURL?.deletingPathExtension().lastPathComponent ?? config.audioURL.deletingPathExtension().lastPathComponent,
            audio_path: config.audioURL.path,
            chunk_frames: config.chunkFrames,
            chunk_ms: chunkMs,
            audio_duration_ms: audioDurationMs,
            provider_start_ms: providerStartMs,
            audio_start_ms: audioStartMs,
            first_audio_sent_ms: firstAudioSentMs,
            first_partial_ms: firstPartialMs,
            first_partial_after_audio_start_ms: firstPartialMs.map { $0 - audioStartMs },
            first_locked_final_ms: firstLockedFinalMs,
            first_final_ms: firstFinalMs,
            audio_end_ms: audioEndMs,
            final_after_audio_end_ms: firstFinalMs.map { $0 - audioEndMs },
            partial_count: partials.count,
            locked_final_count: lockedFinals.count,
            final_count: finals.count,
            premature_final_count: prematureFinalCount,
            avg_partial_interval_ms: avgPartialInterval,
            max_partial_gap_ms: maxPartialGap,
            churn_score: churnScore,
            wer: wer,
            cer: cer,
            final_text: finalText
        )
    }

    private static func churnScore(for texts: [String]) -> Double {
        guard texts.count > 1 else { return 0 }

        var removed = 0
        var observed = 0
        for (previous, current) in zip(texts, texts.dropFirst()) {
            observed += max(previous.count, current.count)
            let common = commonPrefixLength(previous, current)
            removed += max(0, previous.count - common)
        }
        guard observed > 0 else { return 0 }
        return Double(removed) / Double(observed)
    }

    private static func commonPrefixLength(_ lhs: String, _ rhs: String) -> Int {
        var count = 0
        for (left, right) in zip(lhs, rhs) {
            if left != right { break }
            count += 1
        }
        return count
    }

    private static func wordErrorRate(expected: String, actual: String) -> Double {
        let expectedWords = normalizedWords(expected)
        let actualWords = normalizedWords(actual)
        guard !expectedWords.isEmpty else { return actualWords.isEmpty ? 0 : 1 }
        return Double(editDistance(expectedWords, actualWords)) / Double(expectedWords.count)
    }

    private static func characterErrorRate(expected: String, actual: String) -> Double {
        let expectedCharacters = Array(normalizedCharacters(expected))
        let actualCharacters = Array(normalizedCharacters(actual))
        guard !expectedCharacters.isEmpty else { return actualCharacters.isEmpty ? 0 : 1 }
        return Double(editDistance(expectedCharacters, actualCharacters)) / Double(expectedCharacters.count)
    }

    private static func normalizedWords(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    private static func normalizedCharacters(_ text: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(.whitespacesAndNewlines)
        let filtered = String(text.lowercased().unicodeScalars.map { allowed.contains($0) ? Character($0) : " " })
        return filtered.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func editDistance<T: Equatable>(_ lhs: [T], _ rhs: [T]) -> Int {
        if lhs.isEmpty { return rhs.count }
        if rhs.isEmpty { return lhs.count }

        var previous = Array(0...rhs.count)
        var current = Array(repeating: 0, count: rhs.count + 1)

        for i in 1...lhs.count {
            current[0] = i
            for j in 1...rhs.count {
                if lhs[i - 1] == rhs[j - 1] {
                    current[j] = previous[j - 1]
                } else {
                    current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + 1)
                }
            }
            swap(&previous, &current)
        }

        return previous[rhs.count]
    }
}
