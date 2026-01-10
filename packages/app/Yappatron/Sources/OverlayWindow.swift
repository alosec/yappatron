import SwiftUI
import AppKit
import Orb

/// Minimal overlay - just a status indicator, not text display
class OverlayWindow: NSWindow {
    
    let overlayViewModel = OverlayViewModel()
    
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
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
            // Use the Orb library for beautiful animated orb
            OrbView(configuration: orbConfiguration)
                .frame(width: 80, height: 80)
                .opacity(orbOpacity)

            // Status indicator overlay (for non-speaking states)
            if !viewModel.isSpeaking {
                statusIcon
                    .font(.system(size: 24))
                    .foregroundStyle(statusColor)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: viewModel.isSpeaking)
        .animation(.easeInOut(duration: 0.3), value: viewModel.status)
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
            EmptyView() // Orb speaks for itself
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

    // Orb configuration based on state
    private var orbConfiguration: OrbConfiguration {
        switch viewModel.status {
        case .speaking:
            // Vibrant RGB shifting palette when speaking
            return OrbConfiguration(
                backgroundColors: [
                    Color(red: 1.0, green: 0.0, blue: 0.3),  // Red-pink
                    Color(red: 0.3, green: 0.0, blue: 1.0),  // Blue-purple
                    Color(red: 0.0, green: 1.0, blue: 0.5),  // Green-cyan
                    Color(red: 1.0, green: 0.2, blue: 0.0),  // Red-orange
                    Color(red: 0.0, green: 0.5, blue: 1.0)   // Blue
                ],
                glowColor: .white,
                coreGlowIntensity: 1.2,
                speed: 60
            )
        case .listening:
            // Subtle green glow when listening
            return OrbConfiguration(
                backgroundColors: [
                    Color(red: 0.0, green: 1.0, blue: 0.4),
                    Color(red: 0.0, green: 0.8, blue: 0.6),
                    Color(red: 0.2, green: 1.0, blue: 0.5)
                ],
                glowColor: .green,
                coreGlowIntensity: 0.8,
                speed: 40
            )
        case .idle:
            // Dim RGB when idle
            return OrbConfiguration(
                backgroundColors: [
                    Color(red: 0.3, green: 0.3, blue: 0.5),
                    Color(red: 0.4, green: 0.3, blue: 0.4),
                    Color(red: 0.3, green: 0.4, blue: 0.4)
                ],
                glowColor: .white,
                coreGlowIntensity: 0.3,
                speed: 20
            )
        case .error:
            // Red warning
            return OrbConfiguration(
                backgroundColors: [
                    Color(red: 1.0, green: 0.0, blue: 0.0),
                    Color(red: 0.8, green: 0.0, blue: 0.2),
                    Color(red: 1.0, green: 0.2, blue: 0.0)
                ],
                glowColor: .red,
                coreGlowIntensity: 1.5,
                speed: 80
            )
        case .initializing, .downloading:
            // Orange/amber loading
            return OrbConfiguration(
                backgroundColors: [
                    Color(red: 1.0, green: 0.6, blue: 0.0),
                    Color(red: 1.0, green: 0.4, blue: 0.2),
                    Color(red: 1.0, green: 0.5, blue: 0.0)
                ],
                glowColor: .orange,
                coreGlowIntensity: 1.0,
                speed: 50
            )
        }
    }

    private var orbOpacity: Double {
        switch viewModel.status {
        case .speaking: return 1.0
        case .listening: return 0.7
        case .idle: return 0.3
        case .error: return 0.9
        case .initializing, .downloading: return 0.6
        }
    }
}
