import SwiftUI
import UIKit
import WebKit

final class KeyboardViewController: UIInputViewController {
    private let transcriptStore = SharedTranscriptStore.shared
    private let localDefaults = UserDefaults.standard

    private let transcriptLabel = UILabel()
    private let insertButton = UIButton(type: .system)
    private let startButtonContainer = UIView()
    private let micButton = UIButton(type: .system)
    private let historyButton = UIButton(type: .system)
    private let undoButton = UIButton(type: .system)
    private let spaceButton = UIButton(type: .system)
    private let returnButton = UIButton(type: .system)
    private let deleteButton = UIButton(type: .system)
    private let appLaunchWebView = WKWebView(frame: .zero)
    private var startLinkController: UIHostingController<KeyboardStartLinkView>?

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
    private var transientStatusText: String?
    private var transientStatusExpiresAt: Date?

    private let keyboardBackgroundColor = UIColor(red: 0.09, green: 0.09, blue: 0.10, alpha: 1)
    private let activeTextColor = UIColor(white: 0.94, alpha: 1)
    private let secondaryTextColor = UIColor(white: 0.64, alpha: 1)

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
        view.backgroundColor = keyboardBackgroundColor
        view.layoutMargins = UIEdgeInsets(top: 6, left: 6, bottom: 6, right: 6)
        appLaunchWebView.isHidden = true
        appLaunchWebView.isOpaque = false
        appLaunchWebView.backgroundColor = .clear

        transcriptLabel.font = .preferredFont(forTextStyle: .footnote)
        transcriptLabel.numberOfLines = 1
        transcriptLabel.lineBreakMode = .byTruncatingTail
        transcriptLabel.textColor = activeTextColor
        transcriptLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        micButton.configuration = .filled()
        micButton.configuration?.image = UIImage(systemName: "mic.fill")
        micButton.configuration?.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 8)
        micButton.configuration?.imagePadding = 5
        micButton.configuration?.title = "Start"
        micButton.titleLabel?.adjustsFontSizeToFitWidth = true
        micButton.titleLabel?.minimumScaleFactor = 0.75
        micButton.addTarget(self, action: #selector(micButtonTapped), for: .touchUpInside)
        micButton.accessibilityLabel = "Start dictation"

        configureStartLink()

        historyButton.configuration = .tinted()
        historyButton.configuration?.image = UIImage(systemName: "clock.arrow.circlepath")
        historyButton.configuration?.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 5, bottom: 6, trailing: 5)
        historyButton.addTarget(self, action: #selector(historyButtonTapped), for: .touchUpInside)
        historyButton.accessibilityLabel = "Transcript history"

        insertButton.configuration = .filled()
        insertButton.configuration?.image = UIImage(systemName: "checkmark")
        insertButton.configuration?.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 5, bottom: 6, trailing: 5)
        insertButton.addTarget(self, action: #selector(insertButtonTapped), for: .touchUpInside)
        insertButton.accessibilityLabel = "Finish dictation"

        undoButton.configuration = .plain()
        undoButton.configuration?.image = UIImage(systemName: "arrow.uturn.backward")
        undoButton.configuration?.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 4, bottom: 6, trailing: 4)
        undoButton.addTarget(self, action: #selector(undoButtonTapped), for: .touchUpInside)
        undoButton.accessibilityLabel = "Undo"

        spaceButton.configuration = .plain()
        spaceButton.configuration?.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 4, bottom: 6, trailing: 4)
        spaceButton.configuration?.title = "_"
        spaceButton.titleLabel?.adjustsFontSizeToFitWidth = true
        spaceButton.titleLabel?.minimumScaleFactor = 0.75
        spaceButton.addTarget(self, action: #selector(spaceButtonTapped), for: .touchUpInside)
        spaceButton.accessibilityLabel = "Space"

        returnButton.configuration = .plain()
        returnButton.configuration?.image = UIImage(systemName: "return")
        returnButton.configuration?.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 4, bottom: 6, trailing: 4)
        returnButton.addTarget(self, action: #selector(returnButtonTapped), for: .touchUpInside)
        returnButton.accessibilityLabel = "Return"

        deleteButton.configuration = .plain()
        deleteButton.configuration?.image = UIImage(systemName: "delete.left")
        deleteButton.configuration?.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 4, bottom: 6, trailing: 4)
        deleteButton.addTarget(self, action: #selector(deleteButtonTapped), for: .touchUpInside)
        deleteButton.accessibilityLabel = "Delete"

        let buttonRow = UIStackView(arrangedSubviews: [
            startButtonContainer,
            historyButton,
            insertButton,
            undoButton,
            spaceButton,
            returnButton,
            deleteButton
        ])
        buttonRow.axis = .horizontal
        buttonRow.alignment = .fill
        buttonRow.distribution = .fill
        buttonRow.spacing = 4

        startButtonContainer.widthAnchor.constraint(equalToConstant: 80).isActive = true
        historyButton.widthAnchor.constraint(equalToConstant: 32).isActive = true
        insertButton.widthAnchor.constraint(equalToConstant: 34).isActive = true
        undoButton.widthAnchor.constraint(equalToConstant: 30).isActive = true
        spaceButton.widthAnchor.constraint(equalToConstant: 44).isActive = true
        returnButton.widthAnchor.constraint(equalToConstant: 30).isActive = true
        deleteButton.widthAnchor.constraint(equalToConstant: 30).isActive = true
        buttonRow.heightAnchor.constraint(equalToConstant: 38).isActive = true

        let stack = UIStackView(arrangedSubviews: [transcriptLabel, buttonRow])
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(stack)
        view.addSubview(appLaunchWebView)
        appLaunchWebView.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: view.layoutMarginsGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: view.layoutMarginsGuide.bottomAnchor),
            appLaunchWebView.widthAnchor.constraint(equalToConstant: 1),
            appLaunchWebView.heightAnchor.constraint(equalToConstant: 1),
            appLaunchWebView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            appLaunchWebView.topAnchor.constraint(equalTo: view.topAnchor),
            view.heightAnchor.constraint(greaterThanOrEqualToConstant: 92)
        ])
    }

    private func configureStartLink() {
        guard let url = URL(string: "yappatron://dictation/start") else {
            return
        }

        let linkController = UIHostingController(
            rootView: KeyboardStartLinkView(url: url) { [weak self] in
                self?.prepareStartDictationRequest()
            }
        )
        startLinkController = linkController
        addChild(linkController)
        linkController.view.backgroundColor = .clear
        linkController.view.translatesAutoresizingMaskIntoConstraints = false
        startButtonContainer.addSubview(linkController.view)

        micButton.translatesAutoresizingMaskIntoConstraints = false
        startButtonContainer.addSubview(micButton)

        NSLayoutConstraint.activate([
            linkController.view.leadingAnchor.constraint(equalTo: startButtonContainer.leadingAnchor),
            linkController.view.trailingAnchor.constraint(equalTo: startButtonContainer.trailingAnchor),
            linkController.view.topAnchor.constraint(equalTo: startButtonContainer.topAnchor),
            linkController.view.bottomAnchor.constraint(equalTo: startButtonContainer.bottomAnchor),
            micButton.leadingAnchor.constraint(equalTo: startButtonContainer.leadingAnchor),
            micButton.trailingAnchor.constraint(equalTo: startButtonContainer.trailingAnchor),
            micButton.topAnchor.constraint(equalTo: startButtonContainer.topAnchor),
            micButton.bottomAnchor.constraint(equalTo: startButtonContainer.bottomAnchor)
        ])
        linkController.didMove(toParent: self)
    }

    private func refreshTranscript() {
        dictationState = transcriptStore.latestDictationStateForKeyboard()
        let lastInsertedAt = localDefaults.double(forKey: LocalKeys.lastInsertedUpdatedAt)
        pendingTranscripts = transcriptStore.keyboardTranscripts(after: lastInsertedAt)
        let hadStreamedLiveText = !lastStreamedLiveTranscript.isEmpty
        streamLiveTranscriptIfNeeded()
        if dictationState.isRecording {
            clearTransientStatus()
            reconcilePendingTranscriptsDuringRecording()
        } else if hadStreamedLiveText {
            consumePendingTranscriptsCoveredByLiveText()
        }

        let text = showingHistory
            ? pendingText(from: pendingTranscripts)
            : dictationState.liveTranscript.trimmingCharacters(in: .whitespacesAndNewlines)

        if let statusText = activeTransientStatusText() {
            transcriptLabel.text = statusText
        } else if !hasFullAccess {
            transcriptLabel.text = "Enable Full Access for live dictation"
        } else if text.isEmpty {
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
        transcriptLabel.textColor = text.isEmpty || !hasFullAccess ? secondaryTextColor : activeTextColor
        micButton.configuration?.title = dictationState.isRecording ? "Rec" : "Start"
        micButton.configuration?.image = UIImage(systemName: dictationState.isRecording ? "waveform" : "mic.fill")
        micButton.isEnabled = false
        micButton.isHidden = !dictationState.isRecording
        startLinkController?.view.isHidden = dictationState.isRecording
        insertButton.isEnabled = dictationState.isRecording || !pendingTranscripts.isEmpty || !text.isEmpty
        historyButton.isEnabled = hasFullAccess
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
        prepareStartDictationRequest()
        guard let url = URL(string: "yappatron://dictation/start") else {
            return
        }

        extensionContext?.open(url) { [weak self] success in
            DispatchQueue.main.async {
                if success {
                    self?.showTransientStatus("Swipe back after Yappatron opens")
                } else {
                    self?.showTransientStatus("Start Yappatron, then return")
                }
            }
        }
    }

    private func prepareStartDictationRequest() {
        showTransientStatus(hasFullAccess ? "Opening Yappatron" : "Enable Full Access, then open Yappatron")
        transcriptStore.saveKeyboardCommand("start")
        guard let url = URL(string: "yappatron://dictation/start") else {
            return
        }

        _ = openURLThroughResponderChain(url)
        openURLThroughWebView(url)
    }

    private func openURLThroughWebView(_ url: URL) {
        let escapedURL = url.absoluteString
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        let html = """
        <html>
        <head>
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <meta http-equiv="refresh" content="0; url=\(escapedURL)">
        <script>window.location.href = "\(escapedURL)";</script>
        </head>
        <body></body>
        </html>
        """
        appLaunchWebView.loadHTMLString(html, baseURL: nil)
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

    private func reconcilePendingTranscriptsDuringRecording() {
        guard !pendingTranscripts.isEmpty else {
            return
        }

        for transcript in pendingTranscripts {
            let text = transcript.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                markPendingTranscriptsInserted(upTo: transcript.updatedAt)
                continue
            }

            if liveTextCovers(text) {
                markPendingTranscriptsInserted(upTo: transcript.updatedAt)
                continue
            }

            let insertion = missingSuffix(from: text, after: lastStreamedLiveTranscript)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !insertion.isEmpty else {
                markPendingTranscriptsInserted(upTo: transcript.updatedAt)
                continue
            }

            if !lastStreamedLiveTranscript.isEmpty {
                textDocumentProxy.insertText(" ")
            }
            textDocumentProxy.insertText(insertion)
            lastStreamedLiveTranscript = mergedTranscript(lastStreamedLiveTranscript, with: text)
            localDefaults.set(lastStreamedLiveTranscript, forKey: LocalKeys.lastStreamedLiveTranscript)
            markPendingTranscriptsInserted(upTo: transcript.updatedAt)
        }
    }

    private func consumePendingTranscriptsCoveredByLiveText() {
        for transcript in pendingTranscripts where liveTextCovers(transcript.text) {
            markPendingTranscriptsInserted(upTo: transcript.updatedAt)
        }
    }

    private func markPendingTranscriptsInserted(upTo updatedAt: TimeInterval) {
        let lastInsertedAt = localDefaults.double(forKey: LocalKeys.lastInsertedUpdatedAt)
        if updatedAt > lastInsertedAt {
            localDefaults.set(updatedAt, forKey: LocalKeys.lastInsertedUpdatedAt)
        }
        pendingTranscripts.removeAll { $0.updatedAt <= updatedAt }
    }

    private func liveTextCovers(_ text: String) -> Bool {
        let streamed = normalized(lastStreamedLiveTranscript)
        let candidate = normalized(text)
        guard !streamed.isEmpty, !candidate.isEmpty else {
            return false
        }
        return streamed.contains(candidate)
    }

    private func missingSuffix(from text: String, after base: String) -> String {
        let candidate = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = base.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty, !base.isEmpty else {
            return candidate
        }

        let overlap = suffixPrefixOverlap(base, candidate)
        guard overlap > 0 else {
            return candidate
        }

        let index = candidate.index(candidate.startIndex, offsetBy: overlap)
        return String(candidate[index...])
    }

    private func mergedTranscript(_ base: String, with next: String) -> String {
        let base = base.trimmingCharacters(in: .whitespacesAndNewlines)
        let next = next.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { return next }
        guard !next.isEmpty else { return base }

        let overlap = suffixPrefixOverlap(base, next)
        if overlap > 0 {
            let index = next.index(next.startIndex, offsetBy: overlap)
            let suffix = next[index...].trimmingCharacters(in: .whitespacesAndNewlines)
            return suffix.isEmpty ? base : "\(base) \(suffix)"
        }

        return "\(base) \(next)"
    }

    private func suffixPrefixOverlap(_ lhs: String, _ rhs: String) -> Int {
        let lhs = lhs.lowercased()
        let rhs = rhs.lowercased()
        let maxLength = min(lhs.count, rhs.count)
        guard maxLength > 0 else { return 0 }

        for length in stride(from: maxLength, through: 1, by: -1) {
            let lhsStart = lhs.index(lhs.endIndex, offsetBy: -length)
            let rhsEnd = rhs.index(rhs.startIndex, offsetBy: length)
            if lhs[lhsStart...] == rhs[..<rhsEnd] {
                return length
            }
        }

        return 0
    }

    private func normalized(_ text: String) -> String {
        text
            .lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func showTransientStatus(_ text: String) {
        transientStatusText = text
        transientStatusExpiresAt = Date().addingTimeInterval(4)
        transcriptLabel.text = text
        transcriptLabel.textColor = secondaryTextColor
    }

    private func clearTransientStatus() {
        transientStatusText = nil
        transientStatusExpiresAt = nil
    }

    private func activeTransientStatusText() -> String? {
        guard let transientStatusText,
              let transientStatusExpiresAt else {
            return nil
        }

        if transientStatusExpiresAt > Date() {
            return transientStatusText
        }

        self.transientStatusText = nil
        self.transientStatusExpiresAt = nil
        return nil
    }

    private func openURLThroughResponderChain(_ url: URL) -> Bool {
        let selector = NSSelectorFromString("openURL:")
        var responder: UIResponder? = self

        while let current = responder {
            if current.responds(to: selector) {
                _ = current.perform(selector, with: url)
                return true
            }
            responder = current.next
        }

        return false
    }
}

private struct KeyboardStartLinkView: View {
    let url: URL
    let onTap: () -> Void

    var body: some View {
        Link(destination: url) {
            HStack(spacing: 5) {
                Image(systemName: "mic.fill")
                    .font(.caption.weight(.semibold))
                Text("Start")
                    .font(.footnote.weight(.semibold))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .foregroundStyle(.white)
            .background(Color.accentColor)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .simultaneousGesture(TapGesture().onEnded { onTap() })
        .accessibilityLabel("Start dictation")
    }
}
