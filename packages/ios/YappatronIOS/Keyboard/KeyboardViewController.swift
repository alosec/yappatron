import UIKit

final class KeyboardViewController: UIInputViewController {
    private let transcriptStore = SharedTranscriptStore.shared
    private let localDefaults = UserDefaults.standard

    private let transcriptLabel = UILabel()
    private let insertButton = UIButton(type: .system)
    private let refreshButton = UIButton(type: .system)
    private let nextKeyboardButton = UIButton(type: .system)

    private var pendingTranscripts: [SharedTranscript] = []
    private var refreshTimer: Timer?

    private enum LocalKeys {
        static let lastInsertedUpdatedAt = "lastAutoInsertedUpdatedAt"
    }

    override func viewDidLoad() {
        super.viewDidLoad()
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

        insertButton.configuration = .filled()
        insertButton.configuration?.image = UIImage(systemName: "text.insert")
        insertButton.configuration?.imagePadding = 8
        insertButton.configuration?.title = "Insert"
        insertButton.addTarget(self, action: #selector(insertButtonTapped), for: .touchUpInside)

        refreshButton.configuration = .tinted()
        refreshButton.configuration?.image = UIImage(systemName: "arrow.clockwise")
        refreshButton.addTarget(self, action: #selector(refreshButtonTapped), for: .touchUpInside)
        refreshButton.accessibilityLabel = "Refresh latest transcript"

        nextKeyboardButton.configuration = .plain()
        nextKeyboardButton.configuration?.image = UIImage(systemName: "globe")
        nextKeyboardButton.addTarget(self, action: #selector(handleInputModeList(from:with:)), for: .allTouchEvents)
        nextKeyboardButton.accessibilityLabel = "Next keyboard"

        let buttonRow = UIStackView(arrangedSubviews: [nextKeyboardButton, refreshButton, insertButton])
        buttonRow.axis = .horizontal
        buttonRow.alignment = .fill
        buttonRow.distribution = .fill
        buttonRow.spacing = 10

        nextKeyboardButton.widthAnchor.constraint(equalToConstant: 44).isActive = true
        refreshButton.widthAnchor.constraint(equalToConstant: 44).isActive = true

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
            view.heightAnchor.constraint(greaterThanOrEqualToConstant: 172)
        ])
    }

    private func refreshTranscript() {
        let lastInsertedAt = localDefaults.double(forKey: LocalKeys.lastInsertedUpdatedAt)
        pendingTranscripts = transcriptStore.keyboardTranscripts(after: lastInsertedAt)
        let text = pendingText(from: pendingTranscripts)

        if text.isEmpty {
            let latest = transcriptStore.latestTranscriptForKeyboard()
            if latest.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                transcriptLabel.text = "Waiting for Yappatron"
            } else {
                transcriptLabel.text = "Latest Yappatron text inserted"
            }
        } else if pendingTranscripts.count > 1 {
            transcriptLabel.text = "\(pendingTranscripts.count) chunks ready\n\(text)"
        } else if pendingTranscripts.first?.pressReturnAfterInsert == true {
            transcriptLabel.text = "\(text)\n↵"
        } else {
            transcriptLabel.text = text
        }
        transcriptLabel.textColor = text.isEmpty ? .secondaryLabel : .label
        insertButton.isEnabled = !text.isEmpty
        insertButton.configuration?.title = pendingTranscripts.count > 1 ? "Insert \(pendingTranscripts.count)" : "Insert"
    }

    private func autoInsertIfNeeded() {
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
        insert(pendingTranscripts, markInserted: true)
    }

    @objc private func refreshButtonTapped() {
        refreshTranscript()
        autoInsertIfNeeded()
    }

    private func pendingText(from transcripts: [SharedTranscript]) -> String {
        transcripts
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
