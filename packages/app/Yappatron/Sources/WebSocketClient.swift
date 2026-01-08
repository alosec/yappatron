import Foundation
import Starscream

class WebSocketClient: WebSocketDelegate {
    private var socket: WebSocket?
    private let url = URL(string: "ws://localhost:9876")!
    private var isConnected = false
    private var reconnectTimer: Timer?
    
    // Callbacks - simplified
    var onText: ((String) -> Void)?  // Transcribed text to display/type
    var onSpeechStart: (() -> Void)?
    var onSpeechEnd: (() -> Void)?
    var onConnected: (() -> Void)?
    var onDisconnected: (() -> Void)?
    
    init() {}
    
    func connect() {
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        
        socket = WebSocket(request: request)
        socket?.delegate = self
        socket?.connect()
    }
    
    func disconnect() {
        reconnectTimer?.invalidate()
        reconnectTimer = nil
        socket?.disconnect()
        socket = nil
        isConnected = false
    }
    
    private func scheduleReconnect() {
        reconnectTimer?.invalidate()
        reconnectTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { [weak self] _ in
            print("[WebSocket] Attempting to reconnect...")
            self?.connect()
        }
    }
    
    // MARK: - Send Messages
    
    func sendPause() {
        send(["type": "pause"])
    }
    
    func sendResume() {
        send(["type": "resume"])
    }
    
    /// Send audio chunk to engine for processing
    func sendAudioChunk(_ samples: [Float]) {
        guard isConnected else { return }
        
        // Convert float array to base64 for efficient transmission
        let data = samples.withUnsafeBytes { Data($0) }
        let base64 = data.base64EncodedString()
        
        send(["type": "audio", "data": base64, "samples": samples.count])
    }
    
    private func send(_ dict: [String: Any]) {
        guard isConnected else { return }
        
        if let data = try? JSONSerialization.data(withJSONObject: dict),
           let string = String(data: data, encoding: .utf8) {
            socket?.write(string: string)
        }
    }
    
    // MARK: - WebSocketDelegate
    
    func didReceive(event: WebSocketEvent, client: WebSocketClient) {
        // This delegate method signature is different in newer Starscream
    }
    
    func didReceive(event: Starscream.WebSocketEvent, client: Starscream.WebSocketClient) {
        switch event {
        case .connected(_):
            isConnected = true
            onConnected?()
            
        case .disconnected(let reason, let code):
            isConnected = false
            print("WebSocket disconnected: \(reason) (code: \(code))")
            onDisconnected?()
            scheduleReconnect()
            
        case .text(let text):
            handleMessage(text)
            
        case .binary(let data):
            if let text = String(data: data, encoding: .utf8) {
                handleMessage(text)
            }
            
        case .error(let error):
            print("WebSocket error: \(String(describing: error))")
            isConnected = false
            scheduleReconnect()
            
        case .cancelled:
            isConnected = false
            print("WebSocket cancelled")
            scheduleReconnect()
            
        default:
            break
        }
    }
    
    private func handleMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else {
            return
        }
        
        switch type {
        case "text":
            if let textContent = json["text"] as? String {
                onText?(textContent)
            }
            
        case "speech_start":
            onSpeechStart?()
            
        case "speech_end":
            onSpeechEnd?()
            
        case "status":
            if let status = json["status"] as? String {
                print("Status: \(status)")
            }
            
        default:
            break
        }
    }
}
