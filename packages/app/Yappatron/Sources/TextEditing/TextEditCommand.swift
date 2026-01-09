import Foundation

/// Represents an abstract text editing operation
protocol TextEditCommand {
    /// Execute this command using the provided input simulator
    func execute(via simulator: InputSimulator) throws

    /// Estimated duration in nanoseconds
    var estimatedDuration: UInt64 { get }
}

// MARK: - Navigation Commands

/// Navigate cursor to a specific position
struct NavigateCommand: TextEditCommand {
    enum Position {
        case home                      // Cmd+Left or Home
        case end                       // Cmd+Right or End
        case lineStart                 // Ctrl+A (Emacs binding)
        case lineEnd                   // Ctrl+E (Emacs binding)
        case wordForward               // Option+Right
        case wordBackward              // Option+Left
        case characterForward(Int)     // Right arrow (n times)
        case characterBackward(Int)    // Left arrow (n times)
    }

    let to: Position
    var estimatedDuration: UInt64 { 10_000_000 } // 10ms

    func execute(via simulator: InputSimulator) throws {
        try simulator.navigate(to: to)
    }
}

// MARK: - Selection Commands

/// Select text range
struct SelectCommand: TextEditCommand {
    enum Range {
        case characters(count: Int, direction: Direction)
        case words(count: Int, direction: Direction)
        case toLineStart
        case toLineEnd
        case all                       // Cmd+A
    }

    enum Direction {
        case forward, backward
    }

    let range: Range
    var estimatedDuration: UInt64 { 15_000_000 } // 15ms

    func execute(via simulator: InputSimulator) throws {
        try simulator.select(range: range)
    }
}

// MARK: - Type Command

/// Type text (replaces selection if active)
struct TypeCommand: TextEditCommand {
    let text: String
    var estimatedDuration: UInt64 {
        UInt64(text.count) * 2_000_000 // 2ms per character
    }

    func execute(via simulator: InputSimulator) throws {
        simulator.typeString(text)
    }
}

// MARK: - Delete Command

/// Delete selection or characters
struct DeleteCommand: TextEditCommand {
    enum Target {
        case selection              // Delete current selection
        case backward(count: Int)   // Backspace n times
        case forward(count: Int)    // Forward delete n times
    }

    let target: Target
    var estimatedDuration: UInt64 { 10_000_000 } // 10ms

    func execute(via simulator: InputSimulator) throws {
        try simulator.delete(target: target)
    }
}

// MARK: - High-Level Commands

/// High-level replace operation (select + type)
struct ReplaceCommand: TextEditCommand {
    let navigation: NavigateCommand  // Move to position
    let selection: SelectCommand     // Select range
    let replacement: String          // New text

    var estimatedDuration: UInt64 {
        navigation.estimatedDuration +
        selection.estimatedDuration +
        UInt64(replacement.count) * 2_000_000
    }

    func execute(via simulator: InputSimulator) throws {
        try navigation.execute(via: simulator)
        try selection.execute(via: simulator)
        simulator.typeString(replacement)
    }
}

/// Insert at specific position
struct InsertCommand: TextEditCommand {
    let navigation: NavigateCommand
    let text: String

    var estimatedDuration: UInt64 {
        navigation.estimatedDuration + UInt64(text.count) * 2_000_000
    }

    func execute(via simulator: InputSimulator) throws {
        try navigation.execute(via: simulator)
        simulator.typeString(text)
    }
}

/// Compound command (execute multiple in sequence)
struct CompoundCommand: TextEditCommand {
    let commands: [TextEditCommand]

    var estimatedDuration: UInt64 {
        commands.reduce(0) { $0 + $1.estimatedDuration }
    }

    func execute(via simulator: InputSimulator) throws {
        for command in commands {
            try command.execute(via: simulator)
        }
    }
}
