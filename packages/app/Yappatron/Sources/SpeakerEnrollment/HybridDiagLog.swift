import Foundation

/// Append-only diagnostic log for the hybrid diarization layer. Writes to
/// ~/Library/Application Support/Yappatron/hybrid-diag.log so we can inspect
/// what override decisions are being made without needing Console.app.
final class HybridDiagLog: @unchecked Sendable {
    static let shared = HybridDiagLog()

    private let queue = DispatchQueue(label: "hybrid-diag-log")
    private let url: URL = {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        let dir = appSupport.appendingPathComponent("Yappatron", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("hybrid-diag.log")
    }()

    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    func write(_ message: String) {
        let line = "[\(formatter.string(from: Date()))] \(message)\n"
        queue.async { [url] in
            if let data = line.data(using: .utf8) {
                if FileManager.default.fileExists(atPath: url.path) {
                    if let handle = try? FileHandle(forWritingTo: url) {
                        handle.seekToEndOfFile()
                        handle.write(data)
                        try? handle.close()
                    }
                } else {
                    try? data.write(to: url, options: .atomic)
                }
            }
        }
    }
}
