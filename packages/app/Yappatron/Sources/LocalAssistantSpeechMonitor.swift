import Darwin
import Foundation

/// Detects local TTS commands whose speaker output would otherwise be captured
/// by Yappatron's microphone and sent back through STT.
enum LocalAssistantSpeechMonitor {
    private static let assistantSpeechProcessNames: Set<String> = ["sag"]

    static func isAssistantSpeechProcessRunning() -> Bool {
        assistantSpeechProcessNames.contains { isProcessRunning(named: $0) }
    }

    static func isProcessRunning(named targetName: String) -> Bool {
        let requiredBytes = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard requiredBytes > 0 else { return false }

        let pidCapacity = Int(requiredBytes) / MemoryLayout<pid_t>.stride + 32
        var pids = [pid_t](repeating: 0, count: pidCapacity)
        let bytesWritten = pids.withUnsafeMutableBytes { buffer in
            proc_listpids(
                UInt32(PROC_ALL_PIDS),
                0,
                buffer.baseAddress,
                Int32(buffer.count)
            )
        }
        guard bytesWritten > 0 else { return false }

        let pidCount = min(Int(bytesWritten) / MemoryLayout<pid_t>.stride, pids.count)
        for pid in pids.prefix(pidCount) where pid > 0 {
            var processName = [CChar](repeating: 0, count: 256)
            guard proc_name(pid, &processName, UInt32(processName.count)) > 0 else {
                continue
            }
            if String(cString: processName) == targetName {
                return true
            }
        }

        return false
    }
}
