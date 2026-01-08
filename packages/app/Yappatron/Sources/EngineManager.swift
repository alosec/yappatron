import Foundation

/// Manages the Python engine subprocess
class EngineManager: ObservableObject {
    static let shared = EngineManager()
    
    enum Status: Equatable {
        case stopped
        case starting
        case running
        case error(String)
    }
    
    @Published var status: Status = .stopped
    
    private var engineProcess: Process?
    private var outputPipe: Pipe?
    private var logFileHandle: FileHandle?
    
    private let projectDir: String
    private let venvDir: String
    private let logDir: String
    
    private init() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        self.projectDir = "\(home)/Workspace/yappatron"
        self.venvDir = "\(projectDir)/.venv"
        self.logDir = "\(home)/.yappatron"
        
        // Create log directory
        try? FileManager.default.createDirectory(atPath: logDir, withIntermediateDirectories: true)
    }
    
    /// Start the Python engine
    func start(model: WhisperModel = .small) {
        guard status != .running && status != .starting else { return }
        
        status = .starting
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.launchEngine(model: model)
        }
    }
    
    private func launchEngine(model: WhisperModel) {
        let process = Process()
        
        // Use bash to source venv and run
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [
            "-c",
            "source '\(venvDir)/bin/activate' && PYTHONUNBUFFERED=1 yappatron --no-speaker-id --model \(model.rawValue)"
        ]
        
        // Set up output capture
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        
        // Log to file
        let logPath = "\(logDir)/engine.log"
        FileManager.default.createFile(atPath: logPath, contents: nil)
        logFileHandle = FileHandle(forWritingAtPath: logPath)
        
        // Handle output
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if !data.isEmpty {
                self?.logFileHandle?.write(data)
                
                // Check for ready signal
                if let text = String(data: data, encoding: .utf8) {
                    if text.contains("Listening...") {
                        DispatchQueue.main.async {
                            self?.status = .running
                        }
                    }
                }
            }
        }
        
        // Handle termination
        process.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                if proc.terminationStatus != 0 && self?.status == .running {
                    self?.status = .error("Engine crashed (exit \(proc.terminationStatus))")
                } else {
                    self?.status = .stopped
                }
            }
        }
        
        do {
            try process.run()
            engineProcess = process
            outputPipe = pipe
            
            // Wait a bit for startup
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
                if self?.status == .starting {
                    self?.status = .running
                }
            }
        } catch {
            DispatchQueue.main.async { [weak self] in
                self?.status = .error("Failed to start: \(error.localizedDescription)")
            }
        }
    }
    
    /// Stop the Python engine
    func stop() {
        engineProcess?.terminate()
        engineProcess = nil
        outputPipe = nil
        logFileHandle?.closeFile()
        logFileHandle = nil
        status = .stopped
    }
    
    /// Restart with a new model
    func restart(model: WhisperModel) {
        stop()
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.start(model: model)
        }
    }
    
    deinit {
        stop()
    }
}
