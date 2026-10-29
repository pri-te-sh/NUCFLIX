import SwiftUI

struct MoviesView: View {
    @Environment(AppState.self) var appState

    @State private var searchQuery: String = ""
    @State private var debouncedSearchQuery: String = ""
    @State private var showCategorySheet: Bool = false

    private let columns = [
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8)
    ]

    private var activeCategoryTitle: String {
        if appState.selectedVODCategoryID == "FAV" {
            return "My List • Movies"
        }
        if let cat = appState.vodCategories.first(where: { $0.id == appState.selectedVODCategoryID }) {
            return cat.cleanName
        }
        return appState.vodCategories.first?.cleanName ?? "Movies"
    }

    private var currentMovies: [XtreamVODStream] {
        let trimmed = debouncedSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return appState.searchMovies(
                query: trimmed,
                prioritizeCategoryID: appState.selectedVODCategoryID,
                limit: 180
            )
        }
        if appState.selectedVODCategoryID == "FAV" {
            return appState.visibleFavoriteMovies
        } else {
            return appState.vodStreamsByCategory[appState.selectedVODCategoryID] ?? []
        }
    }

    var body: some View {
        let movies = currentMovies
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                VStack(spacing: 0) {
                    netflixCategoryBar

                    if appState.isLoadingVOD && movies.isEmpty {
                        Spacer()
                        ProgressView("Loading \(activeCategoryTitle)...")
                            .tint(AppTheme.netflixRed)
                        Spacer()
                    } else if movies.isEmpty {
                        Spacer()
                        ContentUnavailableView(
                            "No Movies in \(activeCategoryTitle)",
                            systemImage: "film.stack",
                            description: Text("Tap Categories above to browse all \(appState.vodCategories.count) movie collections.")
                        )
                        Spacer()
                    } else {
                        ScrollView {
                            LazyVGrid(columns: columns, spacing: 10) {
                                ForEach(movies) { movie in
                                    NavigationLink {
                                        MovieDetailView(movie: movie)
                                    } label: {
                                        netflixMoviePoster(movie)
                                    }
                                    .buttonStyle(PressableCardStyle())
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                        }
                        .refreshable {
                            await appState.refreshAllCatalogs(force: true)
                        }
                    }
                }
            }
            .navigationTitle("Movies")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchQuery, prompt: "Search all movies across \(appState.vodCategories.count) categories...")
            .task(id: searchQuery) {
                if searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    debouncedSearchQuery = ""
                } else {
                    try? await Task.sleep(nanoseconds: 150_000_000)
                    guard !Task.isCancelled else { return }
                    debouncedSearchQuery = searchQuery
                }
            }
            .sheet(isPresented: $showCategorySheet) {
                CategoryExplorerSheet(
                    title: "Movie Categories",
                    categories: appState.vodCategories,
                    selectedCategoryID: Bindable(appState).selectedVODCategoryID,
                    favoritesCount: appState.visibleFavoriteMovies.count
                ) { chosenID in
                    appState.selectVODCategory(chosenID)
                }
            }
            .onAppear {
                if appState.selectedVODCategoryID.isEmpty, let first = appState.vodCategories.first {
                    appState.selectVODCategory(first.id)
                } else if !appState.selectedVODCategoryID.isEmpty,
                          appState.selectedVODCategoryID != "FAV",
                          appState.vodStreamsByCategory[appState.selectedVODCategoryID] == nil {
                    // Only fetch when not cached — avoids re-publishing AppState on every tab switch
                    appState.selectVODCategory(appState.selectedVODCategoryID)
                }
            }
        }
    }

    private var netflixCategoryBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Button {
                    showCategorySheet = true
                } label: {
                    HStack(spacing: 6) {
                        Text(activeCategoryTitle)
                            .font(.system(size: 13, weight: .bold))
                            .lineLimit(1)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .bold))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(AppTheme.netflixRed, in: Capsule())
                    .foregroundStyle(.white)
                }
                .buttonStyle(.plain)

                Button {
                    appState.selectVODCategory("FAV")
                } label: {
                    Text("My List (\(appState.visibleFavoriteMovies.count))")
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 13)
                        .padding(.vertical, 8)
                        .background(
                            appState.selectedVODCategoryID == "FAV" ? Color.white : AppTheme.elevatedGray,
                            in: Capsule()
                        )
                        .foregroundStyle(appState.selectedVODCategoryID == "FAV" ? .black : .white)
                }
                .buttonStyle(.plain)

                ForEach(appState.vodCategories.prefix(20)) { cat in
                    let isSelected = appState.selectedVODCategoryID == cat.id
                    Button {
                        appState.selectVODCategory(cat.id)
                    } label: {
                        Text(cat.cleanName)
                            .font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 13)
                            .padding(.vertical, 8)
                            .background(
                                isSelected ? Color.white : AppTheme.elevatedGray,
                                in: Capsule()
                            )
                            .foregroundStyle(isSelected ? .black : .white)
                    }
                    .buttonStyle(.plain)
                }

                Button {
                    showCategorySheet = true
                } label: {
                    Text("All \(appState.vodCategories.count) Categories...")
                        .font(.system(size: 12, weight: .bold))
                        .padding(.horizontal, 13)
                        .padding(.vertical, 8)
                        .background(AppTheme.elevatedGray, in: Capsule())
                        .foregroundStyle(AppTheme.netflixRed)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
    }

    private func netflixMoviePoster(_ movie: XtreamVODStream) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack(alignment: .topLeading) {
                ArtworkImageView(
                    urlString: movie.streamIcon,
                    fallbackTitle: movie.cleanName,
                    fallbackIcon: "film"
                )
                .frame(height: 168)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                NucFlixLogoBadge(size: 15)
                    .padding(6)
            }

            Text(movie.cleanName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)
        }
    }
}

// MARK: - Netflix-Style Movie Detail View

struct MovieDetailView: View {
    @Environment(AppState.self) var appState
    private var downloadManager = DownloadManager.shared
    let movie: XtreamVODStream

    @State private var vodInfo: XtreamVODInfoResponse?
    @State private var isLoadingInfo: Bool = false
    @State private var showQualitySheet: Bool = false

    private var itemID: String {
        "movie-\(movie.streamId.value)"
    }

    private var savedProgress: WatchHistoryEntry? {
        appState.savedProgress(for: itemID)
    }

    private var resolvedExtension: String {
        vodInfo?.movieData?.containerExtension ?? movie.containerExtension ?? "mkv"
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    // 16:9 Top Preview Area (Strictly bounded to screen width)
                    topPreviewBanner

                    VStack(alignment: .leading, spacing: 14) {
                        NucFlixSeriesTag(label: "FILM")

                        Text(movie.cleanName)
                            .font(.system(size: 24, weight: .black))
                            .foregroundStyle(.white)
                            .fixedSize(horizontal: false, vertical: true)

                        // Classic Netflix Match % + Year + HD/4K + Runtime row
                        HStack(spacing: 10) {
                            Text("98% Match")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(AppTheme.matchGreen)

                            if let year = vodInfo?.info?.releaseDate, !year.isEmpty {
                                Text(String(year.prefix(4)))
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.75))
                            }

                            QualityBadgeView(text: movie.qualityBadges.first ?? "HD")

                            if let duration = vodInfo?.info?.duration, !duration.isEmpty {
                                Text(duration)
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.75))
                            }

                            QualityBadgeView(text: resolvedExtension.uppercased())
                        }

                        // Primary White "Play" & Secondary Dark Gray "Download" Capsule Buttons (Netflix Exact)
                        VStack(spacing: 10) {
                            Button {
                                var updated = movie
                                updated.containerExtension = resolvedExtension
                                appState.startPlayback(.fromMovie(updated, resumeSeconds: savedProgress?.resumePosition ?? 0))
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "play.fill")
                                        .font(.system(size: 17, weight: .bold))
                                    Text(savedProgress.map { $0.isWatched ? "Play Again" : "Resume" } ?? "Play")
                                        .font(.system(size: 16, weight: .bold))
                                }
                                .frame(maxWidth: .infinity)
                                .frame(height: 44)
                                .background(Color.white, in: Capsule())
                                .foregroundStyle(.black)
                            }

                            movieDownloadButton
                        }
                        .padding(.top, 2)

                        // Synopsis
                        Text(vodInfo?.info?.resolvedPlot ?? "Loading synopsis...")
                            .font(.system(size: 14))
                            .foregroundStyle(.white.opacity(0.9))
                            .lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)

                        // Cast & Director in Muted Gray
                        VStack(alignment: .leading, spacing: 4) {
                            if let cast = vodInfo?.info?.resolvedCast, !cast.isEmpty {
                                Text("Cast: \(cast)")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.white.opacity(0.55))
                                    .lineLimit(2)
                            }
                            if let director = vodInfo?.info?.director, !director.isEmpty {
                                Text("Director: \(director)")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.white.opacity(0.55))
                            }
                        }

                        // Netflix Action Row (My List, Restart, Open VLC, Copy Link)
                        HStack(spacing: 32) {
                            Button {
                                appState.toggleFavoriteMovie(movie)
                            } label: {
                                let isFav = appState.isFavoriteMovie(movie.streamId.value)
                                VStack(spacing: 6) {
                                    Image(systemName: isFav ? "checkmark" : "plus")
                                        .font(.system(size: 20, weight: .semibold))
                                    Text("My List")
                                        .font(.system(size: 11))
                                }
                                .foregroundStyle(.white.opacity(0.85))
                            }

                            Button {
                                var updated = movie
                                updated.containerExtension = resolvedExtension
                                appState.startPlayback(.fromMovie(updated, resumeSeconds: 0))
                            } label: {
                                VStack(spacing: 6) {
                                    Image(systemName: "arrow.counterclockwise")
                                        .font(.system(size: 20, weight: .semibold))
                                    Text("From Start")
                                        .font(.system(size: 11))
                                }
                                .foregroundStyle(.white.opacity(0.85))
                            }

                            Button {
                                openMovieInVLC()
                            } label: {
                                VStack(spacing: 6) {
                                    Image(systemName: "cone")
                                        .font(.system(size: 20, weight: .semibold))
                                    Text("VLC App")
                                        .font(.system(size: 11))
                                }
                                .foregroundStyle(.white.opacity(0.85))
                            }

                            Button {
                                if let creds = appState.credentials,
                                   let url = creds.vodStreamURL(streamID: movie.streamId.value, containerExtension: resolvedExtension) {
                                    UIPasteboard.general.string = url.absoluteString
                                }
                            } label: {
                                VStack(spacing: 6) {
                                    Image(systemName: "paperplane")
                                        .font(.system(size: 20, weight: .semibold))
                                    Text("Copy Link")
                                        .font(.system(size: 11))
                                }
                                .foregroundStyle(.white.opacity(0.85))
                            }
                        }
                        .padding(.vertical, 8)
                    }
                    .padding(.horizontal, 16)
                }
                .padding(.bottom, 36)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showQualitySheet) {
            MovieDownloadQualitySheet(primaryMovie: movie, resolvedExtension: resolvedExtension)
                .environment(appState)
        }
        .task {
            async let infoTask: Void = loadVODInfo()
            async let companionTask: Void = appState.loadCompanionVODCategories(for: movie)
            _ = await (infoTask, companionTask)
        }
    }

    @ViewBuilder
    private var movieDownloadButton: some View {
        if let active = downloadManager.activeDownloads[itemID] {
            Button {
                downloadManager.cancelDownload(id: itemID)
            } label: {
                HStack(spacing: 8) {
                    ProgressView()
                        .tint(AppTheme.netflixRed)
                        .scaleEffect(0.85)
                    Text(active.progressDetailText)
                        .font(.system(size: 14, weight: .bold))
                        .lineLimit(1)
                    Spacer()
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.white.opacity(0.75))
                }
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .background(Color(white: 0.20), in: Capsule())
                .foregroundStyle(.white)
            }
        } else if downloadManager.isQueued(itemID) {
            Button {
                downloadManager.cancelDownload(id: itemID)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: downloadManager.isPausedForStreaming ? "pause.circle" : "clock")
                        .font(.system(size: 15, weight: .bold))
                    Text(downloadManager.isPausedForStreaming ? "Paused while someone is watching" : "Waiting to download")
                        .font(.system(size: 14, weight: .bold))
                        .lineLimit(1)
                    Spacer()
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.white.opacity(0.75))
                }
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .background(Color(white: 0.20), in: Capsule())
                .foregroundStyle(.white)
            }
        } else if let downloaded = downloadManager.downloadedItem(for: itemID) {
            Menu {
                Button {
                    appState.startPlayback(downloaded.toPlaybackItem(resumeSeconds: savedProgress?.resumePosition ?? 0))
                } label: {
                    Label("Play Offline (\(downloaded.formattedSize))", systemImage: "play.fill")
                }
                Button(role: .destructive) {
                    downloadManager.deleteDownload(id: itemID)
                } label: {
                    Label("Delete Download", systemImage: "trash")
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 15, weight: .bold))
                    Text("Downloaded")
                        .font(.system(size: 16, weight: .bold))
                }
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .background(Color(white: 0.20), in: Capsule())
                .foregroundStyle(.white)
            }
        } else {
            Button {
                if downloadManager.preferredQualityPreset == .askEveryTime {
                    showQualitySheet = true
                } else if let creds = appState.credentials {
                    let preset = downloadManager.preferredQualityPreset
                    let variants = appState.findMatchingQualityVariants(for: movie)
                    let selectedVariant: XtreamVODStream
                    if preset != .original,
                       let non4K = variants.dropFirst().first(where: { !$0.qualityBadges.contains("4K") }) ?? variants.dropFirst().first {
                        selectedVariant = non4K
                    } else {
                        selectedVariant = movie
                    }
                    let targetExt = (selectedVariant.streamId.value == movie.streamId.value)
                        ? resolvedExtension
                        : (selectedVariant.containerExtension ?? resolvedExtension)
                    let compress = (preset == .standard720p && targetExt.lowercased() == "mp4") ? "AVAssetExportPreset1280x720" : nil
                    appState.recordDownload(movie: movie)
                    downloadManager.startMovieDownload(
                        movie: selectedVariant,
                        resolvedExtension: targetExt,
                        credentials: creds,
                        qualityLabel: preset.shortLabel,
                        compressPreset: compress,
                        sizeScaleFactor: preset.sizeScaleFactor,
                        customItemID: itemID
                    )
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.down.to.line")
                        .font(.system(size: 16, weight: .bold))
                    Text("Download")
                        .font(.system(size: 16, weight: .bold))
                }
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .background(Color(white: 0.20), in: Capsule())
                .foregroundStyle(.white)
            }
        }
    }

    private var topPreviewBanner: some View {
        ZStack {
            ArtworkImageView(
                urlString: vodInfo?.info?.resolvedBackdrop ?? movie.streamIcon,
                fallbackTitle: movie.cleanName,
                fallbackIcon: "film"
            )
            .frame(maxWidth: .infinity)
            .frame(height: 225)

            Color.black.opacity(0.25)

            Button {
                var updated = movie
                updated.containerExtension = resolvedExtension
                appState.startPlayback(.fromMovie(updated, resumeSeconds: savedProgress?.resumePosition ?? 0))
            } label: {
                Circle()
                    .fill(Color.black.opacity(0.65))
                    .frame(width: 58, height: 58)
                    .overlay(
                        Circle().stroke(AppTheme.netflixRed, lineWidth: 2)
                    )
                    .overlay(
                        Image(systemName: "play.fill")
                            .font(.system(size: 22, weight: .bold))
                            .foregroundStyle(.white)
                            .offset(x: 2)
                    )
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 225)
    }

    private func openMovieInVLC() {
        guard let creds = appState.credentials,
              let url = creds.vodStreamURL(streamID: movie.streamId.value, containerExtension: resolvedExtension) else {
            return
        }
        let encoded = url.absoluteString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? url.absoluteString
        if let vlcURL = URL(string: "vlc-x-callback://x-callback-url/stream?url=\(encoded)") {
            UIApplication.shared.open(vlcURL)
        }
    }

    private func loadVODInfo() async {
        guard let creds = appState.credentials else { return }
        isLoadingInfo = true
        defer { isLoadingInfo = false }
        vodInfo = try? await XtreamAPIService.shared.fetchVODInfo(credentials: creds, vodId: movie.streamId.value)
        appState.recordDetailView(movie: movie, genre: vodInfo?.info?.genre)
    }
}
