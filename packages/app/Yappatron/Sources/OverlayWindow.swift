import SwiftUI
import AppKit

/// Minimal overlay - just a status indicator, not text display
class OverlayWindow: NSWindow {
    
    let overlayViewModel = OverlayViewModel()

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    
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
        let screen = Self.activeScreen()
        let screenFrame = screen.visibleFrame

        switch overlayViewModel.orbStyle {
        case .bottomLine:
            hasShadow = false
            setFrame(
                NSRect(x: screenFrame.minX, y: screenFrame.minY + 3, width: screenFrame.width, height: 8),
                display: true
            )
        case .voronoi, .concentricRings:
            hasShadow = true
            let size = NSSize(width: 100, height: 100)
            let origin = NSPoint(x: screenFrame.midX - size.width / 2, y: screenFrame.minY + 80)
            setFrame(NSRect(origin: origin, size: size), display: true)
        }
    }

    private static func activeScreen() -> NSScreen {
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouseLocation) } ?? NSScreen.main ?? NSScreen.screens[0]
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
    @Published var orbStyle: OrbStyle = .voronoi

    enum StatusType: Equatable {
        case idle // Paused or push-to-talk idle
        case initializing
        case downloading(Double)
        case listening
        case speaking
        case error(String)
    }

    enum OrbStyle: String, CaseIterable {
        case voronoi = "Voronoi Cells"
        case concentricRings = "Concentric Rings"
        case bottomLine = "Bottom Line"
    }
}

struct OverlayView: View {
    @ObservedObject var viewModel: OverlayViewModel

    var body: some View {
        Group {
            switch viewModel.orbStyle {
            case .voronoi:
                VoronoiOrbView(colors: orbColors, speed: orbSpeed)
                    .frame(width: 80, height: 80)
            case .concentricRings:
                ConcentricRingsOrbView(colors: orbColors, speed: orbSpeed)
                    .frame(width: 80, height: 80)
            case .bottomLine:
                BottomLineIndicatorView(colors: orbColors, speed: orbSpeed)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .opacity(orbOpacity)
        .animation(.easeInOut(duration: 0.3), value: viewModel.isSpeaking)
        .animation(.easeInOut(duration: 0.3), value: viewModel.status)
        .animation(.easeInOut(duration: 0.2), value: viewModel.orbStyle)
    }

    // Orb colors based on state
    private var orbColors: [Color] {
        switch viewModel.status {
        case .speaking:
            // Vibrant RGB shifting palette when speaking
            return [
                Color(red: 1.0, green: 0.0, blue: 0.3),  // Red-pink
                Color(red: 0.3, green: 0.0, blue: 1.0),  // Blue-purple
                Color(red: 0.0, green: 1.0, blue: 0.5),  // Green-cyan
                Color(red: 1.0, green: 0.2, blue: 0.0),  // Red-orange
                Color(red: 0.0, green: 0.5, blue: 1.0)   // Blue
            ]
        case .listening:
            // Subtle green glow when listening
            return [
                Color(red: 0.0, green: 1.0, blue: 0.4),
                Color(red: 0.0, green: 0.8, blue: 0.6),
                Color(red: 0.2, green: 1.0, blue: 0.5)
            ]
        case .idle:
            // Dim neutral glow when paused or waiting for push-to-talk
            return [
                Color(red: 0.28, green: 0.32, blue: 0.36),
                Color(red: 0.38, green: 0.36, blue: 0.42),
                Color(red: 0.24, green: 0.38, blue: 0.42)
            ]
        case .error:
            // Red warning
            return [
                Color(red: 1.0, green: 0.0, blue: 0.0),
                Color(red: 0.8, green: 0.0, blue: 0.2),
                Color(red: 1.0, green: 0.2, blue: 0.0)
            ]
        case .initializing, .downloading:
            // Orange/amber loading
            return [
                Color(red: 1.0, green: 0.6, blue: 0.0),
                Color(red: 1.0, green: 0.4, blue: 0.2),
                Color(red: 1.0, green: 0.5, blue: 0.0)
            ]
        }
    }

    private var orbSpeed: Double {
        switch viewModel.status {
        case .speaking: return 1.5
        case .listening: return 1.0
        case .idle: return 0.5
        case .error: return 2.0
        case .initializing, .downloading: return 1.2
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

// BOTTOM LINE INDICATOR - quiet active-display strip
struct BottomLineIndicatorView: View {
    let colors: [Color]
    let speed: Double

    var body: some View {
        TimelineView(.animation) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            let phase = (sin(time * speed * 2.2) + 1) / 2

            Capsule()
                .fill(
                    LinearGradient(
                        colors: colors.map { $0.opacity(0.65 + phase * 0.35) },
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(height: 5)
                .shadow(color: colors.first?.opacity(0.7) ?? .green.opacity(0.7), radius: 8, x: 0, y: 0)
                .padding(.horizontal, 18)
        }
    }
}

// MARK: - Orb View Implementations

// CONCENTRIC RINGS ORB - Radar/sound waves
struct ConcentricRingsOrbView: View {
    let colors: [Color]
    let speed: Double

    var body: some View {
        TimelineView(.animation) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate

            ZStack {
                ForEach(0..<7, id: \.self) { index in
                    let phase = time * speed * 2.0 - Double(index) * 0.3
                    let scale = 0.3 + (sin(phase) * 0.5 + 0.5) * 0.7
                    let opacity = (cos(phase) * 0.5 + 0.5) * 0.8

                    Circle()
                        .stroke(colors[index % colors.count], lineWidth: 3)
                        .scaleEffect(scale)
                        .opacity(opacity)
                }
            }
            .clipShape(Circle())
        }
    }
}

// MARK: - Focus Lock Outline

class FocusLockOverlayWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        level = .statusBar
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        contentView = NSHostingView(rootView: FocusLockOutlineView())
    }

    func show(frame: NSRect) {
        setFrame(frame, display: true)
        orderFrontRegardless()
    }
}

class FocusLockOverlayWindowController: NSWindowController {
    convenience init(window: FocusLockOverlayWindow) {
        self.init(window: window as NSWindow)
    }
}

struct FocusLockOutlineView: View {
    var body: some View {
        TimelineView(.animation) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            let pulse = (sin(time * 3.0) + 1) / 2

            RoundedRectangle(cornerRadius: 8)
                .stroke(
                    LinearGradient(
                        colors: [
                            Color(red: 0.0, green: 1.0, blue: 0.48),
                            Color(red: 0.0, green: 0.76, blue: 1.0)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 3
                )
                .shadow(color: Color(red: 0.0, green: 1.0, blue: 0.55).opacity(0.45 + pulse * 0.25), radius: 10, x: 0, y: 0)
                .padding(3)
        }
    }
}

// VORONOI CELLS ORB - Organic cells (DEFAULT)
struct VoronoiOrbView: View {
    let colors: [Color]
    let speed: Double

    var body: some View {
        TimelineView(.animation) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate

            // Simplified Voronoi: overlay multiple radial gradients from moving points
            ZStack {
                ForEach(0..<8, id: \.self) { index in
                    let angle = Double(index) * 45.0 + time * speed * 10
                    let radius = 20 + sin(time * speed + Double(index)) * 10

                    let x = cos(angle * .pi / 180) * radius
                    let y = sin(angle * .pi / 180) * radius

                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [colors[index % colors.count], colors[index % colors.count].opacity(0)],
                                center: .center,
                                startRadius: 0,
                                endRadius: 30
                            )
                        )
                        .offset(x: x, y: y)
                        .blendMode(.screen)
                }
            }
            .frame(width: 80, height: 80)
            .clipShape(Circle())
            .drawingGroup()
        }
    }
}
