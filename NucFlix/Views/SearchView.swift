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

    var body: some View {
        let liveCategories = matchedLiveCategories
        let liveChannels = matchedLive
        let movies = matchedMovies
        let series = matchedSeries

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
                    } else if !trimmedQuery.isEmpty && liveCategories.isEmpty && liveChannels.isEmpty && movies.isEmpty && series.isEmpty {
                        Spacer()
                        ContentUnavailableView.search(text: trimmedQuery)
                        Spacer()
                    } else {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 10) {
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
                                }

                                if !movies.isEmpty {
                                        Text("MOVIES (\(movies.count))")
                                            .padding(.top, 10)
                                            .font(.system(size: 11, weight: .heavy, design: .rounded))
                                            .foregroundStyle(AppTheme.primaryRed)

                                        ForEach(movies) { movie in
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
                                }

                                if !series.isEmpty {
                                        Text("TV SERIES (\(series.count))")
                                            .padding(.top, 10)
                                            .font(.system(size: 11, weight: .heavy, design: .rounded))
                                            .foregroundStyle(AppTheme.primaryRed)

                                        ForEach(series) { seriesItem in
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
            .task {
                if appState.allMoviesCatalog.isEmpty && !appState.isIndexingFullCatalog {
                    await appState.preloadFullCatalogInBackground()
                }
            }
        }
    }
}
