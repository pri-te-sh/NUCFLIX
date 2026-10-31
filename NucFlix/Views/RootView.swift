import SwiftUI
import AVFoundation

struct RootView: View {
    @Environment(AppState.self) var appState
    @Environment(CloudAccount.self) var cloud
    /// Netflix-style animated intro, shown once per cold launch
    @State private var showSplash = true

    /// Changes whenever the session should (re)start: account, person profile, or the line's login.
    private var sessionKey: String {
        [cloud.uid ?? "", cloud.selectedProfileID ?? "", cloud.activeLine.map { "\($0.id)|\($0.hashValue)" } ?? ""]
            .joined(separator: "#")
    }

    var body: some View {
        ZStack {
            Group {
                switch screen {
                case .loading:
                    Color.black.ignoresSafeArea()
                case .signIn:
                    CloudAuthView()
                case .whoIsWatching:
                    ProfilePickerView()
                case .firstLine:
                    LineFormView(isFirstLine: true) { cloud.selectLine($0.id) }
                case .connecting:
                    ConnectingView()
                case .main:
                    MainTabView()
                }
            }
            .transition(.opacity)
            .animation(.easeInOut(duration: 0.35), value: screen)

            if showSplash {
                NucFlixSplashView {
                    withAnimation(.easeOut(duration: 0.45)) {
                        showSplash = false
                    }
                }
                .transition(.opacity)
                .zIndex(1)
            }
        }
        .preferredColorScheme(.dark)
        .task(id: sessionKey) {
            guard let uid = cloud.uid, let profile = cloud.selectedProfile, let line = cloud.activeLine else {
                if cloud.phase == .signedOut || cloud.selectedProfileID == nil, appState.activeProfileID != nil || appState.credentials != nil {
                    appState.signOut()
                }
                return
            }
            await appState.activate(line: line, profile: profile, uid: uid)
        }
        .onChange(of: cloud.selectedProfile) { _, profile in
            // Settings changed on another device (e.g. the TV) apply here right away.
            if let profile, appState.activeProfileID == profile.id { appState.applyProfilePrefs(profile) }
        }
        .fullScreenCover(item: Bindable(appState).activePlayback) { item in
            IPTVPlayerView(item: item) {
                appState.activePlayback = nil
                appState.flushCloudProgress()
            }
            .environment(appState)
            .environment(cloud)
        }
    }

    private enum Screen: Equatable {
        case loading, signIn, whoIsWatching, firstLine, connecting, main
    }

    private var screen: Screen {
        switch cloud.phase {
        case .starting: return .loading
        case .signedOut: return .signIn
        case .signedIn:
            guard cloud.profilesLoaded, cloud.linesLoaded else { return .loading }
            guard let profile = cloud.selectedProfile else { return .whoIsWatching }
            guard cloud.activeLine != nil else { return .firstLine }
            if appState.credentials != nil, appState.activeProfileID == profile.id { return .main }
            return .connecting
        }
    }
}

/// Shown while the chosen line logs in to the provider (or if it can't).
struct ConnectingView: View {
    @Environment(AppState.self) var appState
    @Environment(CloudAccount.self) var cloud
    @State private var showLines = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 18) {
                if let profile = cloud.selectedProfile {
                    ProfileAvatar(profile: profile, size: 84)
                }
                if let error = appState.authError, !appState.isAuthenticating {
                    Text("Couldn't connect to \(cloud.activeLine?.name ?? "your IPTV line")")
                        .font(.headline)
                        .foregroundStyle(.white)
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.65))
                        .multilineTextAlignment(.center)
                    HStack(spacing: 12) {
                        Button("Try Again") {
                            guard let uid = cloud.uid, let profile = cloud.selectedProfile, let line = cloud.activeLine else { return }
                            Task { await appState.activate(line: line, profile: profile, uid: uid) }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(AppTheme.netflixRed)
                        Button("IPTV Lines") { showLines = true }
                            .buttonStyle(.bordered)
                            .tint(.white)
                    }
                    Button("Switch Profile") { cloud.selectProfile(nil) }
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.6))
                } else {
                    ProgressView().tint(.white)
                    Text("Connecting to \(cloud.activeLine?.name ?? "your IPTV line")…")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
            .padding(30)
        }
        .sheet(isPresented: $showLines) {
            LinesView().environment(cloud).environment(appState)
        }
    }
}

// MARK: - Netflix-Style Animated Splash ("N" ribbon reveal → ta-dum → zoom through the spectrum)

struct NucFlixSplashView: View {
    let onFinish: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // Ribbon build-up
    @State private var leftStem: CGFloat = 0
    @State private var diagonal: CGFloat = 0
    @State private var rightStem: CGFloat = 0
    // Ta-dum glow + zoom-through
    @State private var glow: Double = 0
    @State private var zoom: CGFloat = 1
    @State private var logoOpacity: Double = 1
    @State private var streaks: CGFloat = 0
    @State private var streakOpacity: Double = 0
    @State private var wordmarkOpacity: Double = 0

    private let logoHeight: CGFloat = 150
    private var logoWidth: CGFloat { logoHeight * 0.56 }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // Spectrum light streaks (the iconic Netflix "ribbon of colour" zoom)
            SpectrumStreaksView(progress: streaks)
                .opacity(streakOpacity)
                .blur(radius: 1.5 + (1 - streaks) * 6)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            VStack(spacing: 26) {
                ribbonLogo
                    .shadow(color: AppTheme.netflixRed.opacity(0.85 * glow), radius: 30 * glow)
                    .scaleEffect(zoom)
                    .opacity(logoOpacity)

                Text("NUCFLIX")
                    .font(.system(size: 22, weight: .black))
                    .tracking(8)
                    .foregroundStyle(AppTheme.netflixRed)
                    .opacity(wordmarkOpacity * logoOpacity)
            }
        }
        .task { await runSequence() }
        .accessibilityElement()
        .accessibilityLabel("NucFlix")
    }

    /// Three-piece folded "N": left stem rises, diagonal ribbon sweeps down, right stem rises
    private var ribbonLogo: some View {
        let stem = logoWidth * 0.34
        return ZStack(alignment: .topLeading) {
            // Left stem
            Rectangle()
                .fill(AppTheme.darkRed)
                .frame(width: stem, height: logoHeight)
                .scaleEffect(x: 1, y: leftStem, anchor: .bottom)

            // Right stem
            Rectangle()
                .fill(AppTheme.darkRed)
                .frame(width: stem, height: logoHeight)
                .scaleEffect(x: 1, y: rightStem, anchor: .bottom)
                .offset(x: logoWidth - stem)

            // Diagonal ribbon, revealed top → bottom
            DiagonalRibbonShape(stemWidth: stem)
                .fill(
                    LinearGradient(
                        colors: [Color(red: 0.98, green: 0.07, blue: 0.11), AppTheme.netflixRed],
                        startPoint: .top, endPoint: .bottom
                    )
                )
                .shadow(color: .black.opacity(0.8), radius: 6, x: 0, y: 2)
                .mask(
                    VStack(spacing: 0) {
                        Rectangle().frame(height: logoHeight * diagonal)
                        Spacer(minLength: 0)
                    }
                )
        }
        .frame(width: logoWidth, height: logoHeight)
    }

    @MainActor
    private func runSequence() async {
        if reduceMotion {
            leftStem = 1; diagonal = 1; rightStem = 1
            withAnimation(.easeIn(duration: 0.3)) { wordmarkOpacity = 1 }
            try? await Task.sleep(nanoseconds: 900_000_000)
            onFinish()
            return
        }

        TudumSoundPlayer.shared.play()

        // 1. Build the N (0.0 – 0.7s)
        withAnimation(.easeOut(duration: 0.28)) { leftStem = 1 }
        try? await Task.sleep(nanoseconds: 180_000_000)
        withAnimation(.easeInOut(duration: 0.3)) { diagonal = 1 }
        try? await Task.sleep(nanoseconds: 220_000_000)
        withAnimation(.easeOut(duration: 0.28)) { rightStem = 1 }

        // 2. "Ta-dum" glow pulses (synced with the two hits)
        try? await Task.sleep(nanoseconds: 260_000_000)
        withAnimation(.easeOut(duration: 0.12)) { glow = 1; wordmarkOpacity = 1 }
        try? await Task.sleep(nanoseconds: 140_000_000)
        withAnimation(.easeIn(duration: 0.18)) { glow = 0.35 }
        try? await Task.sleep(nanoseconds: 120_000_000)
        withAnimation(.easeOut(duration: 0.15)) { glow = 1.2 }
        try? await Task.sleep(nanoseconds: 420_000_000)

        // 3. Zoom through the N into the light spectrum
        withAnimation(.easeIn(duration: 0.75)) {
            zoom = 14
            wordmarkOpacity = 0
        }
        withAnimation(.easeOut(duration: 0.35)) { streakOpacity = 1 }
        withAnimation(.easeOut(duration: 0.9)) { streaks = 1 }
        try? await Task.sleep(nanoseconds: 380_000_000)
        withAnimation(.easeIn(duration: 0.3)) { logoOpacity = 0 }
        try? await Task.sleep(nanoseconds: 420_000_000)
        withAnimation(.easeIn(duration: 0.3)) { streakOpacity = 0 }
        try? await Task.sleep(nanoseconds: 200_000_000)

        onFinish()
    }
}

private struct DiagonalRibbonShape: Shape {
    let stemWidth: CGFloat

    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 0, y: 0))
        p.addLine(to: CGPoint(x: stemWidth * 1.02, y: 0))
        p.addLine(to: CGPoint(x: rect.width, y: rect.height))
        p.addLine(to: CGPoint(x: rect.width - stemWidth * 1.02, y: rect.height))
        p.closeSubpath()
        return p
    }
}

/// Vertical bands of colour that burst outward from the centre as the camera "flies" through the N
private struct SpectrumStreaksView: View {
    var progress: CGFloat

    private struct Band {
        let position: CGFloat   // 0...1 across the screen
        let width: CGFloat      // relative width
        let color: Color
    }

    private static let bands: [Band] = {
        let palette: [Color] = [
            Color(red: 0.90, green: 0.04, blue: 0.08), Color(red: 0.70, green: 0.03, blue: 0.06),
            Color(red: 1.00, green: 0.30, blue: 0.20), Color(red: 0.95, green: 0.10, blue: 0.45),
            Color(red: 0.55, green: 0.10, blue: 0.75), Color(red: 0.20, green: 0.35, blue: 0.95),
            Color(red: 0.10, green: 0.75, blue: 0.95), Color(red: 1.00, green: 0.75, blue: 0.10),
            Color(red: 0.98, green: 0.45, blue: 0.05), Color(red: 0.35, green: 0.85, blue: 0.40)
        ]
        var generator = SplitMix(seed: 0xC0FFEE)
        return (0..<56).map { i in
            Band(
                position: CGFloat(generator.nextUnit()),
                width: 0.004 + CGFloat(generator.nextUnit()) * 0.03,
                color: palette[(i * 7 + Int(generator.nextUnit() * 10)) % palette.count]
            )
        }
    }()

    var body: some View {
        Canvas { context, size in
            let cx = size.width / 2
            for band in Self.bands {
                // Bands start bunched at the centre and fan out to their final position
                let finalX = band.position * size.width
                let x = cx + (finalX - cx) * progress
                let w = max(1, band.width * size.width * (0.3 + progress))
                let rect = CGRect(x: x - w / 2, y: 0, width: w, height: size.height)
                context.fill(Path(rect), with: .linearGradient(
                    Gradient(colors: [band.color.opacity(0), band.color, band.color, band.color.opacity(0)]),
                    startPoint: CGPoint(x: x, y: 0),
                    endPoint: CGPoint(x: x, y: size.height)
                ))
            }
        }
    }

    private struct SplitMix {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func nextUnit() -> Double {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            z ^= z >> 31
            return Double(z % 1_000_000) / 1_000_000
        }
    }
}

// MARK: - Synthesized "Ta-dum" Intro Sound

/// Generates a short two-hit cinematic "ta-dum" in memory (no bundled audio asset).
/// Uses the `.ambient` session so it respects the silent switch and doesn't interrupt other audio.
final class TudumSoundPlayer {
    static let shared = TudumSoundPlayer()
    private var player: AVAudioPlayer?

    func play() {
        DispatchQueue.global(qos: .userInitiated).async {
            let session = AVAudioSession.sharedInstance()
            try? session.setCategory(.ambient, mode: .default, options: [.mixWithOthers])
            try? session.setActive(true)
            guard let data = Self.makeTudumWAV(),
                  let player = try? AVAudioPlayer(data: data) else { return }
            player.volume = 0.9
            player.prepareToPlay()
            player.play()
            DispatchQueue.main.async { self.player = player }
        }
    }

    private static func makeTudumWAV() -> Data? {
        let sampleRate = 44_100.0
        let duration = 2.2
        let count = Int(sampleRate * duration)
        var samples = [Float](repeating: 0, count: count)

        /// Percussive low "boom": pitch-dropping sine + short noise transient + harmonic body
        func addHit(at start: Double, baseFreq: Double, decay: Double, gain: Float) {
            let startIndex = Int(start * sampleRate)
            var phase = 0.0
            var noiseSeed: UInt32 = 12345
            for i in 0..<Int(decay * 6 * sampleRate) {
                let idx = startIndex + i
                guard idx < count else { break }
                let t = Double(i) / sampleRate
                let freq = baseFreq * (1 + 1.6 * exp(-t * 28))           // pitch drop
                phase += 2 * .pi * freq / sampleRate
                let env = exp(-t / decay) * min(1, t * 400)               // fast attack, exp decay
                noiseSeed = noiseSeed &* 1_664_525 &+ 1_013_904_223
                let noise = (Double(noiseSeed) / Double(UInt32.max) * 2 - 1) * exp(-t * 90)
                let body = sin(phase) + 0.35 * sin(phase * 2.01) + 0.15 * sin(phase * 3.03)
                samples[idx] += gain * Float(env * body * 0.6 + noise * 0.12)
            }
        }

        addHit(at: 0.70, baseFreq: 72, decay: 0.16, gain: 0.75)   // "ta"
        addHit(at: 0.96, baseFreq: 52, decay: 0.55, gain: 1.0)    // "dum"

        // Soft shimmering pad swell under the zoom
        for i in 0..<count {
            let t = Double(i) / sampleRate
            guard t > 1.0 else { continue }
            let env = sin(min((t - 1.0) / 1.2, 1) * .pi) * 0.08
            let pad = sin(2 * .pi * 220 * t) + sin(2 * .pi * 277.18 * t) + sin(2 * .pi * 329.63 * t)
            samples[i] += Float(env * pad / 3)
        }

        // Normalize & encode 16-bit PCM WAV
        let peak = samples.map { abs($0) }.max() ?? 1
        let scale: Float = peak > 0 ? 0.92 / peak : 1
        var pcm = Data(capacity: count * 2)
        for s in samples {
            var v = Int16(max(-1, min(1, s * scale)) * Float(Int16.max)).littleEndian
            withUnsafeBytes(of: &v) { pcm.append(contentsOf: $0) }
        }

        var wav = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            var v = value.littleEndian
            withUnsafeBytes(of: &v) { wav.append(contentsOf: $0) }
        }
        wav.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + pcm.count))
        wav.append(contentsOf: Array("WAVE".utf8))
        wav.append(contentsOf: Array("fmt ".utf8)); append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
        append(UInt32(sampleRate)); append(UInt32(sampleRate * 2)); append(UInt16(2)); append(UInt16(16))
        wav.append(contentsOf: Array("data".utf8)); append(UInt32(pcm.count))
        wav.append(pcm)
        return wav
    }
}
