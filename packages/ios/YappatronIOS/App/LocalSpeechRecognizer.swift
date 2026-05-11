import AVFoundation
import Foundation
import Speech

final class LocalSpeechRecognizer {
    enum RecognitionError: LocalizedError {
        case speechRecognitionUnavailable
        case speechRecognitionPermissionDenied
        case microphonePermissionDenied
        case onDeviceRecognitionUnavailable
        case noInputDevice

        var errorDescription: String? {
            switch self {
            case .speechRecognitionUnavailable:
                return "Local speech recognition is unavailable."
            case .speechRecognitionPermissionDenied:
                return "Speech recognition permission is required."
            case .microphonePermissionDenied:
                return "Microphone permission is required."
            case .onDeviceRecognitionUnavailable:
                return "On-device speech recognition is unavailable for this language on this iPhone."
            case .noInputDevice:
                return "No microphone input is available."
            }
        }
    }

    var onTranscript: ((String, Bool) -> Void)?
    var onError: ((String) -> Void)?

    private let audioEngine = AVAudioEngine()
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var latestTranscript = ""
    private var committedTranscript = ""
    private var currentSegmentTranscript = ""
    private var isStopping = false
    private var isRunning = false
    private var isRestarting = false
    private var restartTask: Task<Void, Never>?

    func start() async throws {
        guard await Self.requestSpeechAuthorization() else {
            throw RecognitionError.speechRecognitionPermissionDenied
        }

        guard await Self.requestMicrophoneAuthorization() else {
            throw RecognitionError.microphonePermissionDenied
        }

        guard let speechRecognizer, speechRecognizer.isAvailable else {
            throw RecognitionError.speechRecognitionUnavailable
        }

        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.record, mode: .measurement, options: [.duckOthers])
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)

        isStopping = false
        isRunning = true
        isRestarting = false
        latestTranscript = ""
        committedTranscript = ""
        currentSegmentTranscript = ""

        try startRecognitionTask()

        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard inputFormat.channelCount > 0 else {
            throw RecognitionError.noInputDevice
        }

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1_024, format: inputFormat) { [weak self] buffer, _ in
            self?.recognitionRequest?.append(buffer)
        }

        audioEngine.prepare()
        try audioEngine.start()
    }

    func stop() async -> String {
        isStopping = true
        isRunning = false
        restartTask?.cancel()
        restartTask = nil
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        recognitionRequest?.endAudio()

        try? await Task.sleep(nanoseconds: 700_000_000)

        commitCurrentSegment()
        let transcript = latestTranscript
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)

        return transcript
    }

    private func startRecognitionTask() throws {
        guard let speechRecognizer else {
            throw RecognitionError.speechRecognitionUnavailable
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = speechRecognizer.supportsOnDeviceRecognition
        request.taskHint = .dictation
        if #available(iOS 16.0, *) {
            request.addsPunctuation = true
        }
        recognitionRequest = request

        recognitionTask = speechRecognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else {
                return
            }

            if let result {
                self.receive(result)
            }

            if let error, !self.isStopping, !self.isRestarting {
                self.scheduleRecognitionRestart(after: error)
            }
        }
    }

    private func receive(_ result: SFSpeechRecognitionResult) {
        currentSegmentTranscript = result.bestTranscription.formattedString
        latestTranscript = joinedTranscript(committedTranscript, currentSegmentTranscript)

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.onTranscript?(self.latestTranscript, result.isFinal)
        }

        if result.isFinal, !isStopping {
            commitCurrentSegment()
            scheduleRecognitionRestart(after: nil)
        }
    }

    private func commitCurrentSegment() {
        let segment = currentSegmentTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !segment.isEmpty else {
            latestTranscript = committedTranscript
            currentSegmentTranscript = ""
            return
        }

        committedTranscript = joinedTranscript(committedTranscript, segment)
        latestTranscript = committedTranscript
        currentSegmentTranscript = ""
    }

    private func scheduleRecognitionRestart(after error: Error?) {
        guard isRunning, !isStopping else { return }
        guard !isRestarting else { return }

        isRestarting = true
        commitCurrentSegment()
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil

        restartTask?.cancel()
        restartTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard let self, self.isRunning, !self.isStopping else { return }

            do {
                try self.startRecognitionTask()
                self.isRestarting = false
            } catch {
                self.isRunning = false
                self.isRestarting = false
                let message = error.localizedDescription
                DispatchQueue.main.async { [weak self] in
                    self?.onError?(message)
                }
            }
        }
    }

    private func joinedTranscript(_ lhs: String, _ rhs: String) -> String {
        let left = lhs.trimmingCharacters(in: .whitespacesAndNewlines)
        let right = rhs.trimmingCharacters(in: .whitespacesAndNewlines)

        if left.isEmpty { return right }
        if right.isEmpty { return left }
        return "\(left) \(right)"
    }

    private static func requestSpeechAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    private static func requestMicrophoneAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }
}
