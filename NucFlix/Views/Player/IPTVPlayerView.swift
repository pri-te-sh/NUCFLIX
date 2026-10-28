import SwiftUI
import AVKit
import AVFoundation
import MediaPlayer
import MobileVLCKit
import Darwin

struct IPTVPlayerView: View {
    @Environment(AppState.self) var appState
    /// Current item — mutable so series episodes can advance in place (binge autoplay)
    @State private var item: PlaybackItem
    let onClose: () -> Void

    init(item: PlaybackItem, onClose: @escaping () -> Void) {
        _item = State(initialValue: item)
        self.onClose = onClose
    }

    // Next Episode / Binge Autoplay
    @State private var nextEpisodeItem: PlaybackItem?
    @State private var dismissedNextEpisodePrompt: Bool = false
    @State private var consecutiveAutoplays: Int = 0
    @State private var showStillWatchingPrompt: Bool = false
    @State private var endOfEpisodeCountdown: Int? = nil
    @State private var endCountdownTask: Task<Void, Never>?
    private static let creditsWindowSeconds: Double = 25
    private static let maxAutoplaysBeforeCheck: Int = 3

    // Dual Playback Engines: AVPlayer (for HLS/PiP) + VLCMediaPlayer (for MKV/TS/Dolby/Multi-Sub)
    @State private var avPlayer: AVPlayer?
    @State private var vlcPlayer: VLCMediaPlayer?
    @State private var useVLCEngine: Bool = false
    @State private var pipController: AVPictureInPictureController?
    @State private var vlcDelegate = VLCPlayerDelegateBridge()

    @State private var selectedFormat: LiveStreamFormat = .hlsLive
    @State private var playerError: String?
    @State private var showEPGSheet: Bool = false
    @State private var showAudioSubtitleSheet: Bool = false

    // Playback & Netflix UI State
    @State private var isPlaying: Bool = true
    @State private var showControls: Bool = true
    @State private var isScreenLocked: Bool = false
    @State private var isZoomedToFill: Bool = false
    @State private var isAirPlayActive: Bool = false
    @State private var isExternalPlaybackActive: Bool = false
    @State private var activeAirPlayDeviceName: String? = nil
    @State private var isRemuxedCastActive: Bool = false
    @State private var remuxBaseOffsetSeconds: Double = 0
    @State private var avEngineSetupTask: Task<Void, Never>?
    @State private var externalPlaybackObservation: NSKeyValueObservation?
    @State private var routePickerCoordinator = AirPlayTriggerCoordinator()
    @State private var playbackSpeed: Float = 1.0
    @State private var brightnessLevel: CGFloat = UIScreen.main.brightness
    @State private var currentTime: Double = 0
    @State private var totalDuration: Double = 0
    @State private var isScrubbing: Bool = false
    @State private var userReaction: Int = 0

    // Embedded MKV Audio & Subtitle Tracks (from VLCMediaPlayer)
    @State private var audioTracks: [(index: Int32, name: String)] = []
    @State private var selectedAudioTrack: Int32 = -1
    @State private var subtitleTracks: [(index: Int32, name: String)] = []
    @State private var selectedSubtitleTrack: Int32 = -1

    @State private var timeObserverToken: Any?
    @State private var statusObservation: NSKeyValueObservation?
    @State private var hideControlsTask: Task<Void, Never>?

    // Buffering / stall recovery / lifecycle state
    @State private var isBuffering: Bool = false
    @State private var timeControlObservation: NSKeyValueObservation?
    @State private var itemObserverTokens: [NSObjectProtocol] = []
    @State private var stallRecoveryTask: Task<Void, Never>?
    @State private var stallRetryCount: Int = 0
    @State private var isDismissed: Bool = false
    @State private var lastSavedProgressSecond: Double = 0
    @State private var originalBrightness: CGFloat?
    @State private var remoteCommandTargets: [(command: MPRemoteCommand, token: Any)] = []

    private static let progressSaveInterval: Double = 15
    private static let maxStallRetries: Int = 3

    private var cleanTitle: String {
        XtreamTextFormatter.format(item.title).cleanTitle
    }

    private var shouldDefaultToVLC: Bool {
        if let ext = item.containerExtension?.lowercased(),
           ["mkv", "avi", "flv", "ts", "webm"].contains(ext) {
            return true
        }
        if item.contentType == .live && selectedFormat == .mpegTS {
            return true
        }
        return false
    }

    private var currentStreamURL: URL? {
        if let local = item.localFileURL, FileManager.default.fileExists(atPath: local.path) {
            return local
        }
        if let downloadedURL = DownloadManager.shared.localFileURL(for: item.id) {
            return downloadedURL
        }
        guard let creds = appState.credentials else { return nil }
        switch item.contentType {
        case .live:
            guard let streamID = item.streamID else { return nil }
            return creds.liveStreamURL(streamID: streamID, format: selectedFormat)
        case .movie:
            guard let streamID = item.streamID else { return nil }
            return creds.vodStreamURL(streamID: streamID, containerExtension: item.containerExtension)
        case .seriesEpisode:
            guard let episodeID = item.episodeID else { return nil }
            return creds.seriesEpisodeURL(episodeID: episodeID, containerExtension: item.containerExtension)
        }
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // Video Canvas (VLC Engine for MKV/TS or AVPlayer Engine for HLS/MP4)
            if useVLCEngine, let vlcPlayer {
                VLCVideoSurfaceView(player: vlcPlayer)
                    .ignoresSafeArea()
            } else if let avPlayer {
                NetflixVideoLayerView(
                    player: avPlayer,
                    isZoomedToFill: isZoomedToFill,
                    onPiPControllerReady: { controller in
                        self.pipController = controller
                    }
                )
                .ignoresSafeArea()
                .gesture(
                    MagnificationGesture()
                        .onEnded { scale in
                            guard !isScreenLocked else { return }
                            withAnimation(.easeInOut(duration: 0.2)) {
                                isZoomedToFill = scale > 1.05
                            }
                        }
                )
            }

            // Netflix TV Cast Backdrop (replaces phone video playback when casting to external TV)
            if isAirPlayActive || isExternalPlaybackActive {
                netflixTVSideCastBackdrop
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }

            // Software dimmer when dragging brightness slider low
            Color.black
                .opacity(Double(max(0, (1.0 - brightnessLevel) * 0.55)))
                .ignoresSafeArea()
                .allowsHitTesting(false)

            // Tap catcher to toggle Netflix controls
            Color.white.opacity(0.001)
                .ignoresSafeArea()
                .onTapGesture {
                    consecutiveAutoplays = 0
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showControls.toggle()
                    }
                    if showControls {
                        scheduleAutoHideControls()
                    }
                }

            // Buffering spinner (hidden while the full controls overlay is visible to avoid overlapping the play button)
            if isBuffering && playerError == nil && !(showControls && !isScreenLocked) {
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(.white)
                    .scaleEffect(1.5)
                    .allowsHitTesting(false)
            }

            // Active AirPlay / Casting Status Banner (when connected to external TV/speaker)
            if isAirPlayActive, let deviceName = activeAirPlayDeviceName {
                VStack {
                    HStack(spacing: 8) {
                        Image(systemName: "airplayvideo")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(AppTheme.netflixRed)
                        Text("Casting to \(deviceName)")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.white)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(.black.opacity(0.75), in: Capsule())
                    .overlay(Capsule().stroke(AppTheme.netflixRed.opacity(0.6), lineWidth: 0.8))
                    .padding(.top, 14)
                    Spacer()
                }
                .allowsHitTesting(false)
            }

            // Netflix Custom Controls Overlay
            if showControls {
                if isScreenLocked {
                    lockedScreenOverlay
                        .transition(.opacity)
                } else {
                    netflixControlsOverlay
                        .transition(.opacity)
                }
            }

            // Netflix "Next Episode" credits pill / end-of-episode countdown / "Still watching?"
            if !isScreenLocked && playerError == nil {
                nextEpisodeOverlay
            }

            if let playerError {
                errorOverlay(message: playerError)
            }
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .preferredColorScheme(.dark)
        .onAppear {
            isDismissed = false
            stallRetryCount = 0
            lastSavedProgressSecond = item.resumeSeconds
            originalBrightness = UIScreen.main.brightness
            ScreenAwake.set(.playback, true)
            selectedFormat = appState.preferredLiveFormat
            brightnessLevel = max(UIScreen.main.brightness, 0.45)
            configureAudioSession(triggerReloadIfNeeded: false)
            if isAirPlayActive && item.contentType == .live && selectedFormat == .mpegTS {
                selectedFormat = .hlsLive
            }
            useVLCEngine = isAirPlayActive ? false : shouldDefaultToVLC
            setupRemoteCommands()
            requestOrientation(.landscapeRight)
            if item.contentType == .live, let streamID = item.streamID {
                appState.loadEPGIfNeeded(for: streamID)
            }
            loadStream()
            scheduleAutoHideControls()
            resolveNextEpisode()
        }
        .onDisappear {
            isDismissed = true
            endCountdownTask?.cancel()
            hideControlsTask?.cancel()
            avEngineSetupTask?.cancel()
            saveCurrentProgressAndCleanup()
            AirPlayCastRemuxServer.shared.stopSession()
            teardownRemoteCommands()
            if let originalBrightness {
                UIScreen.main.brightness = originalBrightness
            }
            ScreenAwake.set(.playback, false)
            requestOrientation(.portrait)
        }
        .onReceive(
            NotificationCenter.default
                .publisher(for: AVAudioSession.routeChangeNotification)
                .receive(on: DispatchQueue.main)
        ) { _ in
            // Tied to the view's lifetime (auto-cancelled on dismissal), unlike a raw addObserver token.
            guard !isDismissed else { return }
            updateAirPlayRouteStatus()
        }
        .sheet(isPresented: $showEPGSheet) {
            if let streamID = item.streamID {
                EPGDrawerView(channelName: cleanTitle, streamId: streamID)
                    .environment(appState)
            }
        }
        .sheet(isPresented: $showAudioSubtitleSheet) {
            streamAndAudioOptionsSheet
        }
    }

    // MARK: - Authentic Netflix Controls Overlay (Adaptive Portrait & Landscape)

    private var netflixControlsOverlay: some View {
        GeometryReader { geo in
            let isLandscape = geo.size.width > geo.size.height

            ZStack {
                Color.black.opacity(0.52)
                    .ignoresSafeArea()
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showControls = false
                        }
                    }

                if isLandscape {
                    // LANDSCAPE NETFLIX LAYOUT
                    VStack(spacing: 0) {
                        netflixLandscapeTopBar
                            .padding(.horizontal, 28)
                            .padding(.top, 18)

                        Spacer()

                        ZStack {
                            HStack {
                                netflixVerticalBrightnessSlider(height: 128)
                                Spacer()
                            }
                            .padding(.leading, 30)

                            netflixCenterTransportControls(spacing: 88, skipSize: 36, playSize: 44)
                        }

                        Spacer()

                        netflixBottomSection(isLandscape: true)
                            .padding(.horizontal, 28)
                            .padding(.bottom, 16)
                    }
                } else {
                    // PORTRAIT NETFLIX LAYOUT (Zero overlap, tailored for vertical screen)
                    VStack(spacing: 0) {
                        netflixPortraitTopBar
                            .padding(.horizontal, 16)
                            .padding(.top, 12)

                        Spacer()

                        // Only transport controls sit over the 16:9 video center in portrait
                        netflixCenterTransportControls(spacing: 56, skipSize: 34, playSize: 42)

                        Spacer()

                        // Portrait-only secondary strip (Reactions + Horizontal Brightness) in the lower letterbox area
                        VStack(spacing: 18) {
                            netflixReactionRow
                            netflixHorizontalBrightnessBar
                        }
                        .padding(.horizontal, 24)
                        .padding(.bottom, 22)

                        netflixBottomSection(isLandscape: false)
                            .padding(.horizontal, 16)
                            .padding(.bottom, 14)
                    }
                }
            }
        }
    }

    // MARK: - 1. Netflix Top Bar (Landscape & Portrait)

    private var netflixLandscapeTopBar: some View {
        HStack(spacing: 16) {
            // Left column: Close + Title (constrained so it never touches center reactions)
            HStack(spacing: 12) {
                closeButton
                Text(cleanTitle)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Center column: 3 Netflix Reaction Circles
            netflixReactionRow

            // Right column: AirPlay, PiP, Rotate, Lock
            netflixTopRightActions(spacing: 22, isLandscape: true)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private var netflixPortraitTopBar: some View {
        HStack(spacing: 10) {
            closeButton

            Text(cleanTitle)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)

            netflixTopRightActions(spacing: 16, isLandscape: false)
        }
    }

    private var closeButton: some View {
        Button {
            isDismissed = true
            saveCurrentProgressAndCleanup()
            onClose()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 21, weight: .regular))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
        }
    }

    private func netflixTopRightActions(spacing: CGFloat, isLandscape: Bool) -> some View {
        HStack(spacing: max(spacing - 10, 8)) {
            // 1. AirPlay / Cast / Screen Mirroring Button (40x40 reliable hit target + programmatic picker trigger)
            ZStack {
                AirPlayRoutePickerButton(coordinator: routePickerCoordinator)
                    .frame(width: 38, height: 38)

                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    scheduleAutoHideControls()
                    prepareForAirPlayVideoHandoff()
                    routePickerCoordinator.triggerPicker()
                } label: {
                    Image(systemName: "airplayvideo")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle((isAirPlayActive || isExternalPlaybackActive) ? AppTheme.netflixRed : .white)
                        .frame(width: 40, height: 40)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .frame(width: 40, height: 40)

            // 2. Picture-in-Picture / Aspect Fill Button
            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                scheduleAutoHideControls()
                if !useVLCEngine, let pip = pipController, pip.isPictureInPicturePossible {
                    if pip.isPictureInPictureActive {
                        pip.stopPictureInPicture()
                    } else {
                        pip.startPictureInPicture()
                    }
                } else {
                    isZoomedToFill.toggle()
                }
            } label: {
                Image(systemName: "pip.enter")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // 3. Orientation Toggle Button
            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                scheduleAutoHideControls()
                requestOrientation(isLandscape ? .portrait : .landscapeRight)
            } label: {
                Image(systemName: isLandscape ? "arrow.down.right.and.arrow.up.left" : "rotate.right")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // 4. Screen Lock Button
            Button {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                requestOrientation(isLandscape ? .landscapeRight : .portrait)
                withAnimation(.easeInOut(duration: 0.2)) {
                    isScreenLocked = true
                    showControls = true
                }
                scheduleAutoHideControls()
            } label: {
                Image(systemName: "lock")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private var netflixReactionRow: some View {
        HStack(spacing: 16) {
            reactionCircleButton(icon: "hand.thumbsdown", isSelected: userReaction == 1) {
                userReaction = (userReaction == 1) ? 0 : 1
                scheduleAutoHideControls()
            }

            reactionCircleButton(icon: "hand.thumbsup", isSelected: userReaction == 2) {
                userReaction = (userReaction == 2) ? 0 : 2
                scheduleAutoHideControls()
            }

            Button {
                userReaction = (userReaction == 3) ? 0 : 3
                toggleFavoriteForCurrentItem()
                scheduleAutoHideControls()
            } label: {
                ZStack {
                    Circle()
                        .fill(userReaction == 3 ? Color.white.opacity(0.32) : Color.white.opacity(0.16))
                        .frame(width: 42, height: 42)

                    HStack(spacing: -5) {
                        Image(systemName: "hand.thumbsup")
                            .font(.system(size: 14, weight: .semibold))
                        Image(systemName: "hand.thumbsup")
                            .font(.system(size: 14, weight: .semibold))
                            .offset(y: -2)
                    }
                    .foregroundStyle(.white)
                }
            }
            .buttonStyle(.plain)
        }
    }

    private func reactionCircleButton(icon: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(isSelected ? Color.white.opacity(0.32) : Color.white.opacity(0.16))
                    .frame(width: 42, height: 42)
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - 2. Brightness Controls & Center Transport Controls

    private func netflixVerticalBrightnessSlider(height: CGFloat) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "sun.max")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.white)

            GeometryReader { geo in
                ZStack(alignment: .bottom) {
                    Capsule()
                        .fill(Color.white.opacity(0.28))
                        .frame(width: 6)

                    Capsule()
                        .fill(Color.white)
                        .frame(width: 6, height: max(8, geo.size.height * brightnessLevel))
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle().inset(by: -14))
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let fraction = 1.0 - (value.location.y / geo.size.height)
                            let clamped = min(max(fraction, 0.05), 1.0)
                            brightnessLevel = clamped
                            UIScreen.main.brightness = clamped
                            scheduleAutoHideControls()
                        }
                )
            }
            .frame(width: 24, height: height)
        }
    }

    private var netflixHorizontalBrightnessBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "sun.min")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white.opacity(0.75))

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.25))
                        .frame(height: 5)

                    Capsule()
                        .fill(Color.white)
                        .frame(width: max(8, geo.size.width * brightnessLevel), height: 5)
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle().inset(by: -10))
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let fraction = value.location.x / geo.size.width
                            let clamped = min(max(fraction, 0.05), 1.0)
                            brightnessLevel = clamped
                            UIScreen.main.brightness = clamped
                            scheduleAutoHideControls()
                        }
                )
            }
            .frame(height: 18)

            Image(systemName: "sun.max")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.white)
        }
        .frame(maxWidth: 240)
    }

    private func netflixCenterTransportControls(spacing: CGFloat, skipSize: CGFloat, playSize: CGFloat) -> some View {
        HStack(spacing: spacing) {
            Button {
                seekBy(seconds: -10)
                scheduleAutoHideControls()
            } label: {
                Image(systemName: "gobackward.10")
                    .font(.system(size: skipSize, weight: .regular))
                    .foregroundStyle(.white)
            }

            Button {
                togglePlayPause()
                scheduleAutoHideControls()
            } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: playSize, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 56, height: 56)
            }

            Button {
                seekBy(seconds: 10)
                scheduleAutoHideControls()
            } label: {
                Image(systemName: "goforward.10")
                    .font(.system(size: skipSize, weight: .regular))
                    .foregroundStyle(.white)
            }
        }
    }

    // MARK: - 3. Bottom Netflix Red Scrubber & Action Bar

    private func netflixBottomSection(isLandscape: Bool) -> some View {
        VStack(spacing: 16) {
            HStack(spacing: 14) {
                GeometryReader { geo in
                    let fraction: CGFloat = totalDuration > 1 ? CGFloat(min(max(currentTime / totalDuration, 0), 1)) : 0.03
                    let thumbX = max(8, min(geo.size.width - 8, geo.size.width * fraction))

                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.white.opacity(0.32))
                            .frame(height: 4)

                        Capsule()
                            .fill(AppTheme.netflixRed)
                            .frame(width: thumbX, height: 4)

                        Circle()
                            .fill(AppTheme.netflixRed)
                            .frame(width: 16, height: 16)
                            .offset(x: thumbX - 8)
                    }
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle().inset(by: -10))
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { val in
                                guard totalDuration > 1 else { return }
                                isScrubbing = true
                                let pct = min(max(val.location.x / geo.size.width, 0), 1)
                                currentTime = Double(pct) * totalDuration
                                scheduleAutoHideControls()
                            }
                            .onEnded { val in
                                guard totalDuration > 1 else { return }
                                let pct = Float(min(max(val.location.x / geo.size.width, 0), 1))
                                let target = Double(pct) * totalDuration
                                seekTo(seconds: target)
                                scheduleAutoHideControls()
                            }
                    )
                }
                .frame(height: 20)

                Text(formattedRemainingTime)
                    .font(.system(size: 13, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: true, vertical: false)
            }

            HStack(spacing: isLandscape ? 54 : 32) {
                if item.contentType == .live, item.streamID != nil {
                    Button {
                        showEPGSheet = true
                        scheduleAutoHideControls()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "list.bullet.rectangle")
                                .font(.system(size: 14, weight: .semibold))
                            Text("TV Guide")
                                .font(.system(size: 13, weight: .bold))
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                        .foregroundStyle(.white)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                Button {
                    cyclePlaybackSpeed()
                    scheduleAutoHideControls()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "gauge.with.needle")
                            .font(.system(size: 15, weight: .semibold))
                        Text("Speed (\(formattedSpeed))")
                            .font(.system(size: 13, weight: .bold))
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .foregroundStyle(.white)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button {
                    refreshVLCTracks()
                    showAudioSubtitleSheet = true
                    scheduleAutoHideControls()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "captions.bubble")
                            .font(.system(size: 14, weight: .semibold))
                        Text("Audio & Subtitles")
                            .font(.system(size: 13, weight: .bold))
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .foregroundStyle(.white)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if nextEpisodeItem != nil {
                    Button {
                        playNextEpisode(automatic: false)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "forward.end.fill")
                                .font(.system(size: 14, weight: .semibold))
                            Text("Next Episode")
                                .font(.system(size: 13, weight: .bold))
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                        .foregroundStyle(.white)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Authentic Netflix Locked Screen Overlay (Blocks All Stray Touches Until Unlocked)

    private var lockedScreenOverlay: some View {
        ZStack {
            // Full-screen touch shield so tapping anywhere outside the unlock pill only hides the pill
            Color.black.opacity(0.32)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showControls = false
                    }
                }

            VStack {
                Spacer()
                Button {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isScreenLocked = false
                        showControls = true
                    }
                    scheduleAutoHideControls()
                } label: {
                    VStack(spacing: 6) {
                        ZStack {
                            Circle()
                                .fill(Color.white)
                                .frame(width: 46, height: 46)
                                .shadow(color: .black.opacity(0.45), radius: 6, y: 2)
                            Image(systemName: "lock.fill")
                                .font(.system(size: 20, weight: .bold))
                                .foregroundStyle(.black)
                        }
                        Text("Screen Locked")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.white)
                        Text("Tap to Unlock")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white.opacity(0.8))
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 14)
                    .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(Color.white.opacity(0.18), lineWidth: 0.8)
                    )
                }
                .buttonStyle(.plain)
                .padding(.bottom, 28)
            }
        }
    }

    // MARK: - Audio, Subtitles & Engine Options Sheet

    private var streamAndAudioOptionsSheet: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                List {
                    if !audioTracks.isEmpty {
                        Section("Audio Tracks") {
                            ForEach(audioTracks, id: \.index) { track in
                                Button {
                                    selectedAudioTrack = track.index
                                    vlcPlayer?.currentAudioTrackIndex = track.index
                                    showAudioSubtitleSheet = false
                                } label: {
                                    HStack {
                                        Text(track.name)
                                            .foregroundStyle(.white)
                                        Spacer()
                                        if selectedAudioTrack == track.index {
                                            Image(systemName: "checkmark")
                                                .foregroundStyle(AppTheme.netflixRed)
                                        }
                                    }
                                }
                            }
                        }
                    }

                    if !subtitleTracks.isEmpty {
                        Section("Subtitles") {
                            ForEach(subtitleTracks, id: \.index) { track in
                                Button {
                                    selectedSubtitleTrack = track.index
                                    vlcPlayer?.currentVideoSubTitleIndex = track.index
                                    showAudioSubtitleSheet = false
                                } label: {
                                    HStack {
                                        Text(track.name)
                                            .foregroundStyle(.white)
                                        Spacer()
                                        if selectedSubtitleTrack == track.index {
                                            Image(systemName: "checkmark")
                                                .foregroundStyle(AppTheme.netflixRed)
                                        }
                                    }
                                }
                            }
                        }
                    }

                    Section("Playback Engine") {
                        Button {
                            useVLCEngine = true
                            showAudioSubtitleSheet = false
                            loadStream()
                        } label: {
                            HStack {
                                Text("VLC Cinema Engine (MKV / Dolby / Multi-Sub)")
                                    .foregroundStyle(.white)
                                Spacer()
                                if useVLCEngine {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(AppTheme.netflixRed)
                                }
                            }
                        }

                        Button {
                            useVLCEngine = false
                            showAudioSubtitleSheet = false
                            loadStream()
                        } label: {
                            HStack {
                                Text("Native Apple Engine (HLS / PiP)")
                                    .foregroundStyle(.white)
                                Spacer()
                                if !useVLCEngine {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(AppTheme.netflixRed)
                                }
                            }
                        }
                    }

                    if item.contentType == .live {
                        Section("Live Stream Protocol") {
                            ForEach(LiveStreamFormat.allCases) { format in
                                Button {
                                    selectedFormat = format
                                    appState.preferredLiveFormat = format
                                    showAudioSubtitleSheet = false
                                    loadStream()
                                } label: {
                                    HStack {
                                        Text(format.displayName)
                                            .foregroundStyle(.white)
                                        Spacer()
                                        if selectedFormat == format {
                                            Image(systemName: "checkmark")
                                                .foregroundStyle(AppTheme.netflixRed)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Audio & Subtitles")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        showAudioSubtitleSheet = false
                    }
                    .foregroundStyle(AppTheme.netflixRed)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func errorOverlay(message: String) -> some View {
        VStack(spacing: 16) {
            NucFlixLogoBadge(size: 42)

            Text("Stream Notice")
                .font(.headline.weight(.bold))
                .foregroundStyle(.white)

            Text(message)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.75))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)

            HStack(spacing: 12) {
                Button {
                    useVLCEngine = true
                    loadStream()
                } label: {
                    Label("Retry with VLC Engine", systemImage: "arrow.clockwise")
                        .font(.subheadline.bold())
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                        .background(Color.white, in: Capsule())
                        .foregroundStyle(.black)
                }

                Button {
                    isDismissed = true
                    saveCurrentProgressAndCleanup()
                    onClose()
                } label: {
                    Text("Close")
                        .font(.subheadline.bold())
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                        .background(AppTheme.elevatedGray, in: Capsule())
                        .foregroundStyle(.white)
                }
            }
        }
        .padding(24)
        .obsidianGlassCard(cornerRadius: 16)
        .padding(24)
    }

    private var netflixTVSideCastBackdrop: some View {
        ZStack {
            Color.black

            if let artwork = item.artworkURL, !artwork.isEmpty {
                ArtworkImageView(urlString: artwork, fallbackTitle: cleanTitle, maxPixelSize: 600)
                    .blur(radius: 36)
                    .opacity(0.32)
            }

            LinearGradient(
                colors: [.black.opacity(0.75), .black.opacity(0.45), .black.opacity(0.85)],
                startPoint: .top,
                endPoint: .bottom
            )

            VStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(AppTheme.netflixRed.opacity(0.18))
                        .frame(width: 78, height: 78)
                    Image(systemName: "airplayvideo")
                        .font(.system(size: 32, weight: .semibold))
                        .foregroundStyle(AppTheme.netflixRed)
                }

                Text("Playing on \(activeAirPlayDeviceName ?? "AirPlay TV")")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.white)

                Text(cleanTitle)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white.opacity(0.78))
                    .lineLimit(1)
                    .padding(.horizontal, 32)

                if let subtitle = item.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.58))
                        .lineLimit(1)
                }
            }
        }
    }

    // MARK: - Playback Lifecycle & Hybrid Engine Switching

    private var formattedRemainingTime: String {
        guard totalDuration > 1 else {
            return item.contentType == .live ? "LIVE" : "1:45:00"
        }
        let remaining = max(Int(totalDuration - currentTime), 0)
        let h = remaining / 3600
        let m = (remaining % 3600) / 60
        let s = remaining % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%02d:%02d", m, s)
    }

    private var formattedSpeed: String {
        if playbackSpeed == 1.0 { return "1x" }
        return String(format: "%gx", playbackSpeed)
    }

    private func scheduleAutoHideControls() {
        hideControlsTask?.cancel()
        hideControlsTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_800_000_000)
            if !Task.isCancelled && isPlaying && !isScrubbing {
                withAnimation(.easeInOut(duration: 0.25)) {
                    showControls = false
                }
            }
        }
    }

    private func togglePlayPause() {
        if useVLCEngine, let vlcPlayer {
            if isPlaying {
                vlcPlayer.pause()
                isPlaying = false
                saveProgressNow()
            } else {
                vlcPlayer.play()
                vlcPlayer.rate = playbackSpeed
                isPlaying = true
            }
        } else if let avPlayer {
            if isPlaying {
                avPlayer.pause()
                isPlaying = false
                saveProgressNow()
            } else {
                // Restart from the beginning if VOD playback previously reached the end
                if item.contentType != .live, totalDuration > 1, currentTime >= totalDuration - 1 {
                    seekTo(seconds: 0)
                }
                avPlayer.playImmediately(atRate: playbackSpeed)
                isPlaying = true
            }
        }
        updateNowPlayingInfo()
    }

    private func seekBy(seconds delta: Double) {
        if useVLCEngine, let vlcPlayer {
            if delta >= 0 {
                vlcPlayer.jumpForward(Int32(delta))
            } else {
                vlcPlayer.jumpBackward(Int32(abs(delta)))
            }
            currentTime = max(0, currentTime + delta)
            updateNowPlayingInfo()
        } else {
            var target = max(0, currentTime + delta)
            if totalDuration > 1 {
                target = min(target, max(totalDuration - 1, 0))
            }
            seekTo(seconds: target)
        }
    }

    private func seekTo(seconds target: Double) {
        let clampedTarget = max(0, totalDuration > 1 ? min(target, max(totalDuration - 1, 0)) : target)
        currentTime = clampedTarget

        if useVLCEngine, let vlcPlayer, totalDuration > 1 {
            isScrubbing = true
            vlcPlayer.position = Float(min(max(clampedTarget / totalDuration, 0), 1))
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 500_000_000)
                isScrubbing = false
                updateNowPlayingInfo()
            }
            return
        }

        guard let avPlayer else {
            isScrubbing = false
            return
        }

        if isRemuxedCastActive {
            let relativeTarget = clampedTarget - remuxBaseOffsetSeconds
            let buffered = AirPlayCastRemuxServer.shared.bufferedDurationSeconds
            if relativeTarget >= 0 && relativeTarget <= max(buffered - 2.0, 0) {
                let tolerance = CMTime(seconds: 1, preferredTimescale: 600)
                isScrubbing = true
                avPlayer.seek(
                    to: CMTime(seconds: relativeTarget, preferredTimescale: 600),
                    toleranceBefore: tolerance,
                    toleranceAfter: tolerance
                ) { _ in
                    Task { @MainActor in
                        isScrubbing = false
                        updateNowPlayingInfo()
                    }
                }
            } else {
                // Target is outside the currently remuxed window — restart the remux session at clampedTarget
                isScrubbing = false
                item.resumeSeconds = clampedTarget
                loadStream()
            }
        } else {
            let tolerance = CMTime(seconds: 1, preferredTimescale: 600)
            isScrubbing = true
            avPlayer.seek(
                to: CMTime(seconds: clampedTarget, preferredTimescale: 600),
                toleranceBefore: tolerance,
                toleranceAfter: tolerance
            ) { _ in
                Task { @MainActor in
                    isScrubbing = false
                    updateNowPlayingInfo()
                }
            }
        }
    }

    private func cyclePlaybackSpeed() {
        let speeds: [Float] = [0.75, 1.0, 1.25, 1.5]
        if let idx = speeds.firstIndex(of: playbackSpeed) {
            playbackSpeed = speeds[(idx + 1) % speeds.count]
        } else {
            playbackSpeed = 1.0
        }
        if useVLCEngine {
            vlcPlayer?.rate = playbackSpeed
        } else if isPlaying {
            avPlayer?.rate = playbackSpeed
        }
        updateNowPlayingInfo()
    }

    private func refreshVLCTracks() {
        guard let vlcPlayer else { return }
        if let names = vlcPlayer.audioTrackNames as? [String],
           let indexes = vlcPlayer.audioTrackIndexes as? [NSNumber] {
            audioTracks = zip(indexes, names).map { ($0.int32Value, $1) }
            selectedAudioTrack = vlcPlayer.currentAudioTrackIndex
        }
        if let names = vlcPlayer.videoSubTitlesNames as? [String],
           let indexes = vlcPlayer.videoSubTitlesIndexes as? [NSNumber] {
            subtitleTracks = zip(indexes, names).map { ($0.int32Value, $1) }
            selectedSubtitleTrack = vlcPlayer.currentVideoSubTitleIndex
        }
    }

    private func toggleFavoriteForCurrentItem() {
        if item.contentType == .live, let streamID = item.streamID {
            let chan = XtreamLiveStream(name: item.title, streamId: streamID, streamIcon: item.artworkURL)
            appState.toggleFavoriteLive(chan)
        } else if item.contentType == .movie, let streamID = item.streamID {
            let mov = XtreamVODStream(name: item.title, streamId: streamID, streamIcon: item.artworkURL, containerExtension: item.containerExtension ?? "mp4")
            appState.toggleFavoriteMovie(mov)
        }
    }

    private func requestOrientation(_ mask: UIInterfaceOrientationMask) {
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask))
    }

    private func configureAudioSession(triggerReloadIfNeeded: Bool = true) {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .moviePlayback, options: [])
        } catch {
            print("[IPTVPlayer] AVAudioSession setCategory failed: \(error.localizedDescription)")
        }
        do {
            try session.setActive(true)
        } catch {
            print("[IPTVPlayer] AVAudioSession setActive failed: \(error.localizedDescription)")
        }
        updateAirPlayRouteStatus(triggerReloadIfNeeded: triggerReloadIfNeeded)
    }

    /// Ensures `AVPlayer` (+ `AirPlayCastRemuxServer` for MKV/TS) is active BEFORE the user selects an AirPlay TV,
    /// so iOS negotiates a full AirPlay Video session instead of an audio-only session.
    private func prepareForAirPlayVideoHandoff() {
        guard !isDismissed else { return }
        var needsReload = false
        if item.contentType == .live && selectedFormat == .mpegTS {
            selectedFormat = .hlsLive
            needsReload = true
        }
        if useVLCEngine {
            if item.contentType != .live && currentTime > 2 {
                item.resumeSeconds = currentTime
            }
            useVLCEngine = false
            needsReload = true
        }
        if needsReload {
            loadStream()
        }
    }

    private func updateAirPlayRouteStatus(triggerReloadIfNeeded: Bool = true) {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        let wasAirPlayActive = isAirPlayActive
        if let airplayPort = outputs.first(where: { $0.portType == .airPlay }) {
            isAirPlayActive = true
            activeAirPlayDeviceName = airplayPort.portName
            guard triggerReloadIfNeeded, !isDismissed else { return }
            var needsReload = false
            if item.contentType == .live && selectedFormat == .mpegTS {
                selectedFormat = .hlsLive
                needsReload = true
            }
            if useVLCEngine {
                if item.contentType != .live && currentTime > 2 {
                    item.resumeSeconds = currentTime
                }
                useVLCEngine = false
                needsReload = true
            }
            if needsReload {
                loadStream()
            }
        } else {
            isAirPlayActive = false
            activeAirPlayDeviceName = nil
            // If the user disconnected AirPlay while watching an MKV/TS stream that was remuxing for AirPlay,
            // switch back to the local VLC engine seamlessly at the current timestamp.
            if triggerReloadIfNeeded, !isDismissed, wasAirPlayActive, isRemuxedCastActive, shouldDefaultToVLC {
                if item.contentType != .live && currentTime > 2 {
                    item.resumeSeconds = currentTime
                }
                AirPlayCastRemuxServer.shared.stopSession()
                isRemuxedCastActive = false
                useVLCEngine = true
                loadStream()
            }
        }
    }

    private func loadStream(isStallRetry: Bool = false) {
        // Never (re)start playback once the player has been dismissed (prevents ghost audio)
        guard !isDismissed else { return }
        if !isStallRetry {
            stallRetryCount = 0
        }
        playerError = nil
        avEngineSetupTask?.cancel()
        avEngineSetupTask = nil
        saveCurrentProgressAndCleanup()

        guard let url = currentStreamURL else {
            playerError = "Unable to construct a valid stream URL for this item."
            return
        }

        if useVLCEngine {
            AirPlayCastRemuxServer.shared.stopSession()
            isRemuxedCastActive = false
            startVLCEngine(with: url)
        } else {
            startAVPlayerEngine(with: url)
        }
        updateNowPlayingInfo()
    }

    private func startVLCEngine(with url: URL) {
        let player = VLCMediaPlayer()
        let media = VLCMedia(url: url)
        var vlcOptions: [AnyHashable: Any] = [
            "http-user-agent": "IPTVSmartersPlayer/3.0 (iOS; iPhone; Scale/3.00)",
            "network-caching": 1500
        ]
        if appState.hardwareAccelerationEnabled {
            // Allow hardware (VideoToolbox) decoding when available
            vlcOptions["avcodec-hw"] = "any"
        } else {
            // Force pure software decoding
            vlcOptions["codec"] = "avcodec"
            vlcOptions["avcodec-hw"] = "none"
        }
        media.addOptions(vlcOptions)
        player.media = media

        vlcDelegate.onTimeChanged = { [weak player] in
            guard let player else { return }
            let elapsedMs = Double(player.time.intValue)
            let remainingMs = Double( abs(player.remainingTime?.intValue ?? 0) )
            let elapsedSec = max(0, elapsedMs / 1000.0)
            let totalSec = (remainingMs > 0) ? (elapsedSec + remainingMs / 1000.0) : Double(player.media?.length.intValue ?? 0) / 1000.0

            Task { @MainActor in
                if !self.isScrubbing && elapsedSec > 0 {
                    self.currentTime = elapsedSec
                }
                if totalSec > 1 {
                    let durationWasUnknown = self.totalDuration <= 1
                    self.totalDuration = totalSec
                    if durationWasUnknown {
                        self.updateNowPlayingInfo()
                    }
                }
                if self.audioTracks.isEmpty && player.numberOfAudioTracks > 0 {
                    self.refreshVLCTracks()
                }
                self.saveProgressIfNeeded(position: elapsedSec, duration: max(totalSec, 0))
            }
        }

        vlcDelegate.onEnded = {
            Task { @MainActor in
                // Ignore spurious "ended" from network failures early in the stream
                guard self.item.contentType != .live,
                      self.totalDuration > 1,
                      self.currentTime >= self.totalDuration - 30 else { return }
                self.handlePlaybackEnded()
            }
        }
        player.delegate = vlcDelegate
        self.vlcPlayer = player
        self.isPlaying = true
        player.play()

        if item.contentType != .live && item.resumeSeconds > 5 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                player.jumpForward(Int32(item.resumeSeconds))
            }
        }
    }

    /// Applies the user's stream quality + buffering preferences to an AVPlayerItem.
    private func applyStreamQualityPreferences(to playerItem: AVPlayerItem) {
        switch appState.preferredStreamQuality {
        case .fullHD1080p:
            playerItem.preferredPeakBitRate = 6_000_000
            playerItem.preferredMaximumResolution = CGSize(width: 1920, height: 1080)
        case .hd720pSaver:
            playerItem.preferredPeakBitRate = 2_500_000
            playerItem.preferredMaximumResolution = CGSize(width: 1280, height: 720)
        default: // .autoMax → no limits
            playerItem.preferredPeakBitRate = 0
            playerItem.preferredMaximumResolution = .zero
        }
        // Live: keep a small forward buffer for low latency. VOD: 0 = let AVFoundation decide.
        playerItem.preferredForwardBufferDuration = item.contentType == .live ? 4 : 0
    }

    private func startAVPlayerEngine(with url: URL) {
        isBuffering = true
        let needsRemux = (item.contentType != .live && shouldDefaultToVLC)
        let startOffset = (item.contentType != .live && item.resumeSeconds > 5) ? item.resumeSeconds : 0

        // Instantiate AVPlayer immediately so AVPlayerLayer + AVRoutePickerView have an active
        // external-playback-capable player even while the edge URL or remux session prepares.
        let newPlayer = AVPlayer()
        newPlayer.allowsExternalPlayback = true
        newPlayer.usesExternalPlaybackWhileExternalScreenIsActive = true
        self.avPlayer = newPlayer
        self.isPlaying = true

        externalPlaybackObservation = newPlayer.observe(\.isExternalPlaybackActive, options: [.new, .initial]) { observedPlayer, _ in
            let active = observedPlayer.isExternalPlaybackActive
            Task { @MainActor in
                guard self.avPlayer === observedPlayer else { return }
                self.isExternalPlaybackActive = active
            }
        }

        avEngineSetupTask = Task { @MainActor in
            let playableURL: URL
            if url.isFileURL {
                self.isRemuxedCastActive = false
                self.remuxBaseOffsetSeconds = 0
                playableURL = AirPlayCastRemuxServer.shared.startFileSession(localFileURL: url) ?? url
            } else if needsRemux {
                self.isRemuxedCastActive = true
                self.remuxBaseOffsetSeconds = startOffset
                let resolvedSource = await XtreamRedirectResolver.resolve(url: url, fallbackExtension: item.containerExtension)
                guard !Task.isCancelled, !self.isDismissed, self.avPlayer === newPlayer else { return }
                if let hlsURL = AirPlayCastRemuxServer.shared.startHLSRemuxSession(
                    sourceURL: resolvedSource,
                    startSeconds: startOffset
                ) {
                    playableURL = hlsURL
                } else {
                    playableURL = resolvedSource
                }
            } else {
                AirPlayCastRemuxServer.shared.stopSession()
                self.isRemuxedCastActive = false
                self.remuxBaseOffsetSeconds = 0
                let extHint = (item.contentType == .live) ? "m3u8" : (item.containerExtension ?? "mp4")
                playableURL = await XtreamRedirectResolver.resolve(url: url, fallbackExtension: extHint)
            }

            guard !Task.isCancelled, !self.isDismissed, self.avPlayer === newPlayer else { return }

            // IMPORTANT: Do NOT pass AVURLAssetHTTPHeaderFieldsKey or AVURLAssetOutOfBandMIMETypeKey here.
            // Private AVURLAsset options prevent iOS AVPlayer from handing off video to AirPlay receivers
            // (causing audio-only casting while video stays on the phone).
            let asset = AVURLAsset(url: playableURL)
            let playerItem = AVPlayerItem(asset: asset)
            applyStreamQualityPreferences(to: playerItem)
            newPlayer.replaceCurrentItem(with: playerItem)

            // Seamless automatic fallback to MobileVLCKit ONLY when not AirPlaying
            statusObservation = playerItem.observe(\.status, options: [.new, .initial]) { observedItem, _ in
                if observedItem.status == .failed {
                    Task { @MainActor in
                        guard !self.isDismissed, self.avPlayer?.currentItem === observedItem else { return }
                        if !self.isAirPlayActive && !self.isExternalPlaybackActive {
                            self.useVLCEngine = true
                            self.loadStream()
                        }
                    }
                }
            }

            // Buffering indicator driven by timeControlStatus
            timeControlObservation = newPlayer.observe(\.timeControlStatus, options: [.new, .initial]) { observedPlayer, _ in
                let status = observedPlayer.timeControlStatus
                Task { @MainActor in
                    guard self.avPlayer === observedPlayer else { return }
                    self.isBuffering = (status == .waitingToPlayAtSpecifiedRate)
                    if status == .playing {
                        self.stallRecoveryTask?.cancel()
                        self.stallRecoveryTask = nil
                    }
                }
            }

            // Item notifications: stall recovery for live, end-of-playback for VOD
            let center = NotificationCenter.default
            var tokens: [NSObjectProtocol] = []
            if item.contentType == .live {
                tokens.append(center.addObserver(forName: .AVPlayerItemPlaybackStalled, object: playerItem, queue: .main) { _ in
                    Task { @MainActor in
                        self.handlePlaybackStalled()
                    }
                })
            } else {
                tokens.append(center.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: playerItem, queue: .main) { _ in
                    Task { @MainActor in
                        self.handlePlaybackEnded()
                    }
                })
            }
            itemObserverTokens = tokens

            if !self.isRemuxedCastActive && item.contentType != .live && startOffset > 5 {
                let targetTime = CMTime(seconds: startOffset, preferredTimescale: 600)
                newPlayer.seek(to: targetTime, toleranceBefore: .zero, toleranceAfter: .zero) { _ in }
            }

            newPlayer.playImmediately(atRate: playbackSpeed)
            self.isPlaying = true

            let interval = CMTime(seconds: 1, preferredTimescale: 600)
            timeObserverToken = newPlayer.addPeriodicTimeObserver(forInterval: interval, queue: .main) { time in
                guard let currentItem = newPlayer.currentItem else { return }
                let rawCurrentSecs = CMTimeGetSeconds(time)
                let rawDurationSecs = CMTimeGetSeconds(currentItem.duration)
                Task { @MainActor in
                    let effectiveCurrent: Double
                    if self.isRemuxedCastActive {
                        effectiveCurrent = self.remuxBaseOffsetSeconds + max(0, rawCurrentSecs.isFinite ? rawCurrentSecs : 0)
                    } else {
                        effectiveCurrent = rawCurrentSecs
                    }

                    if !self.isScrubbing && effectiveCurrent.isFinite && effectiveCurrent >= 0 {
                        self.currentTime = effectiveCurrent
                    }

                    if self.isRemuxedCastActive {
                        let vlcSourceDur = AirPlayCastRemuxServer.shared.sourceDurationSeconds
                        if vlcSourceDur > 1 {
                            let durationWasUnknown = self.totalDuration <= 1
                            self.totalDuration = vlcSourceDur
                            if durationWasUnknown {
                                self.updateNowPlayingInfo()
                            }
                        } else if self.totalDuration <= 1 && rawDurationSecs.isFinite && rawDurationSecs > 0 {
                            self.totalDuration = self.remuxBaseOffsetSeconds + rawDurationSecs
                        }
                    } else if rawDurationSecs.isFinite && rawDurationSecs > 0 {
                        let durationWasUnknown = self.totalDuration <= 1
                        self.totalDuration = rawDurationSecs
                        if durationWasUnknown {
                            self.updateNowPlayingInfo()
                        }
                    }

                    if effectiveCurrent.isFinite {
                        self.saveProgressIfNeeded(
                            position: effectiveCurrent,
                            duration: self.totalDuration > 1 ? self.totalDuration : 0
                        )
                    }
                }
            }
        }
    }

    // MARK: - Stall Recovery & End of Playback

    private func handlePlaybackStalled() {
        guard !isDismissed, !useVLCEngine, item.contentType == .live, isPlaying else { return }
        isBuffering = true
        stallRecoveryTask?.cancel()
        stallRecoveryTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled, !isDismissed, !useVLCEngine, isPlaying else { return }
            if avPlayer?.timeControlStatus == .playing { return }
            guard stallRetryCount < Self.maxStallRetries else { return }
            stallRetryCount += 1
            loadStream(isStallRetry: true)
        }
    }

    private func handlePlaybackEnded() {
        guard !isDismissed else { return }
        isPlaying = false
        isBuffering = false
        hideControlsTask?.cancel()
        if totalDuration > 1 {
            currentTime = totalDuration
            lastSavedProgressSecond = totalDuration
            appState.recordPlaybackProgress(
                item: item,
                positionSeconds: totalDuration,
                durationSeconds: totalDuration
            )
        }
        updateNowPlayingInfo()

        guard nextEpisodeItem != nil, appState.autoplayNextEpisode else {
            withAnimation(.easeInOut(duration: 0.2)) {
                showControls = true
            }
            return
        }
        if consecutiveAutoplays >= Self.maxAutoplaysBeforeCheck {
            withAnimation(.easeInOut(duration: 0.25)) {
                showControls = false
                showStillWatchingPrompt = true
            }
        } else if dismissedNextEpisodePrompt {
            // User chose "Watch Credits" — give a short countdown before moving on
            startEndOfEpisodeCountdown()
        } else {
            playNextEpisode(automatic: true)
        }
    }

    // MARK: - Next Episode (Binge Autoplay)

    private var remainingSeconds: Double {
        max(totalDuration - currentTime, 0)
    }

    private var isInCreditsWindow: Bool {
        item.contentType == .seriesEpisode
            && totalDuration > 120
            && currentTime > 0
            && remainingSeconds <= Self.creditsWindowSeconds
    }

    private func resolveNextEpisode() {
        guard item.contentType == .seriesEpisode else {
            nextEpisodeItem = nil
            return
        }
        let currentID = item.id
        Task { @MainActor in
            let next = await appState.nextEpisode(after: item)
            guard !isDismissed, item.id == currentID else { return }
            nextEpisodeItem = next
        }
    }

    private func startEndOfEpisodeCountdown() {
        endCountdownTask?.cancel()
        endOfEpisodeCountdown = 5
        endCountdownTask = Task { @MainActor in
            while let remaining = endOfEpisodeCountdown, remaining > 0 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { return }
                endOfEpisodeCountdown = remaining - 1
            }
            guard !Task.isCancelled else { return }
            playNextEpisode(automatic: true)
        }
    }

    /// Switches to the next episode inside the same player (no dismiss / re-present)
    private func playNextEpisode(automatic: Bool) {
        guard !isDismissed, let next = nextEpisodeItem else { return }
        endCountdownTask?.cancel()
        endOfEpisodeCountdown = nil
        showStillWatchingPrompt = false
        consecutiveAutoplays = automatic ? consecutiveAutoplays + 1 : 0

        // Mark the current episode as watched before moving on
        if totalDuration > 1 {
            appState.recordPlaybackProgress(item: item, positionSeconds: totalDuration, durationSeconds: totalDuration)
        }

        let prepared = appState.prepareInPlacePlayback(next)
        // Reset per-item playback state (currentTime first so cleanup doesn't save stale progress)
        currentTime = 0
        totalDuration = 0
        lastSavedProgressSecond = prepared.resumeSeconds
        audioTracks = []
        subtitleTracks = []
        selectedAudioTrack = -1
        selectedSubtitleTrack = -1
        nextEpisodeItem = nil
        dismissedNextEpisodePrompt = false
        playerError = nil
        stallRetryCount = 0
        item = prepared
        useVLCEngine = (isAirPlayActive || isExternalPlaybackActive) ? false : shouldDefaultToVLC
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        loadStream()
        resolveNextEpisode()
        withAnimation(.easeInOut(duration: 0.2)) {
            showControls = true
        }
        scheduleAutoHideControls()
    }

    @ViewBuilder
    private var nextEpisodeOverlay: some View {
        if showStillWatchingPrompt {
            stillWatchingPrompt
                .transition(.opacity)
        } else if let countdown = endOfEpisodeCountdown, let next = nextEpisodeItem {
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    VStack(alignment: .trailing, spacing: 10) {
                        Text("Next episode in \(countdown)")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(.white)
                            .contentTransition(.numericText(countsDown: true))
                        if let subtitle = next.subtitle {
                            Text(subtitle)
                                .font(.system(size: 13))
                                .foregroundStyle(.white.opacity(0.75))
                                .lineLimit(1)
                        }
                        HStack(spacing: 10) {
                            Button("Cancel") {
                                endCountdownTask?.cancel()
                                endOfEpisodeCountdown = nil
                                withAnimation { showControls = true }
                            }
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(Color.white.opacity(0.2), in: RoundedRectangle(cornerRadius: 4))

                            Button {
                                playNextEpisode(automatic: false)
                            } label: {
                                Label("Play Now", systemImage: "play.fill")
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundStyle(.black)
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 10)
                                    .background(Color.white, in: RoundedRectangle(cornerRadius: 4))
                            }
                        }
                    }
                    .padding(18)
                    .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 10))
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 36)
            }
            .transition(.opacity)
        } else if isInCreditsWindow, nextEpisodeItem != nil, !dismissedNextEpisodePrompt {
            VStack {
                Spacer()
                HStack(spacing: 12) {
                    Spacer()
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            dismissedNextEpisodePrompt = true
                        }
                    } label: {
                        Text("Watch Credits")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 12)
                            .background(Color.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 4))
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.white.opacity(0.6), lineWidth: 1))
                    }
                    .buttonStyle(.plain)

                    Button {
                        playNextEpisode(automatic: false)
                    } label: {
                        let progress = appState.autoplayNextEpisode
                            ? CGFloat(1 - min(remainingSeconds / Self.creditsWindowSeconds, 1))
                            : 0
                        HStack(spacing: 8) {
                            Image(systemName: "play.fill")
                                .font(.system(size: 15, weight: .bold))
                            Text("Next Episode")
                                .font(.system(size: 15, weight: .bold))
                        }
                        .foregroundStyle(.black)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                        .background(
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    Color.white
                                    // Netflix-style fill sweeps across as autoplay approaches
                                    Color(white: 0.72)
                                        .frame(width: geo.size.width * progress)
                                        .animation(.linear(duration: 1), value: progress)
                                }
                            }
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 28)
                .padding(.bottom, showControls ? 120 : 36)
            }
            .transition(.move(edge: .trailing).combined(with: .opacity))
            .animation(.easeInOut(duration: 0.3), value: showControls)
        }
    }

    private var stillWatchingPrompt: some View {
        ZStack {
            Color.black.opacity(0.75).ignoresSafeArea()
            VStack(spacing: 18) {
                Text("Are you still watching?")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(.white)
                if let subtitle = nextEpisodeItem?.subtitle {
                    Text("Up next: \(subtitle)")
                        .font(.system(size: 14))
                        .foregroundStyle(.white.opacity(0.75))
                        .lineLimit(1)
                }
                VStack(spacing: 10) {
                    Button {
                        consecutiveAutoplays = 0
                        playNextEpisode(automatic: false)
                    } label: {
                        Text("Continue Watching")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(.black)
                            .frame(width: 260, height: 46)
                            .background(Color.white, in: RoundedRectangle(cornerRadius: 4))
                    }
                    Button {
                        isDismissed = true
                        saveCurrentProgressAndCleanup()
                        onClose()
                    } label: {
                        Text("Back to Browse")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 260, height: 46)
                            .background(Color.white.opacity(0.18), in: RoundedRectangle(cornerRadius: 4))
                    }
                }
            }
        }
    }

    // MARK: - Throttled Progress Persistence

    /// Persists progress at most every `progressSaveInterval` seconds of playback movement.
    private func saveProgressIfNeeded(position: Double, duration: Double) {
        guard position.isFinite, position > 3 else { return }
        guard abs(position - lastSavedProgressSecond) >= Self.progressSaveInterval else { return }
        lastSavedProgressSecond = position
        appState.recordPlaybackProgress(
            item: item,
            positionSeconds: position,
            durationSeconds: max(duration, 0)
        )
        updateNowPlayingInfo()
    }

    /// Immediate save (pause / close / engine switch).
    private func saveProgressNow() {
        guard currentTime > 2 else { return }
        lastSavedProgressSecond = currentTime
        appState.recordPlaybackProgress(
            item: item,
            positionSeconds: currentTime,
            durationSeconds: totalDuration
        )
    }

    // MARK: - Now Playing & Remote Commands

    private func updateNowPlayingInfo() {
        guard !isDismissed else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: cleanTitle,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? Double(playbackSpeed) : 0.0,
            MPNowPlayingInfoPropertyIsLiveStream: item.contentType == .live
        ]
        if let subtitle = item.subtitle {
            info[MPMediaItemPropertyArtist] = subtitle
        }
        if totalDuration > 1 {
            info[MPMediaItemPropertyPlaybackDuration] = totalDuration
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func setupRemoteCommands() {
        teardownRemoteCommands()
        let center = MPRemoteCommandCenter.shared()
        var targets: [(command: MPRemoteCommand, token: Any)] = []

        func register(_ command: MPRemoteCommand, _ action: @escaping @MainActor () -> Void) {
            command.isEnabled = true
            let token = command.addTarget { _ -> MPRemoteCommandHandlerStatus in
                Task { @MainActor in action() }
                return .success
            }
            targets.append((command: command, token: token))
        }

        register(center.playCommand) { if !isPlaying { togglePlayPause() } }
        register(center.pauseCommand) { if isPlaying { togglePlayPause() } }
        register(center.togglePlayPauseCommand) { togglePlayPause() }
        center.skipForwardCommand.preferredIntervals = [10]
        center.skipBackwardCommand.preferredIntervals = [10]
        register(center.skipForwardCommand) { seekBy(seconds: 10) }
        register(center.skipBackwardCommand) { seekBy(seconds: -10) }

        remoteCommandTargets = targets
    }

    private func teardownRemoteCommands() {
        for entry in remoteCommandTargets {
            entry.command.removeTarget(entry.token)
        }
        remoteCommandTargets = []
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    private func saveCurrentProgressAndCleanup() {
        statusObservation?.invalidate()
        statusObservation = nil
        timeControlObservation?.invalidate()
        timeControlObservation = nil
        externalPlaybackObservation?.invalidate()
        externalPlaybackObservation = nil
        isExternalPlaybackActive = false
        for token in itemObserverTokens {
            NotificationCenter.default.removeObserver(token)
        }
        itemObserverTokens = []
        stallRecoveryTask?.cancel()
        stallRecoveryTask = nil
        isBuffering = false

        if let avPlayer, let token = timeObserverToken {
            avPlayer.removeTimeObserver(token)
            timeObserverToken = nil
        }
        if let avPlayer {
            avPlayer.pause()
            self.avPlayer = nil
        }
        if let vlcPlayer {
            vlcDelegate.onTimeChanged = nil
            vlcPlayer.stop()
            self.vlcPlayer = nil
        }
        saveProgressNow()
    }

}

// MARK: - MobileVLCKit Delegate Bridge & Surface View

final class VLCPlayerDelegateBridge: NSObject, VLCMediaPlayerDelegate {
    var onTimeChanged: (() -> Void)?
    var onEnded: (() -> Void)?

    func mediaPlayerTimeChanged(_ aNotification: Notification) {
        onTimeChanged?()
    }

    func mediaPlayerStateChanged(_ aNotification: Notification) {
        guard let player = aNotification.object as? VLCMediaPlayer else { return }
        if player.state == .ended {
            onEnded?()
        }
    }
}

struct VLCVideoSurfaceView: UIViewRepresentable {
    let player: VLCMediaPlayer

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .black
        player.drawable = view
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        if (player.drawable as? UIView) !== uiView {
            player.drawable = uiView
        }
    }
}

// MARK: - Pure AVPlayer Layer with PiP Support

final class PlayerLayerContainerView: UIView {
    override static var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

struct NetflixVideoLayerView: UIViewRepresentable {
    let player: AVPlayer
    let isZoomedToFill: Bool
    let onPiPControllerReady: (AVPictureInPictureController) -> Void

    func makeUIView(context: Context) -> PlayerLayerContainerView {
        let view = PlayerLayerContainerView()
        view.backgroundColor = .black
        view.playerLayer.player = player
        view.playerLayer.videoGravity = isZoomedToFill ? .resizeAspectFill : .resizeAspect

        if AVPictureInPictureController.isPictureInPictureSupported(),
           let pip = AVPictureInPictureController(playerLayer: view.playerLayer) {
            pip.canStartPictureInPictureAutomaticallyFromInline = true
            DispatchQueue.main.async {
                onPiPControllerReady(pip)
            }
        }
        return view
    }

    func updateUIView(_ uiView: PlayerLayerContainerView, context: Context) {
        if uiView.playerLayer.player !== player {
            uiView.playerLayer.player = player
        }
        let targetGravity: AVLayerVideoGravity = isZoomedToFill ? .resizeAspectFill : .resizeAspect
        if uiView.playerLayer.videoGravity != targetGravity {
            uiView.playerLayer.videoGravity = targetGravity
        }
    }
}

// MARK: - AirPlay Route Picker Button with Programmatic Trigger (100% Reliable in Fullscreen Overlays)

final class AirPlayTriggerCoordinator {
    weak var pickerView: AVRoutePickerView?

    func triggerPicker() {
        guard let pickerView else { return }
        if let button = findButton(in: pickerView) {
            button.sendActions(for: .touchUpInside)
        }
    }

    private func findButton(in view: UIView) -> UIButton? {
        if let btn = view as? UIButton {
            return btn
        }
        for sub in view.subviews {
            if let found = findButton(in: sub) {
                return found
            }
        }
        return nil
    }
}

struct AirPlayRoutePickerButton: UIViewRepresentable {
    let coordinator: AirPlayTriggerCoordinator

    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.prioritizesVideoDevices = true
        picker.tintColor = .clear
        picker.activeTintColor = .clear
        picker.backgroundColor = .clear
        picker.isUserInteractionEnabled = false
        coordinator.pickerView = picker
        return picker
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {
        coordinator.pickerView = uiView
    }
}

// MARK: - Xtream 302 Redirect Resolver (Preserves File Extensions for AirPlay Video Handoff)

enum XtreamRedirectResolver {
    private final class RedirectInterceptDelegate: NSObject, URLSessionTaskDelegate {
        var redirectedURL: URL?

        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            redirectedURL = request.url
            // Do not follow the redirect here so the single-connection edge token is reserved for the player/TV
            completionHandler(nil)
        }
    }

    static func resolve(url: URL, fallbackExtension: String?) async -> URL {
        guard !url.isFileURL else { return url }
        let originalExt = url.pathExtension.isEmpty ? (fallbackExtension ?? "") : url.pathExtension

        let delegate = RedirectInterceptDelegate()
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 3.5
        config.timeoutIntervalForResource = 4.0
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("AppleCoreMedia/1.0.0.21A329 (iPhone; U; CPU OS 17_0 like Mac OS X; en_us)", forHTTPHeaderField: "User-Agent")
        request.setValue("bytes=0-1", forHTTPHeaderField: "Range")

        do {
            _ = try await session.data(for: request)
        } catch {
            // Expected if canceled or timed out
        }

        guard let redirected = delegate.redirectedURL else {
            return url
        }

        // Xtream edge redirects (/live/play/<token>/<id>) strip the file extension (.m3u8 / .mp4).
        // Appending the extension allows AVPlayer and AirPlay 2 TVs to identify the container without private options.
        if redirected.pathExtension.isEmpty && !originalExt.isEmpty {
            if let withExt = URL(string: redirected.absoluteString + "." + originalExt) {
                return withExt
            }
        }
        return redirected
    }
}

// MARK: - Local LAN AirPlay Video Remux & File Server (Casts MKV/TS/AVI & Offline Files over AirPlay)

final class AirPlayCastRemuxServer: NSObject, VLCMediaPlayerDelegate {
    static let shared = AirPlayCastRemuxServer()

    private struct HLSSegment {
        let index: Int
        let byteOffset: UInt64
        let byteLength: Int
        let duration: Double
    }

    private let lock = NSLock()
    private let acceptQueue = DispatchQueue(label: "com.priteshbhavsar.NucFlix.castAccept", qos: .userInitiated)
    private let clientQueue = DispatchQueue(label: "com.priteshbhavsar.NucFlix.castClients", qos: .userInitiated, attributes: .concurrent)

    private var listenFD: Int32 = -1
    private var listenPort: UInt16 = 0

    // Active session state (protected by `lock`)
    private var sessionToken: String = ""
    private var sessionDirectory: URL?
    private var remuxTSFileURL: URL?
    private var localDirectFileURL: URL?
    private var segments: [HLSSegment] = []
    private var scanByteOffset: UInt64 = 0
    private var currentSegStartByte: UInt64 = 0
    private var currentSegStartPCR: Double = -1
    private var lastSeenPCR: Double = -1
    private var isRemuxFinished: Bool = false
    private var lastServedByteOffset: UInt64 = 0
    private var isRemuxPausedForBackpressure: Bool = false
    private var cachedSourceDuration: Double = 0

    // Managed on @MainActor
    private var remuxPlayer: VLCMediaPlayer?
    private var indexerTimer: DispatchSourceTimer?

    var bufferedDurationSeconds: Double {
        lock.lock()
        defer { lock.unlock() }
        return segments.reduce(0) { $0 + $1.duration }
    }

    var sourceDurationSeconds: Double {
        lock.lock()
        defer { lock.unlock() }
        return cachedSourceDuration
    }

    private override init() {
        super.init()
    }

    /// Starts serving a local downloaded file over LAN HTTP with byte-range support for AirPlay Video.
    @MainActor
    func startFileSession(localFileURL: URL) -> URL? {
        stopSession()
        guard ensureServerListening() else { return nil }

        let token = UUID().uuidString.lowercased()
        lock.lock()
        sessionToken = token
        localDirectFileURL = localFileURL
        lock.unlock()

        let ext = localFileURL.pathExtension.isEmpty ? "mp4" : localFileURL.pathExtension
        let host = Self.lanIPv4Address() ?? "127.0.0.1"
        return URL(string: "http://\(host):\(listenPort)/file/\(token)/video.\(ext)")
    }

    /// Starts an on-the-fly MKV/TS/AVI -> MPEG-TS HLS remux session served over LAN HTTP for AirPlay Video.
    @MainActor
    func startHLSRemuxSession(sourceURL: URL, startSeconds: Double) -> URL? {
        stopSession()
        guard ensureServerListening() else { return nil }

        let token = UUID().uuidString.lowercased()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("nucflix_cast_\(token)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        let tsFile = dir.appendingPathComponent("remux.ts")
        FileManager.default.createFile(atPath: tsFile.path, contents: nil)

        lock.lock()
        sessionToken = token
        sessionDirectory = dir
        remuxTSFileURL = tsFile
        localDirectFileURL = nil
        segments.removeAll()
        scanByteOffset = 0
        currentSegStartByte = 0
        currentSegStartPCR = -1
        lastSeenPCR = -1
        isRemuxFinished = false
        lastServedByteOffset = 0
        isRemuxPausedForBackpressure = false
        cachedSourceDuration = 0
        lock.unlock()

        let player = VLCMediaPlayer()
        let media = VLCMedia(url: sourceURL)
        media.addOption(":http-user-agent=IPTVSmartersPlayer/3.0 (iOS; iPhone; Scale/3.00)")
        media.addOption(":network-caching=1500")
        media.addOption(":sout-mux-caching=1500")
        media.addOption(":no-sout-all")
        media.addOption(":no-spu")
        if startSeconds > 5 {
            media.addOption(":start-time=\(Int(startSeconds))")
        }
        media.addOption(":sout=#std{access=file,mux=ts,dst='\(tsFile.path)'}")
        player.media = media
        player.delegate = self
        self.remuxPlayer = player
        player.play()

        let timer = DispatchSource.makeTimerSource(queue: clientQueue)
        timer.schedule(deadline: .now() + .milliseconds(200), repeating: .milliseconds(250))
        timer.setEventHandler { [weak self] in
            self?.scanRemuxFile()
        }
        timer.resume()
        self.indexerTimer = timer

        let host = Self.lanIPv4Address() ?? "127.0.0.1"
        return URL(string: "http://\(host):\(listenPort)/hls/\(token)/index.m3u8")
    }

    @MainActor
    func stopSession() {
        indexerTimer?.cancel()
        indexerTimer = nil

        if let player = remuxPlayer {
            player.delegate = nil
            player.stop()
            remuxPlayer = nil
        }

        lock.lock()
        let oldDir = sessionDirectory
        sessionToken = ""
        sessionDirectory = nil
        remuxTSFileURL = nil
        localDirectFileURL = nil
        segments.removeAll()
        scanByteOffset = 0
        currentSegStartByte = 0
        currentSegStartPCR = -1
        lastSeenPCR = -1
        isRemuxFinished = true
        lastServedByteOffset = 0
        isRemuxPausedForBackpressure = false
        cachedSourceDuration = 0
        lock.unlock()

        if let oldDir {
            clientQueue.async {
                try? FileManager.default.removeItem(at: oldDir)
            }
        }
    }

    // MARK: - VLCMediaPlayerDelegate

    func mediaPlayerTimeChanged(_ aNotification: Notification) {
        guard let player = aNotification.object as? VLCMediaPlayer else { return }
        let mediaLenMs = Double(player.media?.length.intValue ?? 0)
        if mediaLenMs > 1000 {
            lock.lock()
            cachedSourceDuration = mediaLenMs / 1000.0
            lock.unlock()
        }
    }

    func mediaPlayerStateChanged(_ aNotification: Notification) {
        guard let player = aNotification.object as? VLCMediaPlayer else { return }
        if player.state == .ended || player.state == .error || player.state == .stopped {
            lock.lock()
            isRemuxFinished = true
            lock.unlock()
            scanRemuxFile()
        }
    }

    // MARK: - MPEG-TS 188-Byte Packet & 90kHz PCR Segment Scanner

    private func scanRemuxFile() {
        lock.lock()
        guard let tsURL = remuxTSFileURL, !sessionToken.isEmpty else {
            lock.unlock()
            return
        }
        let finished = isRemuxFinished
        let startScan = scanByteOffset
        let lastServed = lastServedByteOffset
        let pausedForBackpressure = isRemuxPausedForBackpressure
        lock.unlock()

        guard let handle = try? FileHandle(forReadingFrom: tsURL) else { return }
        defer { try? handle.close() }

        let fileSize: UInt64
        if let end = try? handle.seekToEnd() {
            fileSize = end
        } else {
            return
        }

        // Backpressure control so 4K movies never fill up device storage
        let bufferedAhead = fileSize > lastServed ? (fileSize - lastServed) : 0
        if !finished {
            if !pausedForBackpressure && bufferedAhead > 180_000_000 {
                lock.lock()
                isRemuxPausedForBackpressure = true
                lock.unlock()
                Task { @MainActor in
                    self.remuxPlayer?.pause()
                }
            } else if pausedForBackpressure && bufferedAhead < 90_000_000 {
                lock.lock()
                isRemuxPausedForBackpressure = false
                lock.unlock()
                Task { @MainActor in
                    self.remuxPlayer?.play()
                }
            }
        }

        let alignedEnd = (fileSize / 188) * 188
        guard alignedEnd > startScan else {
            if finished {
                sealTrailingSegmentIfNeeded(alignedEnd: alignedEnd)
            }
            return
        }

        let bytesToRead = Int(min(alignedEnd - startScan, 4 * 1024 * 1024))
        guard bytesToRead >= 188 else { return }

        do {
            try handle.seek(toOffset: startScan)
            guard let chunk = try handle.read(upToCount: bytesToRead), chunk.count >= 188 else { return }

            lock.lock()
            defer { lock.unlock() }

            chunk.withUnsafeBytes { rawBuf in
                guard let base = rawBuf.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
                let packetCount = chunk.count / 188
                for i in 0..<packetCount {
                    let pktOffset = startScan + UInt64(i * 188)
                    let p = base.advanced(by: i * 188)
                    guard p[0] == 0x47 else { continue }

                    // Extract 33-bit 90kHz PCR if present in adaptation field
                    let afc = (p[3] >> 4) & 0x03
                    if (afc == 2 || afc == 3) && p[4] >= 7 && (p[5] & 0x10) != 0 {
                        let pcrBase = (UInt64(p[6]) << 25)
                                    | (UInt64(p[7]) << 17)
                                    | (UInt64(p[8]) << 9)
                                    | (UInt64(p[9]) << 1)
                                    | (UInt64(p[10]) >> 7)
                        let pcrSec = Double(pcrBase) / 90_000.0
                        if currentSegStartPCR < 0 {
                            currentSegStartPCR = pcrSec
                        }
                        if pcrSec >= currentSegStartPCR {
                            lastSeenPCR = pcrSec
                        }
                    }

                    // Check for PAT packet (PID == 0x0000 with Payload Unit Start Indicator == 1)
                    let isPAT = ((p[1] & 0x5F) == 0x40) && (p[2] == 0x00)
                    if isPAT && pktOffset > currentSegStartByte {
                        let byteLen = Int(pktOffset - currentSegStartByte)
                        let pcrDur = (currentSegStartPCR >= 0 && lastSeenPCR > currentSegStartPCR)
                            ? (lastSeenPCR - currentSegStartPCR)
                            : 0

                        if pcrDur >= 3.0 || (pcrDur <= 0 && byteLen >= 752_000) || byteLen >= 3_384_000 {
                            let clampedDur = (pcrDur >= 0.5 && pcrDur <= 7.8)
                                ? pcrDur
                                : min(max(Double(byteLen) / 380_000.0, 2.0), 6.0)
                            segments.append(
                                HLSSegment(
                                    index: segments.count,
                                    byteOffset: currentSegStartByte,
                                    byteLength: byteLen,
                                    duration: clampedDur
                                )
                            )
                            currentSegStartByte = pktOffset
                            currentSegStartPCR = lastSeenPCR
                        }
                    }
                }
                scanByteOffset = startScan + UInt64(packetCount * 188)
            }
        } catch {
            return
        }

        if finished {
            sealTrailingSegmentIfNeeded(alignedEnd: alignedEnd)
        }
    }

    private func sealTrailingSegmentIfNeeded(alignedEnd: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        guard isRemuxFinished, scanByteOffset >= alignedEnd, alignedEnd > currentSegStartByte else { return }
        let remBytes = Int(alignedEnd - currentSegStartByte)
        guard remBytes >= 188 else { return }
        let pcrDur = (currentSegStartPCR >= 0 && lastSeenPCR > currentSegStartPCR)
            ? (lastSeenPCR - currentSegStartPCR)
            : 0
        let dur = (pcrDur >= 0.2 && pcrDur <= 7.8)
            ? pcrDur
            : min(max(Double(remBytes) / 380_000.0, 1.0), 6.0)
        segments.append(
            HLSSegment(
                index: segments.count,
                byteOffset: currentSegStartByte,
                byteLength: remBytes,
                duration: dur
            )
        )
        currentSegStartByte = alignedEnd
    }

    // MARK: - Embedded POSIX HTTP Server for AirPlay Receiver Requests

    private func ensureServerListening() -> Bool {
        lock.lock()
        if listenFD >= 0 && listenPort > 0 {
            lock.unlock()
            return true
        }
        lock.unlock()

        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }

        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = INADDR_ANY

        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0, listen(fd, 32) == 0 else {
            close(fd)
            return false
        }

        var boundAddr = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &boundAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &len)
            }
        }
        let port = UInt16(bigEndian: boundAddr.sin_port)

        lock.lock()
        listenFD = fd
        listenPort = port
        lock.unlock()

        acceptQueue.async { [weak self] in
            self?.acceptLoop(serverFD: fd)
        }
        return true
    }

    private func acceptLoop(serverFD: Int32) {
        while true {
            var clientAddr = sockaddr_in()
            var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let clientFD = withUnsafeMutablePointer(to: &clientAddr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    accept(serverFD, $0, &addrLen)
                }
            }
            if clientFD < 0 {
                if errno == EINTR { continue }
                break
            }
            var noSigPipe: Int32 = 1
            setsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
            clientQueue.async { [weak self] in
                self?.handleHTTPClient(fd: clientFD)
            }
        }
    }

    private func handleHTTPClient(fd: Int32) {
        defer { close(fd) }

        var buffer = [UInt8](repeating: 0, count: 8192)
        let bytesRead = recv(fd, &buffer, buffer.count - 1, 0)
        guard bytesRead > 0 else { return }

        let requestString = String(decoding: buffer[0..<bytesRead], as: UTF8.self)
        let lines = requestString.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return }

        let method = String(parts[0]).uppercased()
        let rawPath = String(parts[1])
        let pathOnly = rawPath.split(separator: "?", maxSplits: 1).first.map(String.init) ?? rawPath

        if method == "OPTIONS" {
            let resp = "HTTP/1.1 200 OK\r\nAccess-Control-Allow-Origin: *\r\nAccess-Control-Allow-Methods: GET, HEAD, OPTIONS\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            sendAll(fd: fd, data: Data(resp.utf8))
            return
        }

        var rangeHeader: String?
        for line in lines.dropFirst() {
            if line.lowercased().hasPrefix("range:") {
                rangeHeader = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
                break
            }
        }

        let comps = pathOnly.split(separator: "/").map(String.init)
        guard comps.count >= 3 else {
            sendNotFound(fd: fd)
            return
        }

        let mode = comps[0]
        let reqToken = comps[1]
        let resource = comps[2]

        lock.lock()
        let activeToken = sessionToken
        lock.unlock()

        guard !activeToken.isEmpty, reqToken == activeToken else {
            sendNotFound(fd: fd)
            return
        }

        if mode == "file" {
            serveDirectFile(fd: fd, method: method, rangeHeader: rangeHeader)
        } else if mode == "hls" {
            if resource == "index.m3u8" {
                serveHLSPlaylist(fd: fd, method: method, token: reqToken)
            } else if resource.hasPrefix("seg_"), resource.hasSuffix(".ts") {
                let idxStr = resource.dropFirst(4).dropLast(3)
                if let segIndex = Int(idxStr) {
                    serveHLSSegment(fd: fd, method: method, segIndex: segIndex, rangeHeader: rangeHeader)
                } else {
                    sendNotFound(fd: fd)
                }
            } else {
                sendNotFound(fd: fd)
            }
        } else {
            sendNotFound(fd: fd)
        }
    }

    private func serveHLSPlaylist(fd: Int32, method: String, token: String) {
        // Wait up to ~7.5s on initial request so at least 2 segments (or finished stream) are ready for AirPlay TV
        for _ in 0..<50 {
            scanRemuxFile()
            lock.lock()
            let currentToken = sessionToken
            let segCount = segments.count
            let finished = isRemuxFinished
            lock.unlock()

            if currentToken != token {
                sendNotFound(fd: fd)
                return
            }
            if segCount >= 2 || (segCount >= 1 && finished) {
                break
            }
            usleep(150_000)
        }

        lock.lock()
        let currentSegments = segments
        let finished = isRemuxFinished
        lock.unlock()

        guard !currentSegments.isEmpty else {
            sendNotFound(fd: fd)
            return
        }

        var m3u8 = "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:8\n#EXT-X-MEDIA-SEQUENCE:0\n#EXT-X-PLAYLIST-TYPE:EVENT\n"
        for seg in currentSegments {
            m3u8 += String(format: "#EXTINF:%.3f,\nseg_%d.ts\n", seg.duration, seg.index)
        }
        if finished {
            m3u8 += "#EXT-X-ENDLIST\n"
        }

        let body = Data(m3u8.utf8)
        let header = "HTTP/1.1 200 OK\r\nContent-Type: application/vnd.apple.mpegurl\r\nContent-Length: \(body.count)\r\nCache-Control: no-cache, no-store, must-revalidate\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n"
        sendAll(fd: fd, data: Data(header.utf8))
        if method != "HEAD" {
            sendAll(fd: fd, data: body)
        }
    }

    private func serveHLSSegment(fd: Int32, method: String, segIndex: Int, rangeHeader: String?) {
        lock.lock()
        guard let tsURL = remuxTSFileURL, segIndex >= 0, segIndex < segments.count else {
            lock.unlock()
            sendNotFound(fd: fd)
            return
        }
        let seg = segments[segIndex]
        if seg.byteOffset + UInt64(seg.byteLength) > lastServedByteOffset {
            lastServedByteOffset = seg.byteOffset + UInt64(seg.byteLength)
        }
        lock.unlock()

        serveByteSlice(
            fd: fd,
            method: method,
            fileURL: tsURL,
            baseOffset: seg.byteOffset,
            totalLength: UInt64(seg.byteLength),
            contentType: "video/mp2t",
            rangeHeader: rangeHeader
        )
    }

    private func serveDirectFile(fd: Int32, method: String, rangeHeader: String?) {
        lock.lock()
        let fileURL = localDirectFileURL
        lock.unlock()

        guard let fileURL,
              let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let fileSize = (attrs[.size] as? NSNumber)?.uint64Value,
              fileSize > 0 else {
            sendNotFound(fd: fd)
            return
        }

        serveByteSlice(
            fd: fd,
            method: method,
            fileURL: fileURL,
            baseOffset: 0,
            totalLength: fileSize,
            contentType: "video/mp4",
            rangeHeader: rangeHeader
        )
    }

    private func serveByteSlice(
        fd: Int32,
        method: String,
        fileURL: URL,
        baseOffset: UInt64,
        totalLength: UInt64,
        contentType: String,
        rangeHeader: String?
    ) {
        guard totalLength > 0, let handle = try? FileHandle(forReadingFrom: fileURL) else {
            sendNotFound(fd: fd)
            return
        }
        defer { try? handle.close() }

        var rangeStart: UInt64 = 0
        var rangeEnd: UInt64 = totalLength - 1
        var isPartial = false

        if let rangeHeader, rangeHeader.lowercased().hasPrefix("bytes=") {
            let spec = rangeHeader.dropFirst(6)
            let bounds = spec.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
            if bounds.count == 2 {
                if let s = UInt64(bounds[0]), s < totalLength {
                    rangeStart = s
                    if let e = UInt64(bounds[1]), e >= s && e < totalLength {
                        rangeEnd = e
                    }
                    isPartial = true
                }
            }
        }

        let contentLen = rangeEnd - rangeStart + 1
        let statusLine = isPartial ? "HTTP/1.1 206 Partial Content" : "HTTP/1.1 200 OK"
        var header = "\(statusLine)\r\nContent-Type: \(contentType)\r\nAccept-Ranges: bytes\r\nContent-Length: \(contentLen)\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n"
        if isPartial {
            header += "Content-Range: bytes \(rangeStart)-\(rangeEnd)/\(totalLength)\r\n"
        }
        header += "\r\n"

        sendAll(fd: fd, data: Data(header.utf8))
        guard method != "HEAD" else { return }

        do {
            try handle.seek(toOffset: baseOffset + rangeStart)
            var remaining = contentLen
            let chunkSize: UInt64 = 65_536
            while remaining > 0 {
                let toRead = Int(min(remaining, chunkSize))
                guard let chunk = try handle.read(upToCount: toRead), !chunk.isEmpty else { break }
                if !sendAll(fd: fd, data: chunk) { break }
                remaining -= UInt64(chunk.count)
            }
        } catch {
            return
        }
    }

    private func sendNotFound(fd: Int32) {
        let resp = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        sendAll(fd: fd, data: Data(resp.utf8))
    }

    @discardableResult
    private func sendAll(fd: Int32, data: Data) -> Bool {
        return data.withUnsafeBytes { rawBuf -> Bool in
            guard let base = rawBuf.baseAddress else { return false }
            var totalSent = 0
            while totalSent < data.count {
                let sent = send(fd, base.advanced(by: totalSent), data.count - totalSent, 0)
                if sent <= 0 {
                    if errno == EINTR { continue }
                    return false
                }
                totalSent += sent
            }
            return true
        }
    }

    /// Returns the iPhone's active Wi-Fi / LAN IPv4 address (e.g. `192.168.1.x`) so the AirPlay TV can reach the server.
    static func lanIPv4Address() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        var wifiIP: String?
        var fallbackIP: String?

        var ptr: UnsafeMutablePointer<ifaddrs>? = firstAddr
        while let current = ptr {
            let interface = current.pointee
            let flags = Int32(interface.ifa_flags)
            if (flags & IFF_UP) != 0 && (flags & IFF_LOOPBACK) == 0,
               let addr = interface.ifa_addr,
               addr.pointee.sa_family == UInt8(AF_INET) {
                var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(
                    addr,
                    socklen_t(addr.pointee.sa_len),
                    &hostname,
                    socklen_t(hostname.count),
                    nil,
                    0,
                    NI_NUMERICHOST
                ) == 0 {
                    let ip = String(cString: hostname)
                    let name = String(cString: interface.ifa_name)
                    if name == "en0" {
                        wifiIP = ip
                        break
                    } else if name.hasPrefix("en") || name.hasPrefix("bridge") {
                        fallbackIP = fallbackIP ?? ip
                    }
                }
            }
            ptr = interface.ifa_next
        }
        return wifiIP ?? fallbackIP
    }
}
