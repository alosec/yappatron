import UIKit

final class KeyboardViewController: UIInputViewController {
    private let transcriptStore = SharedTranscriptStore.shared
    private let localDefaults = UserDefaults.standard

    private let transcriptLabel = UILabel()
    private let insertButton = UIButton(type: .system)
    private let micButton = UIButton(type: .system)
    private let historyButton = UIButton(type: .system)
    private let undoButton = UIButton(type: .system)
    private let spaceButton = UIButton(type: .system)
    private let returnButton = UIButton(type: .system)
    private let deleteButton = UIButton(type: .system)
    private let nextKeyboardButton = UIButton(type: .system)

    private var pendingTranscripts: [SharedTranscript] = []
    private var dictationState = SharedDictationState(
        isRecording: false,
        liveTranscript: "",
        updatedAt: 0,
        pressReturnAfterInsert: false
    )
    private var showingHistory = false
    private var refreshTimer: Timer?
    private var lastStreamedLiveTranscript = ""

    private enum LocalKeys {
        static let lastInsertedUpdatedAt = "lastAutoInsertedUpdatedAt"
        static let lastStreamedLiveTranscript = "lastStreamedLiveTranscript"
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        lastStreamedLiveTranscript = localDefaults.string(forKey: LocalKeys.lastStreamedLiveTranscript) ?? ""
        configureView()
        refreshTranscript()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        refreshTranscript()
        autoInsertIfNeeded()
        startRefreshing()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopRefreshing()
    }

    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        refreshTranscript()
    }

    private func configureView() {
        view.backgroundColor = .systemGray5

        transcriptLabel.font = .preferredFont(forTextStyle: .callout)
        transcriptLabel.numberOfLines = 3
        transcriptLabel.lineBreakMode = .byTruncatingTail
        transcriptLabel.textColor = .label
        transcriptLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        micButton.configuration = .filled()
        micButton.configuration?.image = UIImage(systemName: "mic.fill")
        micButton.configuration?.imagePadding = 8
        micButton.configuration?.title = "Start Dictation"
        micButton.addTarget(self, action: #selector(micButtonTapped), for: .touchUpInside)
        micButton.accessibilityLabel = "Start dictation"

        historyButton.configuration = .tinted()
        historyButton.configuration?.image = UIImage(systemName: "clock.arrow.circlepath")
        historyButton.addTarget(self, action: #selector(historyButtonTapped), for: .touchUpInside)
        historyButton.accessibilityLabel = "Transcript history"

        insertButton.configuration = .filled()
        insertButton.configuration?.image = UIImage(systemName: "checkmark")
        insertButton.configuration?.imagePadding = 8
        insertButton.configuration?.title = "Finish"
        insertButton.addTarget(self, action: #selector(insertButtonTapped), for: .touchUpInside)
        insertButton.accessibilityLabel = "Finish dictation"

        nextKeyboardButton.configuration = .plain()
        nextKeyboardButton.configuration?.image = UIImage(systemName: "globe")
        nextKeyboardButton.addTarget(self, action: #selector(handleInputModeList(from:with:)), for: .allTouchEvents)
        nextKeyboardButton.accessibilityLabel = "Next keyboard"

        undoButton.configuration = .plain()
        undoButton.configuration?.image = UIImage(systemName: "arrow.uturn.backward")
        undoButton.addTarget(self, action: #selector(undoButtonTapped), for: .touchUpInside)
        undoButton.accessibilityLabel = "Undo"

        spaceButton.configuration = .plain()
        spaceButton.configuration?.title = "space"
        spaceButton.addTarget(self, action: #selector(spaceButtonTapped), for: .touchUpInside)
        spaceButton.accessibilityLabel = "Space"

        returnButton.configuration = .plain()
        returnButton.configuration?.image = UIImage(systemName: "return")
        returnButton.addTarget(self, action: #selector(returnButtonTapped), for: .touchUpInside)
        returnButton.accessibilityLabel = "Return"

        deleteButton.configuration = .plain()
        deleteButton.configuration?.image = UIImage(systemName: "delete.left")
        deleteButton.addTarget(self, action: #selector(deleteButtonTapped), for: .touchUpInside)
        deleteButton.accessibilityLabel = "Delete"

        let primaryRow = UIStackView(arrangedSubviews: [nextKeyboardButton, micButton, historyButton, insertButton])
        primaryRow.axis = .horizontal
        primaryRow.alignment = .fill
        primaryRow.distribution = .fill
        primaryRow.spacing = 10

        let editRow = UIStackView(arrangedSubviews: [undoButton, spaceButton, returnButton, deleteButton])
        editRow.axis = .horizontal
        editRow.alignment = .fill
        editRow.distribution = .fill
        editRow.spacing = 8

        let buttonRow = UIStackView(arrangedSubviews: [primaryRow, editRow])
        buttonRow.axis = .vertical
        buttonRow.alignment = .fill
        buttonRow.distribution = .fill
        buttonRow.spacing = 8

        nextKeyboardButton.widthAnchor.constraint(equalToConstant: 44).isActive = true
        historyButton.widthAnchor.constraint(equalToConstant: 44).isActive = true
        undoButton.widthAnchor.constraint(equalToConstant: 42).isActive = true
        returnButton.widthAnchor.constraint(equalToConstant: 42).isActive = true
        deleteButton.widthAnchor.constraint(equalToConstant: 42).isActive = true

        let stack = UIStackView(arrangedSubviews: [transcriptLabel, buttonRow])
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: view.layoutMarginsGuide.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: view.layoutMarginsGuide.bottomAnchor, constant: -8),
            view.heightAnchor.constraint(greaterThanOrEqualToConstant: 216)
        ])
    }

    private func refreshTranscript() {
        dictationState = transcriptStore.latestDictationStateForKeyboard()
        let lastInsertedAt = localDefaults.double(forKey: LocalKeys.lastInsertedUpdatedAt)
        pendingTranscripts = transcriptStore.keyboardTranscripts(after: lastInsertedAt)
        let hadStreamedLiveText = !lastStreamedLiveTranscript.isEmpty
        let didStreamLiveText = streamLiveTranscriptIfNeeded()
        if dictationState.isRecording {
            if didStreamLiveText || !lastStreamedLiveTranscript.isEmpty {
                markPendingTranscriptsInserted()
            }
        } else if hadStreamedLiveText {
            markPendingTranscriptsInserted()
        }

        let text = showingHistory
            ? pendingText(from: pendingTranscripts)
            : dictationState.liveTranscript.trimmingCharacters(in: .whitespacesAndNewlines)

        if text.isEmpty {
            if dictationState.isRecording {
                transcriptLabel.text = "Listening"
            } else if pendingTranscripts.isEmpty {
                transcriptLabel.text = "Start Dictation"
            } else {
                transcriptLabel.text = "\(pendingTranscripts.count) snippet\(pendingTranscripts.count == 1 ? "" : "s") ready"
            }
        } else if showingHistory && pendingTranscripts.count > 1 {
            transcriptLabel.text = "\(pendingTranscripts.count) snippets\n\(text)"
        } else if dictationState.isRecording {
            transcriptLabel.text = text
        } else if pendingTranscripts.count > 1 {
            transcriptLabel.text = "\(pendingTranscripts.count) chunks ready\n\(text)"
        } else if pendingTranscripts.first?.pressReturnAfterInsert == true {
            transcriptLabel.text = "\(text)\n↵"
        } else {
            transcriptLabel.text = text
        }
        transcriptLabel.textColor = text.isEmpty ? .secondaryLabel : .label
        micButton.configuration?.title = dictationState.isRecording ? "Recording" : "Start Dictation"
        micButton.configuration?.image = UIImage(systemName: dictationState.isRecording ? "waveform" : "mic.fill")
        micButton.isEnabled = !dictationState.isRecording
        insertButton.isEnabled = dictationState.isRecording || !pendingTranscripts.isEmpty || !text.isEmpty
        insertButton.configuration?.title = dictationState.isRecording ? "Finish" : "Insert"
    }

    private func autoInsertIfNeeded() {
        guard !dictationState.isRecording else {
            return
        }

        let ready = pendingTranscripts.filter(\.autoInsertOnKeyboardOpen)
        guard !ready.isEmpty else {
            return
        }

        insert(ready, markInserted: true)
    }

    private func startRefreshing() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.refreshTranscript()
            self.autoInsertIfNeeded()
        }

        if let refreshTimer {
            RunLoop.main.add(refreshTimer, forMode: .common)
        }
    }

    private func stopRefreshing() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    private func insert(_ transcripts: [SharedTranscript], markInserted: Bool) {
        let chunks = transcripts.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !chunks.isEmpty else {
            return
        }

        for (index, transcript) in chunks.enumerated() {
            let text = transcript.text.trimmingCharacters(in: .whitespacesAndNewlines)
            textDocumentProxy.insertText(text)

            if transcript.pressReturnAfterInsert {
                textDocumentProxy.insertText("\n")
            } else if index < chunks.count - 1 {
                textDocumentProxy.insertText(" ")
            }
        }

        if markInserted, let newest = chunks.last?.updatedAt {
            localDefaults.set(newest, forKey: LocalKeys.lastInsertedUpdatedAt)
            refreshTranscript()
        }
    }

    @objc private func insertButtonTapped() {
        if dictationState.isRecording {
            insertLiveRemainder()
            markPendingTranscriptsInserted()
            transcriptStore.saveKeyboardCommand("stop")
            return
        }

        insert(pendingTranscripts, markInserted: true)
    }

    @objc private func micButtonTapped() {
        transcriptStore.saveKeyboardCommand("start")
        guard let url = URL(string: "yappatron://dictation/start") else {
            return
        }

        extensionContext?.open(url, completionHandler: nil)
    }

    @objc private func historyButtonTapped() {
        showingHistory.toggle()
        refreshTranscript()
    }

    @objc private func undoButtonTapped() {
        textDocumentProxy.deleteBackward()
    }

    @objc private func spaceButtonTapped() {
        textDocumentProxy.insertText(" ")
    }

    @objc private func returnButtonTapped() {
        textDocumentProxy.insertText("\n")
    }

    @objc private func deleteButtonTapped() {
        textDocumentProxy.deleteBackward()
    }

    private func pendingText(from transcripts: [SharedTranscript]) -> String {
        transcripts
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    @discardableResult
    private func streamLiveTranscriptIfNeeded() -> Bool {
        guard dictationState.isRecording else {
            lastStreamedLiveTranscript = ""
            localDefaults.set("", forKey: LocalKeys.lastStreamedLiveTranscript)
            return false
        }

        let live = dictationState.liveTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !live.isEmpty else { return false }

        let delta: String
        if live.hasPrefix(lastStreamedLiveTranscript) {
            delta = String(live.dropFirst(lastStreamedLiveTranscript.count))
        } else {
            delta = live
        }

        let trimmedDelta = delta.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedDelta.isEmpty else { return false }

        if !lastStreamedLiveTranscript.isEmpty,
           !delta.hasPrefix(" "),
           !delta.hasPrefix("\n") {
            textDocumentProxy.insertText(" ")
        }
        textDocumentProxy.insertText(delta.hasPrefix(" ") || delta.hasPrefix("\n") ? delta : trimmedDelta)
        lastStreamedLiveTranscript = live
        localDefaults.set(lastStreamedLiveTranscript, forKey: LocalKeys.lastStreamedLiveTranscript)
        return true
    }

    private func insertLiveRemainder() {
        let live = dictationState.liveTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !live.isEmpty else { return }

        if live.hasPrefix(lastStreamedLiveTranscript) {
            let delta = String(live.dropFirst(lastStreamedLiveTranscript.count))
            if !delta.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                textDocumentProxy.insertText(delta)
            }
        } else if lastStreamedLiveTranscript.isEmpty {
            textDocumentProxy.insertText(live)
        }

        if dictationState.pressReturnAfterInsert {
            textDocumentProxy.insertText("\n")
        }

        lastStreamedLiveTranscript = ""
        localDefaults.set("", forKey: LocalKeys.lastStreamedLiveTranscript)
    }

    private func markPendingTranscriptsInserted() {
        guard let newest = pendingTranscripts.last?.updatedAt else {
            return
        }

        let lastInsertedAt = localDefaults.double(forKey: LocalKeys.lastInsertedUpdatedAt)
        if newest > lastInsertedAt {
            localDefaults.set(newest, forKey: LocalKeys.lastInsertedUpdatedAt)
        }
        pendingTranscripts.removeAll { $0.updatedAt <= newest }
    }
}
