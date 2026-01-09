import Foundation

/// Generates minimal edit sequences to transform text
actor DiffGenerator {

    /// Diff operation types
    enum DiffOp {
        case insert(position: Int, text: String)
        case delete(position: Int, length: Int)
        case replace(position: Int, length: Int, with: String)
        case noChange
    }

    /// Generate edit commands to transform original into refined
    func generateCommands(
        from original: String,
        to refined: String,
        currentCursorAtEnd: Bool = true
    ) -> [TextEditCommand] {

        // Compute character-level diff
        let diffs = computeDiff(original: original, refined: refined)

        // Convert diffs to commands
        return diffsToCommands(diffs, cursorAtEnd: currentCursorAtEnd)
    }

    /// Simple diff algorithm: finds longest common subsequence
    private func computeDiff(original: String, refined: String) -> [DiffOp] {
        let origChars = Array(original)
        let refinedChars = Array(refined)

        // Handle simple cases
        if origChars == refinedChars {
            return [.noChange]
        }

        if origChars.isEmpty {
            return [.insert(position: 0, text: refined)]
        }

        if refinedChars.isEmpty {
            return [.delete(position: 0, length: original.count)]
        }

        // Find common prefix
        let prefixLen = zip(origChars, refinedChars)
            .prefix(while: { $0 == $1 })
            .count

        // Find common suffix (from remaining text)
        let origSuffix = origChars.dropFirst(prefixLen)
        let refinedSuffix = refinedChars.dropFirst(prefixLen)

        let suffixLen = zip(origSuffix.reversed(), refinedSuffix.reversed())
            .prefix(while: { $0 == $1 })
            .count

        // Middle section differs
        let deleteLen = origChars.count - prefixLen - suffixLen
        let insertText = String(refinedChars.dropFirst(prefixLen).dropLast(suffixLen))

        if deleteLen == 0 && insertText.isEmpty {
            return [.noChange]
        } else if deleteLen == 0 {
            return [.insert(position: prefixLen, text: insertText)]
        } else if insertText.isEmpty {
            return [.delete(position: prefixLen, length: deleteLen)]
        } else {
            return [.replace(position: prefixLen, length: deleteLen, with: insertText)]
        }
    }

    /// Convert diff operations to edit commands
    private func diffsToCommands(
        _ diffs: [DiffOp],
        cursorAtEnd: Bool
    ) -> [TextEditCommand] {

        var commands: [TextEditCommand] = []

        for diff in diffs {
            switch diff {
            case .noChange:
                break

            case .insert(let position, let text):
                // Navigate to position from end
                if cursorAtEnd {
                    // Navigate home, then forward to position
                    commands.append(NavigateCommand(to: .home))
                    if position > 0 {
                        commands.append(NavigateCommand(to: .characterForward(position)))
                    }
                }
                commands.append(TypeCommand(text: text))

            case .delete(let position, let length):
                if cursorAtEnd {
                    commands.append(NavigateCommand(to: .home))
                    if position > 0 {
                        commands.append(NavigateCommand(to: .characterForward(position)))
                    }
                }
                commands.append(SelectCommand(range: .characters(count: length, direction: .forward)))
                commands.append(DeleteCommand(target: .selection))

            case .replace(let position, let length, let newText):
                if cursorAtEnd {
                    commands.append(NavigateCommand(to: .home))
                    if position > 0 {
                        commands.append(NavigateCommand(to: .characterForward(position)))
                    }
                }
                commands.append(SelectCommand(range: .characters(count: length, direction: .forward)))
                commands.append(TypeCommand(text: newText))
            }
        }

        // Return to end
        if cursorAtEnd && !commands.isEmpty {
            commands.append(NavigateCommand(to: .end))
        }

        return commands
    }
}
