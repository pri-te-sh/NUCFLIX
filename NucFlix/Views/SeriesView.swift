import SwiftUI

struct SeriesView: View {
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
        if appState.selectedSeriesCategoryID == "FAV" {
            return "My List • Series"
        }
        if let cat = appState.seriesCategories.first(where: { $0.id == appState.selectedSeriesCategoryID }) {
            return cat.cleanName
        }
        return appState.seriesCategories.first?.cleanName ?? "Series"
    }

    private var currentSeriesList: [XtreamSeries] {
        let trimmed = debouncedSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return appState.searchSeries(
                query: trimmed,
                prioritizeCategoryID: appState.selectedSeriesCategoryID,
                limit: 180
            )
        }
        if appState.selectedSeriesCategoryID == "FAV" {
            return appState.visibleFavoriteSeries
        } else {
            return appState.seriesByCategory[appState.selectedSeriesCategoryID] ?? []
        }
    }

    var body: some View {
        let seriesList = currentSeriesList
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                VStack(spacing: 0) {
                    netflixCategoryBar

                    if appState.isLoadingSeries && seriesList.isEmpty {
                        Spacer()
                        ProgressView("Loading \(activeCategoryTitle)...")
                            .tint(AppTheme.netflixRed)
                        Spacer()
                    } else if seriesList.isEmpty {
                        Spacer()
                        ContentUnavailableView(
                            "No Series in \(activeCategoryTitle)",
                            systemImage: "tv.inset.filled",
                            description: Text("Tap Categories above to browse all \(appState.seriesCategories.count) series collections.")
                        )
                        Spacer()
                    } else {
                        ScrollView {
                            LazyVGrid(columns: columns, spacing: 10) {
                                ForEach(seriesList) { series in
                                    NavigationLink {
                                        SeriesDetailView(series: series)
                                    } label: {
                                        netflixSeriesPoster(series)
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
            .navigationTitle("Series")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchQuery, prompt: "Search all series across \(appState.seriesCategories.count) categories...")
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
                    title: "Series Categories",
                    categories: appState.seriesCategories,
                    selectedCategoryID: Bindable(appState).selectedSeriesCategoryID,
                    favoritesCount: appState.visibleFavoriteSeries.count
                ) { chosenID in
                    appState.selectSeriesCategory(chosenID)
                }
            }
            .onAppear {
                if appState.selectedSeriesCategoryID.isEmpty, let first = appState.seriesCategories.first {
                    appState.selectSeriesCategory(first.id)
                } else if !appState.selectedSeriesCategoryID.isEmpty,
                          appState.selectedSeriesCategoryID != "FAV",
                          appState.seriesByCategory[appState.selectedSeriesCategoryID] == nil {
                    // Only fetch when not cached — avoids re-publishing AppState on every tab switch
                    appState.selectSeriesCategory(appState.selectedSeriesCategoryID)
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
                    appState.selectSeriesCategory("FAV")
                } label: {
                    Text("My List (\(appState.visibleFavoriteSeries.count))")
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 13)
                        .padding(.vertical, 8)
                        .background(
                            appState.selectedSeriesCategoryID == "FAV" ? Color.white : AppTheme.elevatedGray,
                            in: Capsule()
                        )
                        .foregroundStyle(appState.selectedSeriesCategoryID == "FAV" ? .black : .white)
                }
                .buttonStyle(.plain)

                ForEach(appState.seriesCategories.prefix(20)) { cat in
                    let isSelected = appState.selectedSeriesCategoryID == cat.id
                    Button {
                        appState.selectSeriesCategory(cat.id)
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
                    Text("All \(appState.seriesCategories.count) Categories...")
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

    private func netflixSeriesPoster(_ series: XtreamSeries) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack(alignment: .topLeading) {
                ArtworkImageView(
                    urlString: series.cover,
                    fallbackTitle: series.cleanName,
                    fallbackIcon: "tv"
                )
                .frame(height: 168)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                NucFlixLogoBadge(size: 15)
                    .padding(6)
            }

            Text(series.cleanName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)
        }
    }
}

// MARK: - Netflix-Style Series Detail View

struct SeriesDetailView: View {
    @Environment(AppState.self) var appState
    private var downloadManager = DownloadManager.shared
    let series: XtreamSeries

    @State private var seriesInfo: XtreamSeriesInfoResponse = XtreamSeriesInfoResponse()
    @State private var selectedSeason: Int = 1
    @State private var isLoading: Bool = true
    @State private var isRated: Bool = false

    private var currentEpisodes: [XtreamEpisode] {
        seriesInfo.episodesBySeason[selectedSeason] ?? []
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    topPreviewBanner

                    VStack(alignment: .leading, spacing: 14) {
                        Text(series.cleanName)
                            .font(.system(size: 22, weight: .bold))
                            .foregroundStyle(.white)
                            .fixedSize(horizontal: false, vertical: true)

                        // Authentic Netflix Metadata Row: 2018  [TV-MA]  5 Seasons  [HD]  💬
                        HStack(spacing: 8) {
                            if let year = series.releaseDate, !year.isEmpty {
                                Text(String(year.prefix(4)))
                                    .font(.system(size: 13, weight: .regular))
                                    .foregroundStyle(.white.opacity(0.75))
                            }

                            Text("TV-MA")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.white.opacity(0.9))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2.5)
                                .background(Color(white: 0.22), in: RoundedRectangle(cornerRadius: 3))

                            if !seriesInfo.sortedSeasonNumbers.isEmpty {
                                Text("\(seriesInfo.sortedSeasonNumbers.count) Seasons")
                                    .font(.system(size: 13, weight: .regular))
                                    .foregroundStyle(.white.opacity(0.75))
                            }

                            QualityBadgeView(text: series.qualityBadges.first ?? "HD")

                            Image(systemName: "captions.bubble")
                                .font(.system(size: 13))
                                .foregroundStyle(.white.opacity(0.7))
                        }

                        // Authentic Netflix Full-Width Capsule "Play" & "Download" Buttons
                        if let firstEp = currentEpisodes.first {
                            VStack(spacing: 10) {
                                Button {
                                    appState.startPlayback(
                                        .fromEpisode(series: series, episode: firstEp, seasonNumber: selectedSeason)
                                    )
                                } label: {
                                    HStack(spacing: 8) {
                                        Image(systemName: "play.fill")
                                            .font(.system(size: 17, weight: .bold))
                                        Text("Play")
                                            .font(.system(size: 16, weight: .bold))
                                    }
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 44)
                                    .background(Color.white, in: Capsule())
                                    .foregroundStyle(.black)
                                }

                                primaryNetflixDownloadButton(fallbackEpisode: firstEp)
                            }
                        }

                        // Synopsis
                        if let plot = series.plot ?? seriesInfo.info?.plot, !plot.isEmpty {
                            Text(plot)
                                .font(.system(size: 14))
                                .foregroundStyle(.white.opacity(0.92))
                                .lineSpacing(2.5)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        // Cast & Genre in Muted Gray
                        VStack(alignment: .leading, spacing: 3) {
                            if let cast = series.cast ?? seriesInfo.info?.resolvedCast, !cast.isEmpty {
                                Text("Cast: \(cast)")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.white.opacity(0.55))
                                    .lineLimit(1)
                            }
                            if let genre = series.genre, !genre.isEmpty {
                                Text("Genres: \(genre)")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.white.opacity(0.55))
                                    .lineLimit(1)
                            }
                        }

                        // Authentic Netflix 4-Icon Action Row: My List | Rate | Share | Download Season X
                        HStack(alignment: .top, spacing: 0) {
                            Button {
                                appState.toggleFavoriteSeries(series)
                            } label: {
                                let isFav = appState.isFavoriteSeries(series.seriesId.value)
                                VStack(spacing: 6) {
                                    Image(systemName: isFav ? "checkmark" : "plus")
                                        .font(.system(size: 20, weight: .medium))
                                        .frame(height: 24)
                                    Text("My List")
                                        .font(.system(size: 11))
                                }
                                .frame(maxWidth: .infinity)
                                .foregroundStyle(.white.opacity(0.85))
                            }
                            .buttonStyle(.plain)

                            Button {
                                isRated.toggle()
                            } label: {
                                VStack(spacing: 6) {
                                    Image(systemName: isRated ? "hand.thumbsup.fill" : "hand.thumbsup")
                                        .font(.system(size: 20, weight: .medium))
                                        .frame(height: 24)
                                    Text("Rate")
                                        .font(.system(size: 11))
                                }
                                .frame(maxWidth: .infinity)
                                .foregroundStyle(.white.opacity(0.85))
                            }
                            .buttonStyle(.plain)

                            Button {
                                UIPasteboard.general.string = series.cleanName
                            } label: {
                                VStack(spacing: 6) {
                                    Image(systemName: "paperplane")
                                        .font(.system(size: 20, weight: .medium))
                                        .frame(height: 24)
                                    Text("Share")
                                        .font(.system(size: 11))
                                }
                                .frame(maxWidth: .infinity)
                                .foregroundStyle(.white.opacity(0.85))
                            }
                            .buttonStyle(.plain)

                            seasonDownloadActionIcon
                                .frame(maxWidth: .infinity)
                        }
                        .padding(.vertical, 6)

                        // Red Top-Border Indicator above "Episodes" + "More Like This" + Season Dropdown
                        VStack(alignment: .leading, spacing: 14) {
                            HStack(spacing: 24) {
                                VStack(alignment: .leading, spacing: 8) {
                                    Rectangle()
                                        .fill(AppTheme.netflixRed)
                                        .frame(width: 68, height: 3.5)

                                    Text("Episodes")
                                        .font(.system(size: 15, weight: .bold))
                                        .foregroundStyle(.white)
                                }

                                VStack(alignment: .leading, spacing: 8) {
                                    Rectangle()
                                        .fill(Color.clear)
                                        .frame(width: 96, height: 3.5)

                                    Text("More Like This")
                                        .font(.system(size: 15, weight: .bold))
                                        .foregroundStyle(.white.opacity(0.45))
                                }
                            }

                            seasonSelector

                            episodesList
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .padding(.bottom, 36)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .task {
            appState.recordDetailView(series: series)
            await loadSeriesDetails()
        }
    }

    private var topPreviewBanner: some View {
        ZStack {
            ArtworkImageView(
                urlString: series.backdropPath?.values.first ?? series.cover,
                fallbackTitle: series.cleanName,
                fallbackIcon: "tv"
            )
            .frame(maxWidth: .infinity)
            .frame(height: 225)

            Color.black.opacity(0.25)

            if let firstEp = currentEpisodes.first {
                Button {
                    appState.startPlayback(
                        .fromEpisode(series: series, episode: firstEp, seasonNumber: selectedSeason)
                    )
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
        }
        .frame(maxWidth: .infinity)
        .frame(height: 225)
    }

    private var seasonSelector: some View {
        let seasons = seriesInfo.sortedSeasonNumbers
        return HStack {
            if !seasons.isEmpty {
                Menu {
                    ForEach(seasons, id: \.self) { sNum in
                        Button {
                            selectedSeason = sNum
                        } label: {
                            HStack {
                                Text("Season \(sNum)")
                                if selectedSeason == sNum {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 10) {
                        Text("Season \(selectedSeason)")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.white.opacity(0.9))
                        Image(systemName: "chevron.down")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.85))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(Color(white: 0.18), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                }
            }

            Spacer()

            Image(systemName: "info.circle.fill")
                .font(.system(size: 20))
                .foregroundStyle(.white)
        }
    }

    private var episodesList: some View {
        VStack(alignment: .leading, spacing: 18) {
            if isLoading {
                HStack {
                    Spacer()
                    ProgressView("Loading Episodes...")
                        .tint(AppTheme.netflixRed)
                    Spacer()
                }
                .padding(.vertical, 24)
            } else if currentEpisodes.isEmpty {
                Text("No episodes available for this season.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 16)
            } else {
                ForEach(currentEpisodes) { ep in
                    episodeRow(ep)
                }
            }
        }
    }

    private func episodeRow(_ ep: XtreamEpisode) -> some View {
        let saved = appState.savedProgress(for: "episode-\(ep.episodeId.value)")

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Button {
                    appState.startPlayback(
                        .fromEpisode(
                            series: series,
                            episode: ep,
                            seasonNumber: selectedSeason,
                            resumeSeconds: saved?.positionSeconds ?? 0
                        )
                    )
                } label: {
                    ZStack {
                        ArtworkImageView(
                            urlString: ep.info?.movieImage ?? series.cover,
                            fallbackTitle: "E\(ep.episodeNum.value)",
                            fallbackIcon: "play.rectangle.fill"
                        )
                        .frame(width: 124, height: 70)
                        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))

                        Circle()
                            .fill(.black.opacity(0.6))
                            .frame(width: 32, height: 32)
                            .overlay(
                                Circle().stroke(Color.white, lineWidth: 1.2)
                            )
                            .overlay(
                                Image(systemName: "play.fill")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundStyle(.white)
                                    .offset(x: 1)
                            )
                    }
                }
                .buttonStyle(.plain)

                VStack(alignment: .leading, spacing: 4) {
                    Text("\(ep.episodeNum.value). \(XtreamTextFormatter.format(ep.title).cleanTitle)")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(2)

                    let itemID = "episode-\(ep.episodeId.value)"
                    HStack(spacing: 6) {
                        if let dur = ep.info?.duration, !dur.isEmpty {
                            Text(dur)
                                .font(.system(size: 12))
                                .foregroundStyle(.white.opacity(0.55))
                        }
                        if let active = downloadManager.activeDownloads[itemID] {
                            Text("• \(Int(active.progress * 100))%")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(AppTheme.netflixRed)
                        } else if let qPos = downloadManager.queuePosition(for: itemID) {
                            Text("• Queued #\(qPos)")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(AppTheme.gold)
                        }
                    }
                }

                Spacer()

                episodeRowDownloadAccessory(ep)
            }

            if let plot = ep.info?.plot, !plot.isEmpty {
                Text(plot)
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.68))
                    .lineLimit(3)
            }

            if let active = downloadManager.activeDownloads["episode-\(ep.episodeId.value)"] {
                ProgressView(value: max(active.progress, 0.03))
                    .tint(AppTheme.netflixRed)
            } else if let saved, saved.progressFraction > 0 {
                ProgressView(value: saved.progressFraction)
                    .tint(AppTheme.netflixRed)
            }
        }
    }

    @ViewBuilder
    private func primaryNetflixDownloadButton(fallbackEpisode: XtreamEpisode) -> some View {
        // Target the next undownloaded episode in the current season (or the currently downloading one)
        let activeEp = currentEpisodes.first { downloadManager.activeDownloads["episode-\($0.episodeId.value)"] != nil }
        let nextTargetEp = activeEp
            ?? currentEpisodes.first { !downloadManager.isDownloaded("episode-\($0.episodeId.value)") && !downloadManager.isQueued("episode-\($0.episodeId.value)") }
            ?? fallbackEpisode
        let targetID = "episode-\(nextTargetEp.episodeId.value)"

        if let active = downloadManager.activeDownloads[targetID] {
            Button {
                downloadManager.cancelDownload(id: targetID)
            } label: {
                HStack(spacing: 8) {
                    ProgressView()
                        .tint(AppTheme.netflixRed)
                        .scaleEffect(0.85)
                    Text("Downloading S\(selectedSeason):E\(nextTargetEp.episodeNum.value) (\(Int(active.progress * 100))%)")
                        .font(.system(size: 15, weight: .bold))
                }
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .background(Color(white: 0.20), in: Capsule())
                .foregroundStyle(.white)
            }
        } else {
            Button {
                guard let creds = appState.credentials else { return }
                appState.recordDownload(series: series)
                downloadManager.startEpisodeDownload(
                    series: series,
                    episode: nextTargetEp,
                    seasonNumber: selectedSeason,
                    credentials: creds
                )
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

    @ViewBuilder
    private var seasonDownloadActionIcon: some View {
        let total = currentEpisodes.count
        let downloadedCount = currentEpisodes.filter { downloadManager.isDownloaded("episode-\($0.episodeId.value)") }.count
        let activeCount = currentEpisodes.filter { downloadManager.activeDownloads["episode-\($0.episodeId.value)"] != nil }.count
        let queuedCount = currentEpisodes.filter { downloadManager.isQueued("episode-\($0.episodeId.value)") }.count

        if activeCount > 0 || queuedCount > 0 {
            Button {
                downloadManager.cancelSeasonDownloads(episodes: currentEpisodes)
            } label: {
                VStack(spacing: 6) {
                    ProgressView()
                        .tint(AppTheme.netflixRed)
                        .scaleEffect(0.85)
                        .frame(height: 24)
                    Text("Downloading\nSeason \(selectedSeason) (\(downloadedCount)/\(total))")
                        .font(.system(size: 11))
                        .multilineTextAlignment(.center)
                }
                .foregroundStyle(.white.opacity(0.9))
            }
            .buttonStyle(.plain)
        } else if total > 0 && downloadedCount == total {
            Menu {
                Button(role: .destructive) {
                    downloadManager.deleteSeasonDownloads(episodes: currentEpisodes)
                } label: {
                    Label("Delete Season \(selectedSeason) Downloads", systemImage: "trash")
                }
            } label: {
                VStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(AppTheme.netflixRed)
                        .frame(height: 24)
                    Text("Season \(selectedSeason)\nDownloaded")
                        .font(.system(size: 11))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white.opacity(0.85))
                }
            }
        } else {
            Button {
                guard let creds = appState.credentials else { return }
                appState.recordDownload(series: series)
                downloadManager.startSeasonDownload(
                    series: series,
                    episodes: currentEpisodes,
                    seasonNumber: selectedSeason,
                    credentials: creds
                )
            } label: {
                VStack(spacing: 6) {
                    Image(systemName: "arrow.down.to.line")
                        .font(.system(size: 20, weight: .medium))
                        .frame(height: 24)
                    Text("Download\nSeason \(selectedSeason)")
                        .font(.system(size: 11))
                        .multilineTextAlignment(.center)
                }
                .foregroundStyle(.white.opacity(0.85))
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private func episodeRowDownloadAccessory(_ ep: XtreamEpisode) -> some View {
        let itemID = "episode-\(ep.episodeId.value)"
        if let active = downloadManager.activeDownloads[itemID] {
            Button {
                downloadManager.cancelDownload(id: itemID)
            } label: {
                ZStack {
                    Circle()
                        .stroke(Color.white.opacity(0.22), lineWidth: 2.5)
                        .frame(width: 36, height: 36)
                    Circle()
                        .trim(from: 0, to: max(0.08, active.progress))
                        .stroke(AppTheme.netflixRed, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .frame(width: 36, height: 36)
                    Text("\(Int(active.progress * 100))%")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
            .buttonStyle(.plain)
        } else if let qPos = downloadManager.queuePosition(for: itemID) {
            Menu {
                Button {
                    downloadManager.prioritizeQueuedDownload(id: itemID)
                } label: {
                    Label("Download Next (Move to Top)", systemImage: "arrow.up.to.line")
                }
                Button(role: .destructive) {
                    downloadManager.cancelDownload(id: itemID)
                } label: {
                    Label("Remove from Queue", systemImage: "xmark.circle")
                }
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "clock.fill")
                        .font(.system(size: 10))
                    Text("#\(qPos)")
                        .font(.system(size: 11, weight: .bold))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Color.white.opacity(0.12), in: Capsule())
                .foregroundStyle(AppTheme.gold)
            }
        } else if downloadManager.isDownloaded(itemID) {
            Menu {
                Button(role: .destructive) {
                    downloadManager.deleteDownload(id: itemID)
                } label: {
                    Label("Delete Download", systemImage: "trash")
                }
                Button {
                    openEpisodeInVLC(ep)
                } label: {
                    Label("Open in External VLC", systemImage: "cone")
                }
            } label: {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(AppTheme.netflixRed)
                    .frame(width: 36, height: 36)
            }
        } else {
            Button {
                guard let creds = appState.credentials else { return }
                appState.recordDownload(series: series)
                downloadManager.startEpisodeDownload(series: series, episode: ep, seasonNumber: selectedSeason, credentials: creds)
            } label: {
                Image(systemName: "arrow.down.to.line")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)
        }
    }

    private func openEpisodeInVLC(_ ep: XtreamEpisode) {
        guard let creds = appState.credentials,
              let url = creds.seriesEpisodeURL(episodeID: ep.episodeId.value, containerExtension: ep.containerExtension) else {
            return
        }
        let encoded = url.absoluteString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? url.absoluteString
        if let vlcURL = URL(string: "vlc-x-callback://x-callback-url/stream?url=\(encoded)") {
            UIApplication.shared.open(vlcURL)
        }
    }

    private func loadSeriesDetails() async {
        guard let creds = appState.credentials else { return }
        isLoading = true
        defer { isLoading = false }
        let info = (try? await XtreamAPIService.shared.fetchSeriesInfo(credentials: creds, seriesId: series.seriesId.value)) ?? XtreamSeriesInfoResponse()
        self.seriesInfo = info
        if let firstSeason = info.sortedSeasonNumbers.first {
            self.selectedSeason = firstSeason
        }
    }
}
