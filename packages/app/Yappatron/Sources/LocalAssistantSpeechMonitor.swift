import Darwin
import Foundation

/// Detects local TTS commands whose speaker output would otherwise be captured
/// by Yappatron's microphone and sent back through STT.
enum LocalAssistantSpeechMonitor {
    private static let assistantSpeechProcessNames: Set<String> = ["sag"]

    static func isAssistantSpeechProcessRunning() -> Bool {
        assistantSpeechProcessNames.contains { isProcessRunning(named: $0) }
    }

    /// Stops SAG and any direct playback descendants. Returns true when a
    /// running local assistant-speech process was found and signalled.
    static func interruptAssistantSpeechIfRunning() -> Bool {
        let allPIDs = processIDs()
        let sagPIDs = Set(allPIDs.filter { pid in
            guard let name = processName(for: pid) else { return false }
            return assistantSpeechProcessNames.contains(name)
        })
        guard !sagPIDs.isEmpty else { return false }

        var descendants = Set<pid_t>()
        var parents = sagPIDs
        while !parents.isEmpty {
            let children = Set(allPIDs.filter { pid in
                guard !sagPIDs.contains(pid), !descendants.contains(pid),
                      let parent = parentPID(for: pid) else {
                    return false
                }
                return parents.contains(parent)
            })
            guard !children.isEmpty else { break }
            descendants.formUnion(children)
            parents = children
        }

        var signalled = false
        for pid in descendants {
            if kill(pid, SIGTERM) == 0 {
                signalled = true
            }
        }
        for pid in sagPIDs {
            if kill(pid, SIGTERM) == 0 {
                signalled = true
            }
        }
        return signalled
    }

    static func isProcessRunning(named targetName: String) -> Bool {
        processIDs().contains { processName(for: $0) == targetName }
    }

    private static func processIDs() -> [pid_t] {
        let requiredBytes = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard requiredBytes > 0 else { return [] }

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
        guard bytesWritten > 0 else { return [] }

        let pidCount = min(Int(bytesWritten) / MemoryLayout<pid_t>.stride, pids.count)
        return Array(pids.prefix(pidCount).filter { $0 > 0 })
    }

    private static func processName(for pid: pid_t) -> String? {
        var name = [CChar](repeating: 0, count: 256)
        guard proc_name(pid, &name, UInt32(name.count)) > 0 else { return nil }
        return String(cString: name)
    }

    private static func parentPID(for pid: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let actualSize = proc_pidinfo(
            pid,
            PROC_PIDTBSDINFO,
            0,
            &info,
            Int32(MemoryLayout<proc_bsdinfo>.size)
        )
        guard actualSize == MemoryLayout<proc_bsdinfo>.size else { return nil }
        return pid_t(info.pbi_ppid)
    }
}
