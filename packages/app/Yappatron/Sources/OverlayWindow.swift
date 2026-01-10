import SwiftUI
import AppKit

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
    @Published var orbStyle: OrbStyle = .particleCloud

    enum StatusType: Equatable {
        case idle
        case initializing
        case downloading(Double)
        case listening
        case speaking
        case error(String)
    }

    enum OrbStyle: String, CaseIterable {
        case meshGradient = "Mesh Gradient"
        case concentricRings = "Concentric Rings"
        case particleCloud = "Particle Cloud"
        case sliceRotate = "Slice & Rotate"
        case voronoi = "Voronoi Cells"
        case layeredGradients = "Layered Gradients (Original)"
    }
}

struct OverlayView: View {
    @ObservedObject var viewModel: OverlayViewModel

    var body: some View {
        ZStack {
            // Dynamic orb based on selected style
            Group {
                switch viewModel.orbStyle {
                case .meshGradient:
                    if #available(macOS 15.0, *) {
                        MeshGradientOrbView(colors: orbColors, speed: orbSpeed)
                    } else {
                        ParticleCloudOrbView(colors: orbColors, speed: orbSpeed)
                    }
                case .concentricRings:
                    ConcentricRingsOrbView(colors: orbColors, speed: orbSpeed)
                case .particleCloud:
                    ParticleCloudOrbView(colors: orbColors, speed: orbSpeed)
                case .sliceRotate:
                    SliceRotateOrbView(colors: orbColors, speed: orbSpeed)
                case .voronoi:
                    VoronoiOrbView(colors: orbColors, speed: orbSpeed)
                case .layeredGradients:
                    LayeredGradientsOrbView(colors: orbColors, speed: orbSpeed)
                }
            }
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
        .animation(.easeInOut(duration: 0.2), value: viewModel.orbStyle)
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
            // Dim RGB when idle
            return [
                Color(red: 0.3, green: 0.3, blue: 0.5),
                Color(red: 0.4, green: 0.3, blue: 0.4),
                Color(red: 0.3, green: 0.4, blue: 0.4)
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

// MARK: - Orb View Implementations

// 1. MESH GRADIENT ORB - Liquid metal flowing (requires macOS 15+)
@available(macOS 15.0, *)
struct MeshGradientOrbView: View {
    let colors: [Color]
    let speed: Double

    var body: some View {
        TimelineView(.animation) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            let phase = time * speed * 0.3

            // Pre-calculate animated points to help compiler
            let p00 = SIMD2<Float>(0, 0)
            let p10 = SIMD2<Float>(Float(0.5 + sin(phase) * 0.1), 0)
            let p20 = SIMD2<Float>(1, 0)

            let p01 = SIMD2<Float>(0, Float(0.5 + cos(phase * 1.3) * 0.1))
            let p11 = SIMD2<Float>(Float(0.5 + sin(phase * 1.7) * 0.15), Float(0.5 + cos(phase * 1.5) * 0.15))
            let p21 = SIMD2<Float>(1, Float(0.5 + sin(phase * 1.1) * 0.1))

            let p02 = SIMD2<Float>(0, 1)
            let p12 = SIMD2<Float>(Float(0.5 + cos(phase * 1.4) * 0.1), 1)
            let p22 = SIMD2<Float>(1, 1)

            let meshPoints: [SIMD2<Float>] = [
                p00, p10, p20,
                p01, p11, p21,
                p02, p12, p22
            ]

            let meshColors: [Color] = [
                colors[0], colors[1], colors[2],
                colors[3], colors[4 % colors.count], colors[0],
                colors[1], colors[2], colors[3]
            ]

            Circle()
                .fill(
                    MeshGradient(
                        width: 3,
                        height: 3,
                        points: meshPoints,
                        colors: meshColors
                    )
                )
                .clipShape(Circle())
                .blur(radius: 3)
        }
    }
}

// 2. CONCENTRIC RINGS ORB - Radar/sound waves
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

// 3. PARTICLE CLOUD ORB - Galaxy/nebula
struct ParticleCloudOrbView: View {
    let colors: [Color]
    let speed: Double

    var body: some View {
        TimelineView(.animation) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate

            ZStack {
                // Background glow
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [colors.first?.opacity(0.4) ?? .clear, .clear],
                            center: .center,
                            startRadius: 10,
                            endRadius: 40
                        )
                    )

                // Floating particles
                ForEach(0..<40, id: \.self) { index in
                    let angle = Double(index) * 137.5 // Golden angle
                    let radius = Double(index % 7) * 5.0
                    let phase = time * speed * 0.5 + Double(index) * 0.1

                    let x = cos(angle + phase) * (radius + sin(phase * 2) * 3)
                    let y = sin(angle + phase) * (radius + cos(phase * 2) * 3)

                    // Depth effect: particles closer to center are brighter/larger
                    let depth = 1.0 - (radius / 35.0)
                    let size = 2.0 + depth * 2.0

                    Circle()
                        .fill(colors[index % colors.count])
                        .frame(width: size, height: size)
                        .offset(x: x, y: y)
                        .opacity(depth * 0.9)
                }
            }
            .frame(width: 80, height: 80)
            .clipShape(Circle())
        }
    }
}

// 4. SLICE & ROTATE ORB - Kaleidoscope
struct SliceRotateOrbView: View {
    let colors: [Color]
    let speed: Double

    var body: some View {
        TimelineView(.animation) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            let sliceCount = 12

            ZStack {
                ForEach(0..<sliceCount, id: \.self) { index in
                    let baseAngle = Angle(degrees: Double(index) * 360.0 / Double(sliceCount))
                    let rotationOffset = Angle(degrees: time * speed * 30 * (index % 2 == 0 ? 1 : -1))
                    let pulse = sin(time * speed * 2 + Double(index) * 0.5) * 0.1 + 1.0

                    PieSlice(startAngle: baseAngle, endAngle: baseAngle + .degrees(360.0 / Double(sliceCount)))
                        .fill(colors[index % colors.count])
                        .rotationEffect(rotationOffset)
                        .scaleEffect(pulse)
                        .opacity(0.8)
                }
            }
            .clipShape(Circle())
            .blur(radius: 2)
        }
    }
}

// 5. VORONOI CELLS ORB - Organic cells
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

// 6. LAYERED GRADIENTS ORB - Original implementation
struct LayeredGradientsOrbView: View {
    let colors: [Color]
    let speed: Double

    var body: some View {
        TimelineView(.animation) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate

            ZStack {
                // Layer 1: Slow rotating radial gradient (base glow)
                Circle()
                    .fill(
                        RadialGradient(
                            colors: colors + [colors.first?.opacity(0.5) ?? .clear],
                            center: .center,
                            startRadius: 5,
                            endRadius: 50
                        )
                    )
                    .rotationEffect(.degrees(time * 8 * speed))
                    .opacity(0.7)

                // Layer 2: Counter-rotating radial gradient (shimmer)
                Circle()
                    .fill(
                        RadialGradient(
                            colors: (colors.reversed() + [colors.last?.opacity(0.3) ?? .clear]),
                            center: .center,
                            startRadius: 10,
                            endRadius: 40
                        )
                    )
                    .rotationEffect(.degrees(-time * 5 * speed))
                    .opacity(0.5)

                // Layer 3: Very slow angular gradient for color shifts
                Circle()
                    .fill(
                        AngularGradient(
                            colors: colors + [colors.first ?? .clear],
                            center: .center
                        )
                    )
                    .rotationEffect(.degrees(time * 3 * speed))
                    .opacity(0.3)
            }
            .clipShape(Circle())
            .blur(radius: 8)
        }
    }
}

// Helper shape for pie slices
struct PieSlice: Shape {
    let startAngle: Angle
    let endAngle: Angle

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        path.move(to: center)
        path.addArc(
            center: center,
            radius: rect.width / 2,
            startAngle: startAngle,
            endAngle: endAngle,
            clockwise: false
        )
        path.closeSubpath()
        return path
    }
}
