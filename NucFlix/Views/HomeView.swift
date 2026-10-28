import SwiftUI

/// Netflix-style tactile press feedback for poster tiles (subtle scale + dim, springy release)
struct PressableCardStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// Download count badge that observes DownloadManager in isolation so progress ticks
/// don't re-render the entire Home screen.
private struct HomeDownloadCountBadge: View {
    private var downloadManager = DownloadManager.shared

    var body: some View {
        let totalCount = downloadManager.activeDownloads.count + downloadManager.queuedDownloads.count + downloadManager.downloadedItems.count
        if totalCount > 0 {
            Text("\(totalCount)")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white)
                .frame(minWidth: 15, minHeight: 15)
                .padding(.horizontal, 2)
                .background(AppTheme.netflixRed, in: Capsule())
                .offset(x: 6, y: -5)
                .contentTransition(.numericText())
                .animation(.snappy, value: totalCount)
        }
    }
}

struct HomeView: View {
    @Environment(AppState.self) var appState
    @Environment(CloudAccount.self) var cloud
    private var notificationManager = NotificationManager.shared
    @Binding var selectedTab: MainTab
    @State private var showDownloadsSheet: Bool = false
    @State private var showSettingsSheet: Bool = false
    @State private var showNotificationsSheet: Bool = false
    /// Ambient top wash tinted by the current hero artwork (Netflix-style dynamic background)
    @State private var heroAmbientColor: Color = Color(red: 0.24, green: 0.13, blue: 0.09)

    /// Pick a featured title with a clean vertical poster for the Billboard
    private var featuredHeroMovie: XtreamVODStream? {
        appState.featuredMovies.first
    }

    private var featuredHeroSeries: XtreamSeries? {
        if appState.spotlightSeries.count > 1 {
            return appState.spotlightSeries[1]
        }
        return appState.spotlightSeries.first ?? appState.featuredSeries.first
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                Color.black.ignoresSafeArea()

                // Warm Ambient Top Color Wash (Matches Real Netflix iOS Top Bleed)
                LinearGradient(
                    colors: [
                        heroAmbientColor,
                        heroAmbientColor.opacity(0.55),
                        heroAmbientColor.opacity(0.18),
                        Color.black
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 680)
                .ignoresSafeArea()
                .animation(.easeInOut(duration: 1.2), value: heroAmbientColor)

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 18) {
                        netflixTopHeader

                        netflixFilterRow

                        let feed = appState.homeFeed

                        // Dynamic, personalized hero carousel (auto-rotates, swipeable)
                        if !feed.heroPicks.isEmpty {
                            PersonalizedHeroCarousel(picks: feed.heroPicks, ambientColor: $heroAmbientColor)
                        } else if let movie = featuredHeroMovie {
                            netflixMovieBillboardCard(movie: movie)
                        } else if let series = featuredHeroSeries {
                            netflixSeriesBillboardCard(series: series)
                        } else {
                            billboardSkeleton
                        }

                        // Continue Watching sits high, like Netflix
                        if !appState.visibleWatchHistory.isEmpty {
                            continueWatchingNetflixRow
                        }

                        if feed.rails.isEmpty {
                            // Fallback until the recommender has data
                            if !appState.featuredMovies.isEmpty {
                                onlyOnNucFlixRow(
                                    movies: Array(appState.featuredMovies.dropFirst().prefix(12))
                                )
                            }
                            if !appState.featuredSeries.isEmpty {
                                trendingSeriesRow(
                                    seriesList: appState.featuredSeries
                                )
                            }
                        } else {
                            // Personalized rails — first two, then Live TV, then the rest
                            ForEach(feed.rails.prefix(2)) { rail in
                                PersonalizedRailView(rail: rail)
                            }
                        }

                        // "Live TV • Streaming Now"
                        if !appState.featuredLiveChannels.isEmpty {
                            liveNowNetflixRow(
                                title: "Live TV • Streaming Now",
                                channels: appState.featuredLiveChannels
                            )
                        }

                        ForEach(feed.rails.dropFirst(2)) { rail in
                            PersonalizedRailView(rail: rail)
                        }

                        // Row 5: "My List"
                        if !appState.visibleFavoriteMovies.isEmpty {
                            onlyOnNucFlixRow(
                                title: "My List",
                                movies: appState.visibleFavoriteMovies,
                                showTop10Badge: false
                            )
                        }
                    }
                    .padding(.bottom, 36)
                }
                .refreshable {
                    await appState.refreshAllCatalogs(force: true)
                }
            }
            .onAppear {
                // Fresh ordering each time Home is revisited after a while
                if Date().timeIntervalSince(appState.homeFeed.generatedAt) > 600 {
                    appState.scheduleHomeFeedRebuild(delay: 0, reshuffle: true)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showDownloadsSheet) {
                DownloadsView()
                    .environment(appState)
            }
            .sheet(isPresented: $showSettingsSheet) {
                AccountView()
                    .environment(appState)
                    .environment(cloud)
            }
            .sheet(isPresented: $showNotificationsSheet) {
                NotificationsView()
                    .environment(appState)
            }
        }
    }

    // MARK: - Authentic Netflix iOS Header ("N NucFlix" + Download, Setting, Notifications)

    private var netflixTopHeader: some View {
        HStack(spacing: 10) {
            NucFlixLogoBadge(size: 32)

            Text("NucFlix")
                .font(.system(size: 25, weight: .bold))
                .foregroundStyle(.white)

            Spacer()

            HStack(spacing: 22) {
                // 1. Download Icon
                Button {
                    showDownloadsSheet = true
                } label: {
                    ZStack(alignment: .topTrailing) {
                        Image(systemName: "arrow.down.to.line")
                            .font(.system(size: 19, weight: .medium))
                            .foregroundStyle(.white)

                        // Isolated observer: only this badge re-renders on download progress ticks
                        HomeDownloadCountBadge()
                    }
                }
                .accessibilityLabel("Downloads")

                // 2. Setting Icon
                Button {
                    showSettingsSheet = true
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 19, weight: .medium))
                        .foregroundStyle(.white)
                }

                // 3. Notifications Icon
                Button {
                    showNotificationsSheet = true
                } label: {
                    ZStack(alignment: .topTrailing) {
                        Image(systemName: "bell")
                            .font(.system(size: 19, weight: .medium))
                            .foregroundStyle(.white)

                        let unread = notificationManager.unreadCount
                        if unread > 0 {
                            Text("\(unread)")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(minWidth: 15, minHeight: 15)
                                .padding(.horizontal, 2)
                                .background(AppTheme.netflixRed, in: Capsule())
                                .offset(x: 5, y: -5)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 6)
    }

    // MARK: - Authentic Netflix Frosted Rounded-Rect Filter Buttons

    private var netflixFilterRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 9) {
                frostedFilterButton("Live TV") {
                    selectedTab = .liveTV
                }
                frostedFilterButton("Shows") {
                    selectedTab = .series
                }
                frostedFilterButton("Movies") {
                    selectedTab = .movies
                }
                frostedFilterButton("Cricket") {
                    if let cricketCat = appState.liveCategories.first(where: { $0.categoryName.localizedCaseInsensitiveContains("CRICKET") }) {
                        appState.selectLiveCategory(cricketCat.id)
                    }
                    selectedTab = .liveTV
                }
                frostedFilterButton("New") {
                    selectedTab = .movies
                }
            }
            .padding(.horizontal, 18)
        }
    }

    private func frostedFilterButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .background(
                    Color.white.opacity(0.14),
                    in: RoundedRectangle(cornerRadius: 11, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .stroke(Color.white.opacity(0.18), lineWidth: 0.7)
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Authentic Netflix Framed Billboard Card (Capsule Buttons + Top-Left N Ribbon)

    private func netflixMovieBillboardCard(movie: XtreamVODStream) -> some View {
        ZStack(alignment: .bottom) {
            ArtworkImageView(
                urlString: movie.streamIcon,
                fallbackTitle: movie.cleanName,
                fallbackIcon: "film"
            )
            .frame(maxWidth: .infinity)
            .frame(height: 495)

            // Top-Left Authentic 3D Red "N" Ribbon
            VStack {
                HStack {
                    NucFlixLogoBadge(size: 28)
                        .padding(.top, 18)
                        .padding(.leading, 18)
                    Spacer()
                }
                Spacer()
            }

            // Bottom Vignette Gradient
            LinearGradient(
                colors: [
                    .clear,
                    .clear,
                    .black.opacity(0.65),
                    .black.opacity(0.95)
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            // Bottom Metadata & Capsule Pill Buttons
            VStack(spacing: 14) {
                Text(movie.cleanName)
                    .font(.system(size: 28, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.8), radius: 6, y: 2)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .padding(.horizontal, 18)

                // "Film • Drama • Thriller • 4K UHD"
                HStack(spacing: 6) {
                    Text("Film")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                    bulletDot
                    Text("New Release")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(.white.opacity(0.92))
                    bulletDot
                    Text("Cinema")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(.white.opacity(0.92))
                    bulletDot
                    Text("HD")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(.white.opacity(0.92))
                }

                // Capsule-Shaped White "Play Movie" & Frosted Gray "+ My List" Buttons
                HStack(spacing: 12) {
                    NavigationLink {
                        MovieDetailView(movie: movie)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "play.fill")
                                .font(.system(size: 16, weight: .bold))
                            Text("Play Movie")
                                .font(.system(size: 15, weight: .bold))
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .background(Color.white, in: Capsule())
                        .foregroundStyle(.black)
                    }

                    Button {
                        appState.toggleFavoriteMovie(movie)
                    } label: {
                        let isFav = appState.isFavoriteMovie(movie.streamId.value)
                        HStack(spacing: 8) {
                            Image(systemName: isFav ? "checkmark" : "plus")
                                .font(.system(size: 16, weight: .medium))
                            Text("My List")
                                .font(.system(size: 15, weight: .bold))
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .background(Color.white.opacity(0.22), in: Capsule())
                        .overlay(
                            Capsule().stroke(Color.white.opacity(0.22), lineWidth: 0.7)
                        )
                        .foregroundStyle(.white)
                    }
                }
                .padding(.horizontal, 16)
            }
            .padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 495)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.22), lineWidth: 0.8)
        )
        .shadow(color: .black.opacity(0.75), radius: 18, y: 8)
        .padding(.horizontal, 18)
    }

    private func netflixSeriesBillboardCard(series: XtreamSeries) -> some View {
        ZStack(alignment: .bottom) {
            ArtworkImageView(
                urlString: series.cover ?? series.backdropPath?.values.first,
                fallbackTitle: series.cleanName,
                fallbackIcon: "tv"
            )
            .frame(maxWidth: .infinity)
            .frame(height: 495)

            VStack {
                HStack {
                    NucFlixLogoBadge(size: 28)
                        .padding(.top, 18)
                        .padding(.leading, 18)
                    Spacer()
                }
                Spacer()
            }

            LinearGradient(
                colors: [
                    .clear,
                    .clear,
                    .black.opacity(0.65),
                    .black.opacity(0.95)
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            VStack(spacing: 14) {
                Text(series.cleanName)
                    .font(.system(size: 28, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.8), radius: 6, y: 2)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .padding(.horizontal, 18)

                HStack(spacing: 6) {
                    Text("Show")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                    ForEach(Array(buildBillboardTags(for: series).enumerated()), id: \.offset) { _, tag in
                        bulletDot
                        Text(tag)
                            .font(.system(size: 13, weight: .regular))
                            .foregroundStyle(.white.opacity(0.92))
                    }
                }

                HStack(spacing: 12) {
                    NavigationLink {
                        SeriesDetailView(series: series)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "play.fill")
                                .font(.system(size: 16, weight: .bold))
                            Text("Play Show")
                                .font(.system(size: 15, weight: .bold))
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .background(Color.white, in: Capsule())
                        .foregroundStyle(.black)
                    }

                    Button {
                        appState.toggleFavoriteSeries(series)
                    } label: {
                        let isFav = appState.isFavoriteSeries(series.seriesId.value)
                        HStack(spacing: 8) {
                            Image(systemName: isFav ? "checkmark" : "plus")
                                .font(.system(size: 16, weight: .medium))
                            Text("My List")
                                .font(.system(size: 15, weight: .bold))
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .background(Color.white.opacity(0.22), in: Capsule())
                        .overlay(
                            Capsule().stroke(Color.white.opacity(0.22), lineWidth: 0.7)
                        )
                        .foregroundStyle(.white)
                    }
                }
                .padding(.horizontal, 16)
            }
            .padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 495)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.22), lineWidth: 0.8)
        )
        .shadow(color: .black.opacity(0.75), radius: 18, y: 8)
        .padding(.horizontal, 18)
    }

    private var bulletDot: some View {
        Circle()
            .fill(Color.white.opacity(0.55))
            .frame(width: 4, height: 4)
    }

    private func buildBillboardTags(for series: XtreamSeries) -> [String] {
        var result: [String] = []
        if let genre = series.genre, !genre.isEmpty {
            let parts = genre
                .replacingOccurrences(of: "/", with: ",")
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            result.append(contentsOf: parts.prefix(3))
        }
        if result.isEmpty {
            result = ["Drama", "Thriller", "4K"]
        }
        return result
    }

    private var billboardSkeleton: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(AppTheme.cardSurface)
                .frame(height: 495)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.white.opacity(0.15), lineWidth: 0.8)
                )

            VStack(spacing: 12) {
                ProgressView()
                    .tint(AppTheme.netflixRed)
                    .scaleEffect(1.3)
                Text("Loading NucFlix...")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
        .padding(.horizontal, 18)
    }

    // MARK: - "Only on NucFlix" Row (Matches "Only on Netflix" in Screenshot 1!)

    private func onlyOnNucFlixRow(
        title: String = "Only on NucFlix",
        movies: [XtreamVODStream],
        showTop10Badge: Bool = true
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 19, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 18)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 10) {
                    ForEach(Array(movies.enumerated()), id: \.element.id) { index, movie in
                        NavigationLink {
                            MovieDetailView(movie: movie)
                        } label: {
                            ZStack(alignment: .topLeading) {
                                ArtworkImageView(
                                    urlString: movie.streamIcon,
                                    fallbackTitle: movie.cleanName,
                                    fallbackIcon: "film"
                                )
                                .frame(width: 148, height: 210)
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                                if showTop10Badge && index > 0 && index <= 6 {
                                    NetflixTop10CornerBadge()
                                        .padding(6)
                                } else {
                                    NucFlixLogoBadge(size: 18)
                                        .padding(8)
                                }
                            }
                            .frame(width: 148, height: 210)
                        }
                        .buttonStyle(PressableCardStyle())
                    }
                }
                .padding(.horizontal, 18)
            }
        }
    }

    // MARK: - "Trending Shows" Row

    private func trendingSeriesRow(seriesList: [XtreamSeries]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Trending Shows")
                .font(.system(size: 19, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 18)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 10) {
                    ForEach(Array(seriesList.enumerated()), id: \.element.id) { index, series in
                        NavigationLink {
                            SeriesDetailView(series: series)
                        } label: {
                            ZStack(alignment: .topLeading) {
                                ArtworkImageView(
                                    urlString: series.cover,
                                    fallbackTitle: series.cleanName,
                                    fallbackIcon: "tv"
                                )
                                .frame(width: 148, height: 210)
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                                if index < 4 {
                                    NetflixTop10CornerBadge()
                                        .padding(6)
                                } else {
                                    NucFlixLogoBadge(size: 18)
                                        .padding(8)
                                }
                            }
                            .frame(width: 148, height: 210)
                        }
                        .buttonStyle(PressableCardStyle())
                    }
                }
                .padding(.horizontal, 18)
            }
        }
    }

    // MARK: - "Live TV • Streaming Now" Row

    private func liveNowNetflixRow(title: String, channels: [XtreamLiveStream]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title)
                    .font(.system(size: 19, weight: .bold))
                    .foregroundStyle(.white)
                Spacer()
                Button("See All") {
                    selectedTab = .liveTV
                }
                .font(.caption.weight(.bold))
                .foregroundStyle(.white.opacity(0.6))
            }
            .padding(.horizontal, 18)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 10) {
                    ForEach(channels) { channel in
                        Button {
                            appState.startPlayback(.fromLive(channel))
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                ZStack(alignment: .topLeading) {
                                    ArtworkImageView(
                                        urlString: channel.streamIcon,
                                        fallbackTitle: channel.cleanName,
                                        fallbackIcon: "tv",
                                        contentMode: .fit
                                    )
                                    .padding(14)
                                    .frame(width: 158, height: 96)
                                    .background(AppTheme.cardSurface)
                                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                                    LivePulseBadge()
                                        .padding(7)
                                }

                                Text(channel.cleanName)
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundStyle(.white)
                                    .lineLimit(1)
                            }
                            .frame(width: 158)
                        }
                        .buttonStyle(PressableCardStyle())
                    }
                }
                .padding(.horizontal, 18)
            }
        }
    }

    // MARK: - "Continue Watching" Row

    private var continueWatchingNetflixRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Continue Watching")
                    .font(.system(size: 19, weight: .bold))
                    .foregroundStyle(.white)
                Spacer()
                Button("Clear") {
                    appState.clearWatchHistory()
                }
                .font(.caption.weight(.bold))
                .foregroundStyle(.white.opacity(0.6))
            }
            .padding(.horizontal, 18)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 10) {
                    ForEach(appState.visibleWatchHistory.prefix(20)) { entry in
                        Button {
                            appState.startPlayback(entry.toPlaybackItem())
                        } label: {
                            VStack(spacing: 0) {
                                ZStack {
                                    ArtworkImageView(
                                        urlString: entry.artworkURL,
                                        fallbackTitle: entry.title,
                                        fallbackIcon: "play.tv",
                                        contentMode: entry.contentType == .live ? .fit : .fill
                                    )
                                    .frame(width: 132, height: 172)
                                    .background(AppTheme.cardSurface)

                                    Circle()
                                        .fill(.black.opacity(0.65))
                                        .frame(width: 44, height: 44)
                                        .overlay(
                                            Circle().stroke(Color.white, lineWidth: 1.5)
                                        )
                                        .overlay(
                                            Image(systemName: "play.fill")
                                                .font(.system(size: 16, weight: .bold))
                                                .foregroundStyle(.white)
                                                .offset(x: 1)
                                        )
                                }
                                .frame(width: 132, height: 172)

                                GeometryReader { geo in
                                    ZStack(alignment: .leading) {
                                        Rectangle()
                                            .fill(Color(white: 0.28))
                                        Rectangle()
                                            .fill(AppTheme.netflixRed)
                                            .frame(width: geo.size.width * max(entry.progressFraction, 0.2))
                                    }
                                }
                                .frame(width: 132, height: 3)

                                HStack {
                                    Text(XtreamTextFormatter.format(entry.title).cleanTitle)
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(.white.opacity(0.85))
                                        .lineLimit(1)
                                    Spacer()
                                }
                                .padding(.horizontal, 8)
                                .frame(width: 132, height: 30)
                                .background(Color(white: 0.10))
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 18)
            }
        }
    }
}


// MARK: - Personalized Hero Carousel

/// Auto-rotating, swipeable Netflix billboard driven by the recommendation engine.
/// Features a slow Ken Burns push-in, reason labels ("Because you watched…"), page indicators,
/// pause-on-touch, and publishes the artwork's dominant colour for the ambient background wash.
private struct PersonalizedHeroCarousel: View {
    @Environment(AppState.self) var appState
    let picks: [HeroPick]
    @Binding var ambientColor: Color

    @State private var selection: String = ""
    @State private var isInteracting = false
    @State private var kenBurns = false

    private let rotationInterval: UInt64 = 7_000_000_000

    private var currentIndex: Int {
        picks.firstIndex(where: { $0.id == selection }) ?? 0
    }

    var body: some View {
        VStack(spacing: 12) {
            TabView(selection: $selection) {
                ForEach(picks) { pick in
                    heroCard(pick)
                        .tag(pick.id)
                        .padding(.horizontal, 18)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .frame(height: 510)
            .simultaneousGesture(
                DragGesture(minimumDistance: 8)
                    .onChanged { _ in isInteracting = true }
                    .onEnded { _ in isInteracting = false }
            )

            // Netflix-style page indicators
            HStack(spacing: 6) {
                ForEach(picks) { pick in
                    Capsule()
                        .fill(pick.id == selection ? Color.white : Color.white.opacity(0.3))
                        .frame(width: pick.id == selection ? 18 : 6, height: 6)
                }
            }
            .animation(.snappy, value: selection)
        }
        .onAppear {
            if selection.isEmpty || !picks.contains(where: { $0.id == selection }) {
                selection = picks.first?.id ?? ""
            }
        }
        .onChange(of: picks.map(\.id)) { _, ids in
            if !ids.contains(selection) {
                selection = ids.first ?? ""
            }
        }
        // Auto-advance; restarts whenever the page changes (manual swipe resets the timer)
        .task(id: selection) {
            kenBurns = false
            withAnimation(.linear(duration: 7.5)) { kenBurns = true }
            await updateAmbientColor()
            try? await Task.sleep(nanoseconds: rotationInterval)
            guard !Task.isCancelled, !isInteracting, picks.count > 1 else { return }
            let next = picks[(currentIndex + 1) % picks.count].id
            withAnimation(.easeInOut(duration: 0.6)) {
                selection = next
            }
        }
        .sensoryFeedback(.selection, trigger: selection)
    }

    @ViewBuilder
    private func heroCard(_ pick: HeroPick) -> some View {
        ZStack(alignment: .bottom) {
            NavigationLink {
                destination(for: pick.item)
            } label: {
                ArtworkImageView(
                    urlString: pick.item.posterURL,
                    fallbackTitle: pick.item.title,
                    fallbackIcon: "film",
                    maxPixelSize: 1300
                )
                .frame(maxWidth: .infinity)
                .frame(height: 495)
                .scaleEffect(pick.id == selection && kenBurns ? 1.08 : 1.0, anchor: .center)
                .clipped()
            }
            .buttonStyle(.plain)

            VStack {
                HStack {
                    NucFlixLogoBadge(size: 28)
                        .padding(.top, 18)
                        .padding(.leading, 18)
                    Spacer()
                }
                Spacer()
            }
            .allowsHitTesting(false)

            LinearGradient(
                colors: [.clear, .clear, .black.opacity(0.65), .black.opacity(0.95)],
                startPoint: .top,
                endPoint: .bottom
            )
            .allowsHitTesting(false)

            VStack(spacing: 12) {
                // Why it's recommended
                Text(pick.reason.uppercased())
                    .font(.system(size: 11, weight: .heavy))
                    .tracking(1.2)
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(AppTheme.netflixRed.opacity(0.9), in: RoundedRectangle(cornerRadius: 4))
                    .lineLimit(1)
                    .padding(.horizontal, 18)

                Text(pick.item.title)
                    .font(.system(size: 28, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.8), radius: 6, y: 2)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .padding(.horizontal, 18)

                if !pick.tags.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(Array(pick.tags.enumerated()), id: \.offset) { index, tag in
                            if index > 0 {
                                Circle().fill(Color.white.opacity(0.55)).frame(width: 4, height: 4)
                            }
                            Text(tag)
                                .font(.system(size: 13, weight: index == 0 ? .bold : .regular))
                                .foregroundStyle(.white.opacity(index == 0 ? 1 : 0.92))
                                .lineLimit(1)
                        }
                    }
                    .padding(.horizontal, 18)
                }

                HStack(spacing: 12) {
                    playButton(for: pick.item)
                    myListButton(for: pick.item)
                }
                .padding(.horizontal, 16)
            }
            .padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 495)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.22), lineWidth: 0.8)
        )
        .shadow(color: .black.opacity(0.75), radius: 18, y: 8)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func destination(for item: FeedItem) -> some View {
        switch item {
        case .movie(let m): MovieDetailView(movie: m)
        case .series(let s): SeriesDetailView(series: s)
        }
    }

    @ViewBuilder
    private func playButton(for item: FeedItem) -> some View {
        let label = HStack(spacing: 8) {
            Image(systemName: "play.fill")
                .font(.system(size: 16, weight: .bold))
            Text("Play")
                .font(.system(size: 15, weight: .bold))
        }
        .frame(maxWidth: .infinity)
        .frame(height: 44)
        .background(Color.white, in: Capsule())
        .foregroundStyle(.black)

        switch item {
        case .movie(let m):
            Button {
                appState.startPlayback(.fromMovie(m))
            } label: { label }
            .buttonStyle(PressableCardStyle())
        case .series(let s):
            NavigationLink {
                SeriesDetailView(series: s)
            } label: { label }
            .buttonStyle(PressableCardStyle())
        }
    }

    private func myListButton(for item: FeedItem) -> some View {
        let isFav: Bool = {
            switch item {
            case .movie(let m): return appState.isFavoriteMovie(m.streamId.value)
            case .series(let s): return appState.isFavoriteSeries(s.seriesId.value)
            }
        }()
        return Button {
            switch item {
            case .movie(let m): appState.toggleFavoriteMovie(m)
            case .series(let s): appState.toggleFavoriteSeries(s)
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isFav ? "checkmark" : "plus")
                    .font(.system(size: 16, weight: .medium))
                    .contentTransition(.symbolEffect(.replace))
                Text("My List")
                    .font(.system(size: 15, weight: .bold))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .background(Color.white.opacity(0.22), in: Capsule())
            .overlay(Capsule().stroke(Color.white.opacity(0.22), lineWidth: 0.7))
            .foregroundStyle(.white)
        }
        .buttonStyle(PressableCardStyle())
        .sensoryFeedback(.success, trigger: isFav)
    }

    private func updateAmbientColor() async {
        guard let pick = picks.first(where: { $0.id == selection }) ?? picks.first,
              let url = ImageCacheManager.artworkURL(from: pick.item.posterURL),
              let image = await ImageCacheManager.shared.image(for: url, maxPixelSize: 1300) else { return }
        let color = await Task.detached(priority: .utility) { image.nucflixAmbientColor() }.value
        if let color, !Task.isCancelled {
            ambientColor = Color(uiColor: color)
        }
    }
}

// MARK: - Personalized Rail

private struct PersonalizedRailView: View {
    let rail: HomeRail

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(rail.title)
                .font(.system(size: 19, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.horizontal, 18)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: rail.style == .top10 ? 4 : 10) {
                    ForEach(Array(rail.items.enumerated()), id: \.element.id) { index, item in
                        NavigationLink {
                            switch item {
                            case .movie(let m): MovieDetailView(movie: m)
                            case .series(let s): SeriesDetailView(series: s)
                            }
                        } label: {
                            if rail.style == .top10 {
                                top10Tile(item, rank: index + 1)
                            } else {
                                posterTile(item)
                            }
                        }
                        .buttonStyle(PressableCardStyle())
                    }
                }
                .padding(.horizontal, 18)
            }
        }
        .transition(.opacity)
    }

    private func posterTile(_ item: FeedItem) -> some View {
        ZStack(alignment: .topLeading) {
            ArtworkImageView(
                urlString: item.posterURL,
                fallbackTitle: item.title,
                fallbackIcon: "film",
                maxPixelSize: 600
            )
            .frame(width: 118, height: 170)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            NucFlixLogoBadge(size: 16)
                .padding(6)
        }
        .frame(width: 118, height: 170)
    }

    /// Netflix "Top 10" tile: giant outlined rank numeral beside the poster
    private func top10Tile(_ item: FeedItem, rank: Int) -> some View {
        HStack(alignment: .bottom, spacing: -18) {
            Text("\(rank)")
                .font(.system(size: 120, weight: .black, design: .rounded))
                .foregroundStyle(.black)
                .shadow(color: .white.opacity(0.9), radius: 0, x: 1.5, y: 1.5)
                .shadow(color: .white.opacity(0.9), radius: 0, x: -1.5, y: -1.5)
                .shadow(color: .white.opacity(0.9), radius: 0, x: 1.5, y: -1.5)
                .shadow(color: .white.opacity(0.9), radius: 0, x: -1.5, y: 1.5)
                .frame(width: rank >= 10 ? 110 : 70, alignment: .trailing)
                .offset(y: 18)

            ArtworkImageView(
                urlString: item.posterURL,
                fallbackTitle: item.title,
                fallbackIcon: "tv",
                maxPixelSize: 600
            )
            .frame(width: 118, height: 170)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .frame(height: 175)
    }
}

// MARK: - Dominant Colour Extraction

extension UIImage {
    /// Averages the image down to one pixel and darkens it into a tasteful ambient tint
    func nucflixAmbientColor() -> UIColor? {
        guard let cgImage else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(
            data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .medium
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        let base = UIColor(red: CGFloat(pixel[0]) / 255, green: CGFloat(pixel[1]) / 255, blue: CGFloat(pixel[2]) / 255, alpha: 1)
        base.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        // Keep it moody: boost saturation a touch, clamp brightness low so white text stays legible
        return UIColor(hue: hue, saturation: min(saturation * 1.25, 0.85), brightness: min(max(brightness * 0.55, 0.12), 0.32), alpha: 1)
    }
}
