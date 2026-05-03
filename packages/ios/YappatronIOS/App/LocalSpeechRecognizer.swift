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
    private var isStopping = false

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

        guard speechRecognizer.supportsOnDeviceRecognition else {
            throw RecognitionError.onDeviceRecognitionUnavailable
        }

        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.record, mode: .measurement, options: [.duckOthers])
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        request.taskHint = .dictation
        recognitionRequest = request

        recognitionTask = speechRecognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else {
                return
            }

            if let result {
                let transcript = result.bestTranscription.formattedString
                self.latestTranscript = transcript

                DispatchQueue.main.async { [weak self] in
                    self?.onTranscript?(transcript, result.isFinal)
                }
            }

            if let error, !self.isStopping {
                let message = error.localizedDescription
                DispatchQueue.main.async { [weak self] in
                    self?.onError?(message)
                }
            }
        }

        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard inputFormat.channelCount > 0 else {
            throw RecognitionError.noInputDevice
        }

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1_024, format: inputFormat) { [weak request] buffer, _ in
            request?.append(buffer)
        }

        audioEngine.prepare()
        try audioEngine.start()
    }

    func stop() async -> String {
        isStopping = true
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        recognitionRequest?.endAudio()

        try? await Task.sleep(nanoseconds: 700_000_000)

        let transcript = latestTranscript
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)

        return transcript
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
