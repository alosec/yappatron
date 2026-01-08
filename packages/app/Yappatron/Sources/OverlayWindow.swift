import SwiftUI
import AppKit

class OverlayWindow: NSWindow {
    var overlayViewModel = OverlayViewModel()
    
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 60),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        
        // Window properties
        self.isOpaque = false
        self.backgroundColor = .clear
        self.level = .floating
        self.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        self.isMovableByWindowBackground = true
        self.hasShadow = false
        
        let contentView = OverlayContentView(viewModel: overlayViewModel)
        self.contentView = NSHostingView(rootView: contentView)
        
        positionAtBottom()
    }
    
    func positionAtBottom() {
        guard let screen = NSScreen.main else { return }
        
        let screenFrame = screen.visibleFrame
        let windowWidth: CGFloat = 460
        let windowHeight: CGFloat = 60
        let bottomPadding: CGFloat = 40
        
        let x = screenFrame.midX - windowWidth / 2
        let y = screenFrame.minY + bottomPadding
        
        self.setFrame(NSRect(x: x, y: y, width: windowWidth, height: windowHeight), display: true)
    }
    
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    
    func updateText(pending: String, sent: String) {
        DispatchQueue.main.async { [weak self] in
            self?.overlayViewModel.pendingText = pending
            self?.overlayViewModel.sentText = sent
        }
    }
}

class OverlayWindowController: NSWindowController {
    init(window: OverlayWindow?) {
        super.init(window: window)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

class OverlayViewModel: ObservableObject {
    @Published var pendingText: String = ""
    @Published var sentText: String = ""
    @Published var isSpeaking: Bool = false
}

struct OverlayContentView: View {
    @ObservedObject var viewModel: OverlayViewModel
    @State private var isVisible: Bool = false
    @State private var cursorOpacity: Double = 1.0
    
    var body: some View {
        HStack(spacing: 10) {
            // Mic indicator
            Image(systemName: viewModel.isSpeaking ? "waveform" : "mic.fill")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 32, height: 32)
                .background(
                    Circle()
                        .fill(.white.opacity(0.1))
                )
                .symbolEffect(.variableColor.iterative.dimInactiveLayers, isActive: viewModel.isSpeaking)
                .padding(.leading, 4)
            
            // Text area
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 0) {
                        if !viewModel.sentText.isEmpty {
                            Text(viewModel.sentText)
                                .foregroundStyle(.white.opacity(0.35))
                        }
                        
                        Text(viewModel.pendingText)
                            .foregroundStyle(.white)
                            .id("end")
                        
                        // Cursor
                        if !viewModel.pendingText.isEmpty || !viewModel.sentText.isEmpty {
                            RoundedRectangle(cornerRadius: 1)
                                .fill(.white.opacity(cursorOpacity))
                                .frame(width: 2, height: 16)
                                .padding(.leading, 2)
                                .onAppear {
                                    withAnimation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true)) {
                                        cursorOpacity = 0.3
                                    }
                                }
                        }
                    }
                    .font(.system(size: 14, weight: .medium))
                }
                .onChange(of: viewModel.pendingText) { _, _ in
                    withAnimation(.easeOut(duration: 0.1)) {
                        proxy.scrollTo("end", anchor: .trailing)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            
            // Count badge
            if !viewModel.pendingText.isEmpty {
                Text("\(viewModel.pendingText.count)")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(.white.opacity(0.1)))
                    .padding(.trailing, 4)
            }
        }
        .frame(height: 42)
        .background(glassBackground)
        .clipShape(Capsule())
        .shadow(color: .black.opacity(0.25), radius: 20, y: 8)
        .padding(.horizontal, 12)
        .opacity(isVisible ? 1 : 0)
        .scaleEffect(isVisible ? 1 : 0.9)
        .animation(.spring(response: 0.35, dampingFraction: 0.7), value: isVisible)
        .onAppear {
            isVisible = true
        }
    }
    
    var glassBackground: some View {
        ZStack {
            // Primary glass blur
            Capsule()
                .fill(.ultraThinMaterial)
            
            // Very subtle dark wash for legibility 
            Capsule()
                .fill(Color.black.opacity(0.25))
            
            // Top edge highlight (light refraction)
            Capsule()
                .stroke(
                    LinearGradient(
                        colors: [.white.opacity(0.4), .white.opacity(0.1), .clear],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 0.5
                )
                .blur(radius: 0.5)
        }
    }
}
