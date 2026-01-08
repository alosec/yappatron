import SwiftUI
import AppKit

/// Minimal overlay - just a status indicator, not text display
class OverlayWindow: NSWindow {
    
    let overlayViewModel = OverlayViewModel()
    
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 60, height: 60),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        
        self.level = .floating
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = true
        self.ignoresMouseEvents = true
        self.collectionBehavior = [.canJoinAllSpaces, .stationary]
        
        let hostingView = NSHostingView(rootView: OverlayView(viewModel: overlayViewModel))
        self.contentView = hostingView
        
        positionAtBottom()
    }
    
    func positionAtBottom() {
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        let x = screenFrame.midX - frame.width / 2
        let y = screenFrame.minY + 80
        setFrameOrigin(NSPoint(x: x, y: y))
    }
}

class OverlayWindowController: NSWindowController {
    convenience init(window: OverlayWindow) {
        self.init(window: window as NSWindow)
    }
}

class OverlayViewModel: ObservableObject {
    @Published var isListening = false
    @Published var isSpeaking = false
    @Published var status: StatusType = .idle
    
    enum StatusType: Equatable {
        case idle
        case initializing
        case downloading(Double)
        case listening
        case speaking
        case error(String)
    }
}

struct OverlayView: View {
    @ObservedObject var viewModel: OverlayViewModel
    
    var body: some View {
        ZStack {
            // Background circle
            Circle()
                .fill(.ultraThinMaterial)
                .frame(width: 50, height: 50)
            
            // Status indicator
            statusIcon
                .font(.system(size: 24))
                .foregroundStyle(statusColor)
        }
        .animation(.easeInOut(duration: 0.2), value: viewModel.isSpeaking)
        .animation(.easeInOut(duration: 0.2), value: viewModel.status)
    }
    
    @ViewBuilder
    private var statusIcon: some View {
        switch viewModel.status {
        case .idle:
            Image(systemName: "waveform")
                .opacity(0.5)
        case .initializing:
            ProgressView()
                .scaleEffect(0.8)
        case .downloading(let progress):
            ZStack {
                Circle()
                    .stroke(lineWidth: 3)
                    .opacity(0.3)
                    .frame(width: 30, height: 30)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .frame(width: 30, height: 30)
                    .rotationEffect(.degrees(-90))
            }
        case .listening:
            Image(systemName: "waveform")
        case .speaking:
            Image(systemName: "waveform.circle.fill")
                .symbolEffect(.pulse, isActive: true)
        case .error:
            Image(systemName: "exclamationmark.triangle.fill")
        }
    }
    
    private var statusColor: Color {
        switch viewModel.status {
        case .idle: return .secondary
        case .initializing, .downloading: return .orange
        case .listening: return .green
        case .speaking: return .blue
        case .error: return .red
        }
    }
}
