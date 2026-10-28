import SwiftUI

enum SearchScope: String, CaseIterable, Identifiable {
    case all = "All"
    case live = "Live TV"
    case movies = "Movies"
    case series = "Series"

    var id: String { rawValue }
}

struct SearchView: View {
    @Environment(AppState.self) var appState

    @State private var query: String = ""
    @State private var debouncedQuery: String = ""
    @State private var scope: SearchScope = .all
    /// AI-read filters for natural-language requests ("funny hindi movies from the 2010s").
    @State private var smartFilters: SmartAI.SearchFilters?
    @State private var smartLoading = false

    private var trimmedQuery: String {
        debouncedQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var matchedLiveCategories: [XtreamCategory] {
        guard !trimmedQuery.isEmpty, scope == .all || scope == .live else { return [] }
        return Array(
            appState.liveCategories
                .filter { $0.categoryName.localizedCaseInsensitiveContains(trimmedQuery) }
                .prefix(8)
        )
    }

    private var matchedLive: [XtreamLiveStream] {
        guard !trimmedQuery.isEmpty, scope == .all || scope == .live else { return [] }
        return appState.searchLiveStreams(query: trimmedQuery, limit: 80)
    }

    private var matchedMovies: [XtreamVODStream] {
        guard !trimmedQuery.isEmpty, scope == .all || scope == .movies else { return [] }
        return appState.searchMovies(query: trimmedQuery, limit: 80)
    }

    private var matchedSeries: [XtreamSeries] {
        guard !trimmedQuery.isEmpty, scope == .all || scope == .series else { return [] }
        return appState.searchSeries(query: trimmedQuery, limit: 80)
    }

    private var smartResults: (live: [XtreamLiveStream], movies: [XtreamVODStream], series: [XtreamSeries]) {
        guard let smartFilters, !trimmedQuery.isEmpty else { return ([], [], []) }
        let r = appState.smartSearchResults(smartFilters)
        return (scope == .all || scope == .live ? r.live : [],
                scope == .all || scope == .movies ? r.movies : [],
                scope == .all || scope == .series ? r.series : [])
    }

    var body: some View {
        let liveCategories = matchedLiveCategories
        let liveChannels = matchedLive
        let movies = matchedMovies
        let series = matchedSeries
        let smart = smartResults
        let smartCount = smart.live.count + smart.movies.count + smart.series.count

        NavigationStack {
            ZStack {
                ObsidianBackgroundView()

                VStack(spacing: 0) {
                    Picker("Scope", selection: $scope) {
                        ForEach(SearchScope.allCases) { item in
                            Text(item.rawValue).tag(item)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)

                    if appState.isIndexingFullCatalog {
                        HStack(spacing: 8) {
                            ProgressView()
                                .tint(AppTheme.netflixRed)
                                .scaleEffect(0.8)
                            Text("Indexing full server catalog (48K+ movies, 12K+ series, 20K+ channels)...")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.8))
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 6)
                    }

                    if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Spacer()
                        ContentUnavailableView(
                            "Search NucFlix Catalog",
                            systemImage: "magnifyingglass",
                            description: Text("Search across \(appState.allMoviesCatalog.isEmpty ? appState.allLoadedMovies.count : appState.allMoviesCatalog.count) movies, \(appState.allSeriesCatalog.isEmpty ? appState.allLoadedSeries.count : appState.allSeriesCatalog.count) series, and \(appState.allLiveCatalog.isEmpty ? appState.allLoadedLiveStreams.count : appState.allLiveCatalog.count) live channels.")
                        )
                        Spacer()
                    } else if !trimmedQuery.isEmpty && liveCategories.isEmpty && liveChannels.isEmpty && movies.isEmpty && series.isEmpty
                                && smartCount == 0 && !smartLoading {
                        Spacer()
                        ContentUnavailableView.search(text: trimmedQuery)
                        Spacer()
                    } else {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 10) {
                                if smartLoading && smartCount == 0 {
                                    HStack(spacing: 8) {
                                        ProgressView()
                                            .tint(AppTheme.netflixRed)
                                            .scaleEffect(0.8)
                                        Text("Understanding your request…")
                                            .font(.system(size: 12, weight: .semibold))
                                            .foregroundStyle(.white.opacity(0.8))
                                    }
                                } else if let smartFilters, smartCount > 0 {
                                    Label(smartFilters.summary.uppercased(), systemImage: "sparkles")
                                        .padding(.top, 4)
                                        .font(.system(size: 11, weight: .heavy, design: .rounded))
                                        .foregroundStyle(AppTheme.primaryRed)
                                    ForEach(smart.movies) { movieRow($0) }
                                    ForEach(smart.series) { seriesRow($0) }
                                    ForEach(smart.live) { liveRow($0) }
                                }

                                if !liveCategories.isEmpty {
                                    VStack(alignment: .leading, spacing: 10) {
                                        Text("MATCHING CATEGORIES")
                                            .font(.system(size: 11, weight: .heavy, design: .rounded))
                                            .foregroundStyle(AppTheme.primaryRed)

                                        ScrollView(.horizontal, showsIndicators: false) {
                                            HStack(spacing: 10) {
                                                ForEach(liveCategories) { cat in
                                                    Button {
                                                        Task {
                                                            await appState.loadLiveCategory(id: cat.id)
                                                        }
                                                    } label: {
                                                        HStack(spacing: 6) {
                                                            Image(systemName: "folder.fill")
                                                                .foregroundStyle(AppTheme.primaryRed)
                                                            Text(cat.cleanName)
                                                                .font(.caption.weight(.bold))
                                                                .foregroundStyle(.white)
                                                        }
                                                        .padding(.horizontal, 14)
                                                        .padding(.vertical, 10)
                                                        .obsidianGlassCard(cornerRadius: 14)
                                                    }
                                                    .buttonStyle(.plain)
                                                }
                                            }
                                        }
                                    }
                                }

                                if !liveChannels.isEmpty {
                                        Text("LIVE CHANNELS (\(liveChannels.count))")
                                            .padding(.top, 10)
                                            .font(.system(size: 11, weight: .heavy, design: .rounded))
                                            .foregroundStyle(AppTheme.primaryRed)

                                        ForEach(liveChannels) { channel in
                                            liveRow(channel)
                                        }
                                }

                                if !movies.isEmpty {
                                        Text("MOVIES (\(movies.count))")
                                            .padding(.top, 10)
                                            .font(.system(size: 11, weight: .heavy, design: .rounded))
                                            .foregroundStyle(AppTheme.primaryRed)

                                        ForEach(movies) { movie in
                                            movieRow(movie)
                                        }
                                }

                                if !series.isEmpty {
                                        Text("TV SERIES (\(series.count))")
                                            .padding(.top, 10)
                                            .font(.system(size: 11, weight: .heavy, design: .rounded))
                                            .foregroundStyle(AppTheme.primaryRed)

                                        ForEach(series) { seriesItem in
                                            seriesRow(seriesItem)
                                        }
                                }
                            }
                            .padding(16)
                        }
                    }
                }
            }
            .navigationTitle("Search")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: "Channels, movies, series, categories...")
            .task(id: query) {
                if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    debouncedQuery = ""
                } else {
                    try? await Task.sleep(nanoseconds: 150_000_000) // 150ms debounce
                    guard !Task.isCancelled else { return }
                    debouncedQuery = query
                }
            }
            .task(id: debouncedQuery) {
                // Longer requests also go to the AI for filters; plain title searches never do.
                smartFilters = nil
                let q = trimmedQuery
                guard q.split(whereSeparator: \.isWhitespace).count >= 3 else {
                    smartLoading = false
                    return
                }
                smartLoading = true
                try? await Task.sleep(nanoseconds: 750_000_000)
                guard !Task.isCancelled else { return }
                let filters = await SmartAI.shared.searchFilters(q)
                guard !Task.isCancelled else { return }
                smartFilters = filters
                smartLoading = false
            }
            .task {
                if appState.allMoviesCatalog.isEmpty && !appState.isIndexingFullCatalog {
                    await appState.preloadFullCatalogInBackground()
                }
            }
        }
    }

    // MARK: Rows

    private func liveRow(_ channel: XtreamLiveStream) -> some View {
        Button {
            appState.startPlayback(.fromLive(channel))
        } label: {
            HStack(spacing: 12) {
                ArtworkImageView(
                    urlString: channel.streamIcon,
                    fallbackTitle: channel.cleanName,
                    fallbackIcon: "tv",
                    contentMode: .fit
                )
                .padding(6)
                .frame(width: 48, height: 48)
                .background(Color.black.opacity(0.4))
                .clipShape(RoundedRectangle(cornerRadius: 10))

                VStack(alignment: .leading, spacing: 3) {
                    Text(channel.cleanName)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.white)
                    HStack(spacing: 6) {
                        LivePulseBadge()
                        ForEach(channel.qualityBadges, id: \.self) { b in
                            QualityBadgeView(text: b)
                        }
                    }
                }
                Spacer()
                Image(systemName: "play.circle.fill")
                    .font(.title2)
                    .foregroundStyle(AppTheme.primaryRed)
            }
            .padding(10)
            .obsidianGlassCard(cornerRadius: 14)
        }
        .buttonStyle(.plain)
    }

    private func movieRow(_ movie: XtreamVODStream) -> some View {
        NavigationLink {
            MovieDetailView(movie: movie)
        } label: {
            HStack(spacing: 12) {
                ArtworkImageView(
                    urlString: movie.streamIcon,
                    fallbackTitle: movie.cleanName,
                    fallbackIcon: "film"
                )
                .frame(width: 46, height: 66)
                .clipShape(RoundedRectangle(cornerRadius: 10))

                VStack(alignment: .leading, spacing: 4) {
                    Text(movie.cleanName)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.white)
                    HStack(spacing: 6) {
                        if let rating = movie.displayRating {
                            Label(rating, systemImage: "star.fill")
                                .font(.caption2.bold())
                                .foregroundStyle(AppTheme.gold)
                        }
                        ForEach(movie.qualityBadges, id: \.self) { b in
                            QualityBadgeView(text: b)
                        }
                    }
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.4))
            }
            .padding(10)
            .obsidianGlassCard(cornerRadius: 14)
        }
        .buttonStyle(.plain)
    }

    private func seriesRow(_ seriesItem: XtreamSeries) -> some View {
        NavigationLink {
            SeriesDetailView(series: seriesItem)
        } label: {
            HStack(spacing: 12) {
                ArtworkImageView(
                    urlString: seriesItem.cover,
                    fallbackTitle: seriesItem.cleanName,
                    fallbackIcon: "tv.inset.filled"
                )
                .frame(width: 46, height: 66)
                .clipShape(RoundedRectangle(cornerRadius: 10))

                VStack(alignment: .leading, spacing: 4) {
                    Text(seriesItem.cleanName)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.white)
                    HStack(spacing: 6) {
                        if let rating = seriesItem.displayRating {
                            Label(rating, systemImage: "star.fill")
                                .font(.caption2.bold())
                                .foregroundStyle(AppTheme.gold)
                        }
                        ForEach(seriesItem.qualityBadges, id: \.self) { b in
                            QualityBadgeView(text: b)
                        }
                    }
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.4))
            }
            .padding(10)
            .obsidianGlassCard(cornerRadius: 14)
        }
        .buttonStyle(.plain)
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .padding(.top, 10)
            .font(.system(size: 11, weight: .heavy, design: .rounded))
            .foregroundStyle(AppTheme.primaryRed)
    }
}
