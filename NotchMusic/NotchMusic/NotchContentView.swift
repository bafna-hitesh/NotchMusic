import SwiftUI
import AppKit

class ClickThroughView: NSView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        return true
    }
}

struct FirstMouseAcceptingView: NSViewRepresentable {
    func makeNSView(context: Context) -> ClickThroughView {
        let view = ClickThroughView()
        return view
    }
    
    func updateNSView(_ nsView: ClickThroughView, context: Context) {}
}

final class NotchStateController: ObservableObject {
    static let shared = NotchStateController()
    @Published var isExpanded = false
    
    private init() {}
    
    func toggle() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
            isExpanded.toggle()
        }
    }
    
    func expand() {
        if !isExpanded {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                isExpanded = true
            }
        }
    }
    
    func collapse() {
        if isExpanded {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                isExpanded = false
            }
        }
    }
}

struct NotchContentView: View {
    @ObservedObject private var spotify = SpotifyController.shared
    @StateObject private var notchState = NotchStateController.shared
    @State private var isHovering = false
    
    private var currentWidth: CGFloat {
        notchState.isExpanded ? NotchConstants.expandedWidth : NotchConstants.collapsedWidth
    }
    
    private var currentHeight: CGFloat {
        notchState.isExpanded ? NotchConstants.expandedHeight : NotchConstants.collapsedHeight
    }
    
    var body: some View {
        notchBody
            .frame(width: currentWidth, height: currentHeight)
            .scaleEffect(isHovering && !notchState.isExpanded ? 1.02 : 1.0, anchor: .top)
            .shadow(color: isHovering && !notchState.isExpanded ? .black.opacity(0.3) : .clear, radius: 8, x: 0, y: 4)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: notchState.isExpanded)
            .animation(.spring(response: 0.2, dampingFraction: 0.7), value: isHovering)
            .onHover { hovering in
                isHovering = hovering
                if !hovering && notchState.isExpanded {
                    notchState.collapse()
                }
            }
            .onTapGesture {
                notchState.expand()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .onAppear {
                MusicBarsAnimationController.shared.isAnimating = spotify.isPlaying
            }
            .onChange(of: spotify.isPlaying) { newValue in
                MusicBarsAnimationController.shared.isAnimating = newValue
            }
    }
    
    private var notchBody: some View {
        ZStack {
            FirstMouseAcceptingView()
                .clipShape(NotchShape(expandProgress: notchState.isExpanded ? 1 : 0))
            
            NotchShape(expandProgress: notchState.isExpanded ? 1 : 0)
                .fill(.black)
            
            if notchState.isExpanded {
                expandedContent
                    .transition(.opacity.animation(.easeOut(duration: 0.15)))
            } else {
                collapsedContent
                    .transition(.opacity.animation(.easeOut(duration: 0.1)))
            }
        }
    }
    
    private var collapsedContent: some View {
        HStack(spacing: 0) {
            albumArtMini
                .padding(.leading, 22)
            
            Spacer()
            
            MusicBarsView(barCount: 3, spacing: 2, color: spotify.dominantColor ?? .white.opacity(0.8))
                .frame(width: 14, height: 10)
                .padding(.trailing, 22)
        }
        .padding(.top, 2)
    }
    
    @ViewBuilder
    private var albumArtMini: some View {
        if let image = spotify.artworkImage {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 22, height: 22)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        } else {
            defaultMiniArt
        }
    }
    
    private var defaultMiniArt: some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(
                LinearGradient(
                    colors: spotify.isPlaying
                        ? [Color(red: 0.3, green: 0.3, blue: 0.35), Color(red: 0.2, green: 0.2, blue: 0.25)]
                        : [Color(white: 0.15), Color(white: 0.1)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .frame(width: 22, height: 22)
            .overlay(
                Image(systemName: "music.note")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
            )
    }
    
    private var expandedContent: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                albumArtLarge
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(spotify.trackName.isEmpty ? "Not Playing" : spotify.trackName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    
                    Text(spotify.artistName.isEmpty ? "Play something on Spotify" : spotify.artistName)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
                    
                    if !spotify.albumName.isEmpty {
                        Text(spotify.albumName)
                            .font(.system(size: 10, weight: .regular))
                            .foregroundStyle(.white.opacity(0.3))
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 24)
            .padding(.top, 14)
            
            Spacer()
            
            playbackControls
                .padding(.bottom, 14)
        }
    }
    
    @ViewBuilder
    private var albumArtLarge: some View {
        if let image = spotify.artworkImage {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 58, height: 58)
                .overlay(largeOverlay)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        } else {
            defaultLargeArt
        }
    }
    
    private var largeOverlay: some View {
        Group {
            if spotify.isPlaying {
                ZStack {
                    Color.black.opacity(0.3)
                    MusicBarsView(barCount: 4, spacing: 2, color: spotify.dominantColor ?? .white.opacity(0.8))
                        .frame(width: 18, height: 16)
                }
            }
        }
    }
    
    private var defaultLargeArt: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(
                LinearGradient(
                    colors: spotify.isPlaying
                        ? [Color(red: 0.4, green: 0.25, blue: 0.7), Color(red: 0.25, green: 0.35, blue: 0.8)]
                        : [Color(white: 0.12), Color(white: 0.08)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .frame(width: 58, height: 58)
            .overlay(
                Group {
                    if spotify.isPlaying {
                        MusicBarsView(barCount: 4, spacing: 2, color: spotify.dominantColor ?? .white.opacity(0.8))
                            .frame(width: 18, height: 16)
                    } else {
                        Image(systemName: "music.note")
                            .font(.system(size: 20, weight: .light))
                            .foregroundStyle(.white.opacity(0.3))
                    }
                }
            )
    }
    
    private var playbackControls: some View {
        HStack(spacing: 32) {
            ControlButton(systemName: "backward.fill", size: 14) {
                spotify.previous()
            }
            
            ControlButton(systemName: spotify.isPlaying ? "pause.fill" : "play.fill", size: 20, isPrimary: true) {
                spotify.playPause()
            }
            
            ControlButton(systemName: "forward.fill", size: 14) {
                spotify.next()
            }
        }
    }
}

struct NotchShape: Shape {
    var expandProgress: CGFloat
    
    var animatableData: CGFloat {
        get { expandProgress }
        set { expandProgress = newValue }
    }
    
    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        
        let flare: CGFloat = 12
        let collapsedBottomRadius: CGFloat = 14
        let expandedBottomRadius: CGFloat = 24
        let bottomRadius = collapsedBottomRadius + (expandedBottomRadius - collapsedBottomRadius) * expandProgress
        
        var path = Path()
        
        // Start at top-left tip
        path.move(to: CGPoint(x: 0, y: 0))
        
        // Left flare (concave)
        path.addCurve(
            to: CGPoint(x: flare, y: flare),
            control1: CGPoint(x: flare * 0.4, y: 0),
            control2: CGPoint(x: flare, y: flare * 0.4)
        )
        
        // Left vertical edge
        path.addLine(to: CGPoint(x: flare, y: h - bottomRadius))
        
        // Bottom-left corner (convex)
        path.addQuadCurve(
            to: CGPoint(x: flare + bottomRadius, y: h),
            control: CGPoint(x: flare, y: h)
        )
        
        // Bottom edge
        path.addLine(to: CGPoint(x: w - flare - bottomRadius, y: h))
        
        // Bottom-right corner (convex)
        path.addQuadCurve(
            to: CGPoint(x: w - flare, y: h - bottomRadius),
            control: CGPoint(x: w - flare, y: h)
        )
        
        // Right vertical edge
        path.addLine(to: CGPoint(x: w - flare, y: flare))
        
        // Right flare (concave)
        path.addCurve(
            to: CGPoint(x: w, y: 0),
            control1: CGPoint(x: w - flare, y: flare * 0.4),
            control2: CGPoint(x: w - flare * 0.4, y: 0)
        )
        
        // Top edge
        path.addLine(to: CGPoint(x: 0, y: 0))
        
        path.closeSubpath()
        
        return path
    }
}

final class MusicBarsAnimationController: ObservableObject {
    static let shared = MusicBarsAnimationController()
    
    @Published private(set) var heights: [CGFloat] = [0.2, 0.2, 0.2, 0.2]
    @Published var isAnimating: Bool = false {
        didSet {
            if isAnimating != oldValue {
                if isAnimating {
                    startTimer()
                } else {
                    stopTimer()
                }
            }
        }
    }
    
    private var timer: Timer?
    private var spotifyObserver: Any?
    
    private init() {
        spotifyObserver = NotificationCenter.default.addObserver(
            forName: .spotifyRunningStateChanged,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let isRunning = notification.userInfo?["isRunning"] as? Bool ?? false
            if !isRunning {
                self?.isAnimating = false
            }
        }
    }
    
    deinit {
        stopTimer()
        if let observer = spotifyObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }
    
    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.heights = (0..<4).map { _ in CGFloat.random(in: 0.2...1.0) }
        }
    }
    
    private func stopTimer() {
        timer?.invalidate()
        timer = nil
        heights = [0.2, 0.2, 0.2, 0.2]
    }
}

struct MusicBarsView: View {
    var barCount: Int = 3
    var spacing: CGFloat = 2
    var color: Color = .white.opacity(0.8)
    
    @ObservedObject private var animationController = MusicBarsAnimationController.shared
    
    var body: some View {
        HStack(spacing: spacing) {
            ForEach(0..<barCount, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1)
                    .fill(color)
                    .frame(width: 2.5)
                    .scaleEffect(y: animationController.isAnimating ? animationController.heights[safe: index] ?? 0.2 : 0.2, anchor: .bottom)
                    .animation(.easeInOut(duration: 0.2), value: animationController.heights)
            }
        }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        return indices.contains(index) ? self[index] : nil
    }
}

struct ControlButton: View {
    let systemName: String
    let size: CGFloat
    var isPrimary: Bool = false
    let action: () -> Void
    
    @GestureState private var isPressed = false
    
    var body: some View {
        ZStack {
            if isPrimary {
                Circle()
                    .fill(.white.opacity(0.1))
                    .frame(width: 40, height: 40)
            }
            
            Image(systemName: systemName)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(isPrimary ? .white : .white.opacity(0.6))
        }
        .scaleEffect(isPressed ? 0.9 : 1.0)
        .animation(.easeOut(duration: 0.08), value: isPressed)
        .gesture(
            DragGesture(minimumDistance: 0)
                .updating($isPressed) { _, state, _ in
                    state = true
                }
                .onEnded { _ in
                    action()
                }
        )
    }
}

#Preview {
    ZStack {
        Color(red: 0.25, green: 0.4, blue: 0.55)
        NotchContentView()
    }
    .frame(width: 450, height: 200)
}
