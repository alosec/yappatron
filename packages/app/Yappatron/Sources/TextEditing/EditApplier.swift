import Foundation

/// Executes text edit commands safely with error handling
@MainActor
class EditApplier {

    private let simulator: InputSimulator
    private var isApplying = false
    private var commandQueue: [TextEditCommand] = []

    // Version tracking to detect stale edits
    private var currentTextVersion: Int = 0

    init(simulator: InputSimulator) {
        self.simulator = simulator
    }

    /// Apply a sequence of edit commands
    func apply(_ commands: [TextEditCommand], version: Int) async {
        guard !commands.isEmpty else { return }

        // Check if this edit is stale
        guard version >= currentTextVersion else {
            log("[EditApplier] Skipping stale edit (version \(version) < \(currentTextVersion))")
            return
        }

        currentTextVersion = version

        // Queue commands
        commandQueue.append(contentsOf: commands)

        // Process queue if not already processing
        guard !isApplying else { return }

        await processQueue()
    }

    private func processQueue() async {
        isApplying = true
        defer { isApplying = false }

        while !commandQueue.isEmpty {
            let command = commandQueue.removeFirst()

            do {
                // Check if input is still focused
                guard InputSimulator.isTextInputFocused() else {
                    log("[EditApplier] Text input lost focus, clearing queue")
                    commandQueue.removeAll()
                    break
                }

                // Execute command
                try command.execute(via: simulator)

                // Small delay for reliability
                try await Task.sleep(nanoseconds: 2_000_000) // 2ms

            } catch {
                log("[EditApplier] Command execution failed: \(error.localizedDescription)")
                // Continue with next command
            }
        }
    }

    /// Clear pending commands (e.g., when user starts typing)
    func clearQueue() {
        commandQueue.removeAll()
    }

    /// Increment version (called when new text arrives)
    func incrementVersion() {
        currentTextVersion += 1
    }
}
