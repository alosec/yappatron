import Foundation
import SwiftUI

let arguments = Array(CommandLine.arguments.dropFirst())

if DeepgramLatencyBenchmarkCommand.shouldRun(arguments: arguments) {
    Task {
        let exitCode = await DeepgramLatencyBenchmarkCommand.run(arguments: arguments)
        exit(Int32(exitCode))
    }
    RunLoop.main.run()
} else {
    YappatronApp.main()
}
