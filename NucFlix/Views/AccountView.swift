import SwiftUI
import LocalAuthentication

// Authentic Netflix iOS Accent Blue for Downloads & Storage Bars
private let netflixDownloadBlue = Color(red: 0.0, green: 0.44, blue: 0.92) // #0071EB
private let netflixSurfaceGray = Color(red: 0.10, green: 0.10, blue: 0.10)  // #1A1A1A
private let netflixElevatedRow = Color(red: 0.14, green: 0.14, blue: 0.14)  // #242424
private let netflixMutedText = Color(red: 0.64, green: 0.64, blue: 0.64)    // #A3A3A3

// MARK: - 1. Authentic Netflix iOS "Downloads" Screen

struct DownloadsView: View {
    @Environment(AppState.self) var appState
    private var downloadManager = DownloadManager.shared
    @Environment(\.dismiss) private var dismiss

    private var hasAnyDownloadsOrTransfers: Bool {
        !downloadManager.downloadedItems.isEmpty ||
        !downloadManager.activeDownloads.isEmpty ||
        !downloadManager.queuedDownloads.isEmpty
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        // Top Netflix "Smart Downloads" Header Bar
                        HStack(spacing: 8) {
                            Image(systemName: "gearshape")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.85))
                            Text("Smart Downloads")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.85))
                            Text("• \(downloadManager.preferredQualityPreset.shortLabel)")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(netflixDownloadBlue)
                            Spacer()
                            if !downloadManager.queuedDownloads.isEmpty {
                                Button("Clear Queue") {
                                    downloadManager.clearQueue()
                                }
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.75))
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)

                        Divider().overlay(Color.white.opacity(0.10))

                        if let err = downloadManager.lastDownloadError {
                            downloadErrorBanner(err)
                                .padding(.top, 12)
                        }

                        if !hasAnyDownloadsOrTransfers {
                            emptyDownloadsState
                        } else {
                            // 1. TV Series (Grouped Under Same Series Poster)
                            let seriesGroups = downloadManager.groupedSeriesDownloads
                            if !seriesGroups.isEmpty {
                                VStack(alignment: .leading, spacing: 0) {
                                    ForEach(seriesGroups) { group in
                                        NavigationLink {
                                            SeriesDownloadsDetailView(
                                                groupID: group.id,
                                                onPlayEpisode: { item in
                                                    playOfflineItem(item)
                                                }
                                            )
                                            .environment(appState)
                                        } label: {
                                            netflixSeriesGroupRow(group)
                                        }
                                        .buttonStyle(.plain)

                                        Divider()
                                            .overlay(Color.white.opacity(0.08))
                                            .padding(.leading, 16)
                                    }
                                }
                            }

                            // 2. Movies (Individual Movie Rows)
                            let activeMovies = downloadManager.activeMovieDownloads
                            let queuedMovies = downloadManager.queuedMovieDownloads
                            let completedMovies = downloadManager.downloadedMoviesOnly

                            if !activeMovies.isEmpty || !queuedMovies.isEmpty || !completedMovies.isEmpty {
                                VStack(alignment: .leading, spacing: 0) {
                                    ForEach(activeMovies) { active in
                                        netflixActiveMovieRow(active)
                                        Divider().overlay(Color.white.opacity(0.08)).padding(.leading, 16)
                                    }

                                    ForEach(queuedMovies) { queued in
                                        netflixQueuedMovieRow(queued)
                                        Divider().overlay(Color.white.opacity(0.08)).padding(.leading, 16)
                                    }

                                    ForEach(completedMovies) { movieItem in
                                        netflixCompletedMovieRow(movieItem)
                                        Divider().overlay(Color.white.opacity(0.08)).padding(.leading, 16)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.bottom, 24)
                }
            }
            .navigationTitle("Downloads")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                }
            }
            .safeAreaInset(edge: .bottom) {
                NetflixDeviceStorageBar(
                    totalDeviceBytes: downloadManager.deviceTotalDiskBytes,
                    freeDeviceBytes: downloadManager.deviceFreeDiskBytes,
                    nucflixBytes: downloadManager.totalStorageBytes,
                    formattedNucflix: downloadManager.formattedTotalStorage,
                    formattedFree: downloadManager.formattedDeviceFreeSpace,
                    hasDownloads: !downloadManager.downloadedItems.isEmpty,
                    onDeleteAll: {
                        downloadManager.clearAllDownloads()
                    }
                )
            }
        }
        .preferredColorScheme(.dark)
    }

    private func playOfflineItem(_ item: DownloadedMediaItem) {
        let resume = appState.savedProgress(for: item.id)?.positionSeconds ?? 0
        dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            appState.startPlayback(item.toPlaybackItem(resumeSeconds: resume))
        }
    }

    // MARK: - Authentic Netflix Series Grouped Row (Stacked Thumbnail + Title + "X Episodes | Y GB" + Chevron)

    private func netflixSeriesGroupRow(_ group: DownloadedSeriesGroup) -> some View {
        let resolvedPoster: String? = {
            if let sID = group.seriesID,
               let match = appState.seriesByID(sID),
               let cover = match.cover, !cover.isEmpty {
                return cover
            }
            return group.artworkURL
        }()

        return HStack(spacing: 14) {
            // Netflix Stacked Series Thumbnail
            ZStack {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color(white: 0.24))
                    .frame(width: 102, height: 58)
                    .offset(y: -6)

                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color(white: 0.17))
                    .frame(width: 108, height: 61)
                    .offset(y: -3)

                ArtworkImageView(
                    urlString: resolvedPoster,
                    fallbackTitle: group.title,
                    fallbackIcon: "tv"
                )
                .frame(width: 114, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            }
            .padding(.top, 6)

            VStack(alignment: .leading, spacing: 4) {
                Text(group.title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                if !group.downloadedEpisodes.isEmpty {
                    let count = group.downloadedEpisodes.count
                    Text("\(count) \(count == 1 ? "Episode" : "Episodes") | \(group.formattedTotalSize)")
                        .font(.system(size: 13))
                        .foregroundStyle(netflixMutedText)
                }

                if let active = group.activeEpisodes.first {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Downloading \(Int(active.progress * 100))% • \(group.totalInFlightCount) remaining")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(netflixDownloadBlue)
                            .lineLimit(1)

                        ProgressView(value: active.progress)
                            .tint(netflixDownloadBlue)
                    }
                    .padding(.top, 2)
                } else if !group.queuedEpisodes.isEmpty {
                    Text("\(group.queuedEpisodes.count) queued")
                        .font(.system(size: 12))
                        .foregroundStyle(netflixMutedText)
                }
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(netflixMutedText)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    // MARK: - Authentic Netflix Movie Rows

    private func netflixActiveMovieRow(_ active: ActiveDownloadItem) -> some View {
        HStack(spacing: 14) {
            ArtworkImageView(
                urlString: active.artworkURL,
                fallbackTitle: active.cleanTitle,
                fallbackIcon: "film"
            )
            .frame(width: 114, height: 64)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))

            VStack(alignment: .leading, spacing: 5) {
                Text(active.cleanTitle)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                Text(active.progressDetailText)
                    .font(.system(size: 12))
                    .foregroundStyle(netflixDownloadBlue)
                    .lineLimit(1)

                ProgressView(value: active.progress)
                    .tint(netflixDownloadBlue)
            }

            Spacer()

            Button {
                downloadManager.cancelDownload(id: active.id)
            } label: {
                Image(systemName: "stop.circle")
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(netflixMutedText)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func netflixQueuedMovieRow(_ queued: ActiveDownloadItem) -> some View {
        HStack(spacing: 14) {
            ArtworkImageView(
                urlString: queued.artworkURL,
                fallbackTitle: queued.cleanTitle,
                fallbackIcon: "film"
            )
            .frame(width: 114, height: 64)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(queued.cleanTitle)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                Text("Waiting in queue • \(queued.qualityLabel)")
                    .font(.system(size: 13))
                    .foregroundStyle(netflixMutedText)
            }

            Spacer()

            Button {
                downloadManager.cancelDownload(id: queued.id)
            } label: {
                Image(systemName: "xmark.circle")
                    .font(.system(size: 20))
                    .foregroundStyle(netflixMutedText)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func netflixCompletedMovieRow(_ item: DownloadedMediaItem) -> some View {
        HStack(spacing: 14) {
            Button {
                playOfflineItem(item)
            } label: {
                HStack(spacing: 14) {
                    ZStack {
                        ArtworkImageView(
                            urlString: item.artworkURL,
                            fallbackTitle: item.cleanTitle,
                            fallbackIcon: "film"
                        )
                        .frame(width: 114, height: 64)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))

                        Circle()
                            .fill(.black.opacity(0.6))
                            .frame(width: 30, height: 30)
                            .overlay(Circle().stroke(Color.white, lineWidth: 1.2))
                            .overlay(
                                Image(systemName: "play.fill")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundStyle(.white)
                                    .offset(x: 1)
                            )
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.cleanTitle)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(2)

                        Text("Movie | \(item.formattedSize)")
                            .font(.system(size: 13))
                            .foregroundStyle(netflixMutedText)
                    }
                }
            }
            .buttonStyle(.plain)

            Spacer()

            Menu {
                Button {
                    playOfflineItem(item)
                } label: {
                    Label("Play", systemImage: "play.fill")
                }

                Button(role: .destructive) {
                    downloadManager.deleteDownload(id: item.id)
                } label: {
                    Label("Delete Download", systemImage: "trash")
                }
            } label: {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(netflixDownloadBlue)
                    .padding(6)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func downloadErrorBanner(_ err: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.circle")
                .foregroundStyle(.white)
            Text(err)
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.9))
            Spacer()
            if downloadManager.lastFailedItem != nil {
                Button("Retry") {
                    downloadManager.retryLastFailedDownload()
                }
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color(white: 0.25), in: Capsule())
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .background(netflixSurfaceGray, in: RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal, 16)
    }

    private var emptyDownloadsState: some View {
        VStack(spacing: 18) {
            Spacer().frame(height: 64)
            ZStack {
                Circle()
                    .fill(Color(white: 0.11))
                    .frame(width: 96, height: 96)
                Image(systemName: "arrow.down.to.line")
                    .font(.system(size: 38, weight: .regular))
                    .foregroundStyle(.white.opacity(0.6))
            }
            Text("Movies and TV Shows You Download Appear Here")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            Text("Downloads remain available on your iPhone even when you're offline.")
                .font(.system(size: 14))
                .foregroundStyle(netflixMutedText)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 44)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Authentic Netflix iOS Device Storage Bar Component (Used in Downloads & App Settings)

struct NetflixDeviceStorageBar: View {
    let totalDeviceBytes: Int64
    let freeDeviceBytes: Int64
    let nucflixBytes: Int64
    let formattedNucflix: String
    let formattedFree: String
    let hasDownloads: Bool
    var onDeleteAll: (() -> Void)? = nil

    var body: some View {
        let total = max(Double(totalDeviceBytes), 1)
        let free = Double(freeDeviceBytes)
        let nucflix = Double(nucflixBytes)
        let usedOther = max(total - free - nucflix, 0)

        let otherFraction = min(max(usedOther / total, 0.06), 0.88)
        let nucflixFraction = nucflix > 0 ? max(nucflix / total, 0.03) : 0

        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("iPhone Storage")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer()
                if hasDownloads, let onDeleteAll {
                    Button(role: .destructive, action: onDeleteAll) {
                        Text("Delete All Downloads")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.8))
                    }
                    .buttonStyle(.plain)
                }
            }

            // Classic Netflix 3-Segment Horizontal Storage Bar
            GeometryReader { geo in
                HStack(spacing: 1.5) {
                    Rectangle()
                        .fill(Color(white: 0.42))
                        .frame(width: geo.size.width * otherFraction)

                    if nucflixFraction > 0 {
                        Rectangle()
                            .fill(netflixDownloadBlue)
                            .frame(width: geo.size.width * nucflixFraction)
                    }

                    Rectangle()
                        .fill(Color(white: 0.18))
                }
            }
            .frame(height: 10)
            .clipShape(RoundedRectangle(cornerRadius: 2))

            // Legend with Square Dots (Matches Real Netflix App Settings)
            HStack(spacing: 16) {
                HStack(spacing: 5) {
                    Rectangle().fill(Color(white: 0.42)).frame(width: 8, height: 8)
                    Text("Used")
                        .font(.system(size: 11))
                        .foregroundStyle(netflixMutedText)
                }

                HStack(spacing: 5) {
                    Rectangle().fill(netflixDownloadBlue).frame(width: 8, height: 8)
                    Text("NucFlix (\(formattedNucflix))")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                }

                HStack(spacing: 5) {
                    Rectangle().fill(Color(white: 0.22)).frame(width: 8, height: 8)
                    Text("Free (\(formattedFree))")
                        .font(.system(size: 11))
                        .foregroundStyle(netflixMutedText)
                }

                Spacer()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            Color(red: 0.07, green: 0.07, blue: 0.07)
                .overlay(alignment: .top) {
                    Rectangle().fill(Color.white.opacity(0.10)).frame(height: 0.5)
                }
        )
    }
}

// MARK: - Series Episodes Drill-Down View (Inside a Downloaded Series)

struct SeriesDownloadsDetailView: View {
    @Environment(AppState.self) var appState
    private var downloadManager = DownloadManager.shared
    @Environment(\.dismiss) private var dismiss

    let groupID: String
    let onPlayEpisode: (DownloadedMediaItem) -> Void

    private var group: DownloadedSeriesGroup? {
        downloadManager.groupedSeriesDownloads.first { $0.id == groupID }
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let group {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        // Active Episodes
                        ForEach(group.activeEpisodes) { active in
                            HStack(spacing: 14) {
                                ArtworkImageView(
                                    urlString: active.artworkURL ?? group.artworkURL,
                                    fallbackTitle: active.cleanTitle,
                                    fallbackIcon: "tv"
                                )
                                .frame(width: 114, height: 64)
                                .clipShape(RoundedRectangle(cornerRadius: 4))

                                VStack(alignment: .leading, spacing: 5) {
                                    Text(active.subtitle ?? active.cleanTitle)
                                        .font(.system(size: 15, weight: .semibold))
                                        .foregroundStyle(.white)
                                        .lineLimit(1)
                                    Text(active.progressDetailText)
                                        .font(.system(size: 12))
                                        .foregroundStyle(netflixDownloadBlue)
                                        .lineLimit(1)
                                    ProgressView(value: active.progress)
                                        .tint(netflixDownloadBlue)
                                }

                                Spacer()

                                Button {
                                    downloadManager.cancelDownload(id: active.id)
                                } label: {
                                    Image(systemName: "stop.circle")
                                        .font(.system(size: 22))
                                        .foregroundStyle(netflixMutedText)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)

                            Divider().overlay(Color.white.opacity(0.08)).padding(.leading, 16)
                        }

                        // Queued Episodes
                        ForEach(group.queuedEpisodes) { queued in
                            HStack(spacing: 14) {
                                ArtworkImageView(
                                    urlString: queued.artworkURL ?? group.artworkURL,
                                    fallbackTitle: queued.cleanTitle,
                                    fallbackIcon: "tv"
                                )
                                .frame(width: 114, height: 64)
                                .clipShape(RoundedRectangle(cornerRadius: 4))

                                VStack(alignment: .leading, spacing: 4) {
                                    Text(queued.subtitle ?? queued.cleanTitle)
                                        .font(.system(size: 15, weight: .semibold))
                                        .foregroundStyle(.white)
                                        .lineLimit(1)
                                    Text("Queued • \(queued.qualityLabel)")
                                        .font(.system(size: 12))
                                        .foregroundStyle(netflixMutedText)
                                }

                                Spacer()

                                Button {
                                    downloadManager.prioritizeQueuedDownload(id: queued.id)
                                } label: {
                                    Image(systemName: "arrow.up.to.line")
                                        .font(.system(size: 15))
                                        .foregroundStyle(.white.opacity(0.8))
                                        .padding(6)
                                }
                                .buttonStyle(.plain)

                                Button {
                                    downloadManager.cancelDownload(id: queued.id)
                                } label: {
                                    Image(systemName: "xmark.circle")
                                        .font(.system(size: 20))
                                        .foregroundStyle(netflixMutedText)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)

                            Divider().overlay(Color.white.opacity(0.08)).padding(.leading, 16)
                        }

                        // Completed Episodes
                        ForEach(group.downloadedEpisodes) { ep in
                            HStack(spacing: 14) {
                                Button {
                                    onPlayEpisode(ep)
                                } label: {
                                    HStack(spacing: 14) {
                                        ZStack {
                                            ArtworkImageView(
                                                urlString: ep.artworkURL ?? group.artworkURL,
                                                fallbackTitle: ep.cleanTitle,
                                                fallbackIcon: "tv"
                                            )
                                            .frame(width: 114, height: 64)
                                            .clipShape(RoundedRectangle(cornerRadius: 4))

                                            Circle()
                                                .fill(.black.opacity(0.6))
                                                .frame(width: 30, height: 30)
                                                .overlay(Circle().stroke(Color.white, lineWidth: 1.2))
                                                .overlay(
                                                    Image(systemName: "play.fill")
                                                        .font(.system(size: 12, weight: .bold))
                                                        .foregroundStyle(.white)
                                                        .offset(x: 1)
                                                )
                                        }

                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(ep.subtitle ?? ep.cleanTitle)
                                                .font(.system(size: 15, weight: .semibold))
                                                .foregroundStyle(.white)
                                                .lineLimit(2)

                                            Text(ep.formattedSize)
                                                .font(.system(size: 13))
                                                .foregroundStyle(netflixMutedText)
                                        }
                                    }
                                }
                                .buttonStyle(.plain)

                                Spacer()

                                Menu {
                                    Button {
                                        onPlayEpisode(ep)
                                    } label: {
                                        Label("Play Episode", systemImage: "play.fill")
                                    }

                                    Button(role: .destructive) {
                                        downloadManager.deleteDownload(id: ep.id)
                                    } label: {
                                        Label("Delete Episode", systemImage: "trash")
                                    }
                                } label: {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.system(size: 22))
                                        .foregroundStyle(netflixDownloadBlue)
                                        .padding(6)
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)

                            Divider().overlay(Color.white.opacity(0.08)).padding(.leading, 16)
                        }
                    }
                }
            } else {
                ContentUnavailableView("No Episodes Remaining", systemImage: "tv.slash")
            }
        }
        .navigationTitle(group?.title ?? "Series")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let group {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .destructive) {
                        downloadManager.deleteSeriesGroup(group)
                        dismiss()
                    } label: {
                        Image(systemName: "trash")
                            .foregroundStyle(.white)
                    }
                }
            }
        }
    }
}

// MARK: - 2. Authentic Netflix iOS "App Settings" & "Account" Screen (Zero Rainbow Icons, Pure Netflix Design)

struct AccountView: View {
    @Environment(AppState.self) var appState
    @Environment(CloudAccount.self) var cloud
    @State private var showLines = false
    @State private var showPairTV = false
    private var downloadManager = DownloadManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var showAdultConfirmation = false
    @State private var adultAuthError: String?

    /// Toggle binding that gates turning NSFW ON behind an 18+ confirmation + device authentication
    private var adultContentBinding: Binding<Bool> {
        Binding(
            get: { appState.showAdultContent },
            set: { newValue in
                if newValue {
                    showAdultConfirmation = true
                } else {
                    withAnimation(.snappy) { appState.showAdultContent = false }
                }
            }
        )
    }

    private func authenticateAndEnableAdultContent() {
        let context = LAContext()
        var error: NSError?
        let policy = LAPolicy.deviceOwnerAuthentication
        guard context.canEvaluatePolicy(policy, error: &error) else {
            // No passcode configured on the device — fall back to the 18+ confirmation alone
            withAnimation(.snappy) { appState.showAdultContent = true }
            return
        }
        context.evaluatePolicy(policy, localizedReason: "Unlock adult (NSFW) content on NucFlix") { success, authError in
            DispatchQueue.main.async {
                if success {
                    withAnimation(.snappy) { appState.showAdultContent = true }
                } else if let authError, (authError as? LAError)?.code != .userCancel {
                    adultAuthError = authError.localizedDescription
                }
            }
        }
    }

    private var contentFilterSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            netflixSectionHeader("Content & Parental Controls")

            VStack(spacing: 0) {
                HStack(spacing: 16) {
                    Image(systemName: appState.showAdultContent ? "eye" : "eye.slash")
                        .font(.system(size: 20, weight: .regular))
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(width: 24)
                        .contentTransition(.symbolEffect(.replace))

                    VStack(alignment: .leading, spacing: 3) {
                        Text("Show Adult Content (NSFW)")
                            .font(.system(size: 16, weight: .regular))
                            .foregroundStyle(.white)
                        Text(appState.showAdultContent
                             ? "18+ categories, titles and suggestions are visible"
                             : "18+ categories, titles, search results and suggestions are hidden")
                            .font(.system(size: 13))
                            .foregroundStyle(netflixMutedText)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer()

                    Toggle("", isOn: adultContentBinding)
                        .labelsHidden()
                        .tint(AppTheme.netflixRed)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
            .background(netflixSurfaceGray, in: RoundedRectangle(cornerRadius: 8))

            Text("Turning this on requires Face ID, Touch ID or your device passcode.")
                .font(.system(size: 12))
                .foregroundStyle(netflixMutedText)
                .padding(.horizontal, 4)
        }
        .confirmationDialog(
            "Are you 18 or older?",
            isPresented: $showAdultConfirmation,
            titleVisibility: .visible
        ) {
            Button("I'm 18+ — Show Adult Content", role: .destructive) {
                authenticateAndEnableAdultContent()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Adult content contains explicit material. You'll be asked to authenticate.")
        }
        .alert("Couldn't Unlock", isPresented: Binding(
            get: { adultAuthError != nil },
            set: { if !$0 { adultAuthError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(adultAuthError ?? "")
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 26) {
                        // Top Netflix Profile Header
                        netflixProfileHeader

                        // Section 1: VIDEO PLAYBACK (Exact Netflix App Settings Layout)
                        VStack(alignment: .leading, spacing: 8) {
                            netflixSectionHeader("Video Playback")

                            VStack(spacing: 0) {
                                // Stream Quality Row (Custom Menu - Never Wraps Multi-line Red Text)
                                Menu {
                                    ForEach(StreamQualityPreference.allCases) { qual in
                                        Button {
                                            appState.preferredStreamQuality = qual
                                        } label: {
                                            HStack {
                                                Text(qual.displayName)
                                                if appState.preferredStreamQuality == qual {
                                                    Image(systemName: "checkmark")
                                                }
                                            }
                                        }
                                    }
                                } label: {
                                    netflixSettingMenuRow(
                                        icon: "speedometer",
                                        title: "Stream Quality",
                                        subtitle: appState.preferredStreamQuality.displayName,
                                        value: appState.preferredStreamQuality.shortLabel
                                    )
                                }
                                .buttonStyle(.plain)

                                rowDivider

                                // Live Stream Format Row
                                Menu {
                                    ForEach(LiveStreamFormat.allCases) { format in
                                        Button {
                                            appState.preferredLiveFormat = format
                                        } label: {
                                            HStack {
                                                Text(format.displayName)
                                                if appState.preferredLiveFormat == format {
                                                    Image(systemName: "checkmark")
                                                }
                                            }
                                        }
                                    }
                                } label: {
                                    netflixSettingMenuRow(
                                        icon: "antenna.radiowaves.left.and.right",
                                        title: "Live TV Stream Format",
                                        subtitle: "Protocol used for Live TV channels",
                                        value: appState.preferredLiveFormat == .mpegTS ? "MPEG-TS (.ts)" : "HLS (.m3u8)"
                                    )
                                }
                                .buttonStyle(.plain)

                                rowDivider

                                // Hardware Decoding Toggle Row
                                HStack(spacing: 16) {
                                    Image(systemName: "tv")
                                        .font(.system(size: 20, weight: .regular))
                                        .foregroundStyle(.white.opacity(0.85))
                                        .frame(width: 24)

                                    VStack(alignment: .leading, spacing: 3) {
                                        Text("Hardware Decoding")
                                            .font(.system(size: 16, weight: .regular))
                                            .foregroundStyle(.white)
                                        Text("Smooth 4K HEVC & MKV playback")
                                            .font(.system(size: 13))
                                            .foregroundStyle(netflixMutedText)
                                    }

                                    Spacer()

                                    Toggle("", isOn: Bindable(appState).hardwareAccelerationEnabled)
                                        .labelsHidden()
                                        .tint(netflixDownloadBlue)
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 14)

                                rowDivider

                                // Autoplay Next Episode Toggle Row
                                HStack(spacing: 16) {
                                    Image(systemName: "forward.end")
                                        .font(.system(size: 20, weight: .regular))
                                        .foregroundStyle(.white.opacity(0.85))
                                        .frame(width: 24)

                                    VStack(alignment: .leading, spacing: 3) {
                                        Text("Autoplay Next Episode")
                                            .font(.system(size: 16, weight: .regular))
                                            .foregroundStyle(.white)
                                        Text("Play the next episode automatically when one ends")
                                            .font(.system(size: 13))
                                            .foregroundStyle(netflixMutedText)
                                    }

                                    Spacer()

                                    Toggle("", isOn: Bindable(appState).autoplayNextEpisode)
                                        .labelsHidden()
                                        .tint(netflixDownloadBlue)
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 14)
                            }
                            .background(netflixSurfaceGray, in: RoundedRectangle(cornerRadius: 8))
                        }

                        // Content & Parental Controls (NSFW filter)
                        contentFilterSection

                        // Section 2: DOWNLOADS (Exact Netflix App Settings Layout + Storage Bar)
                        VStack(alignment: .leading, spacing: 8) {
                            netflixSectionHeader("Downloads")

                            VStack(spacing: 0) {
                                // Download Video Quality
                                Menu {
                                    ForEach(DownloadQualityPreset.allCases) { preset in
                                        Button {
                                            downloadManager.preferredQualityPreset = preset
                                        } label: {
                                            HStack {
                                                Text(preset.displayName)
                                                if downloadManager.preferredQualityPreset == preset {
                                                    Image(systemName: "checkmark")
                                                }
                                            }
                                        }
                                    }
                                } label: {
                                    netflixSettingMenuRow(
                                        icon: "film",
                                        title: "Download Video Quality",
                                        subtitle: downloadQualitySubtitle,
                                        value: downloadManager.preferredQualityPreset.shortLabel
                                    )
                                }
                                .buttonStyle(.plain)

                                rowDivider

                                // Simultaneous Transfers
                                Menu {
                                    Button {
                                        downloadManager.maxConcurrentDownloads = 1
                                    } label: {
                                        HStack {
                                            Text("1 at a time (Recommended)")
                                            if downloadManager.maxConcurrentDownloads == 1 {
                                                Image(systemName: "checkmark")
                                            }
                                        }
                                    }
                                    Button {
                                        downloadManager.maxConcurrentDownloads = 2
                                    } label: {
                                        HStack {
                                            Text("2 Parallel Downloads")
                                            if downloadManager.maxConcurrentDownloads == 2 {
                                                Image(systemName: "checkmark")
                                            }
                                        }
                                    }
                                } label: {
                                    netflixSettingMenuRow(
                                        icon: "arrow.down.to.line",
                                        title: "Concurrent Downloads",
                                        subtitle: "Sequential queueing prevents server limits",
                                        value: downloadManager.maxConcurrentDownloads == 1 ? "1 at a time" : "2 Parallel"
                                    )
                                }
                                .buttonStyle(.plain)

                                rowDivider

                                // Delete All Downloads Row
                                Button(role: .destructive) {
                                    downloadManager.clearAllDownloads()
                                } label: {
                                    HStack(spacing: 16) {
                                        Image(systemName: "trash")
                                            .font(.system(size: 20, weight: .regular))
                                            .foregroundStyle(.white.opacity(0.85))
                                            .frame(width: 24)

                                        VStack(alignment: .leading, spacing: 3) {
                                            Text("Delete All Downloads")
                                                .font(.system(size: 16, weight: .regular))
                                                .foregroundStyle(.white)
                                            Text("\(downloadManager.downloadedItems.count) downloaded \(downloadManager.downloadedItems.count == 1 ? "file" : "files")")
                                                .font(.system(size: 13))
                                                .foregroundStyle(netflixMutedText)
                                        }

                                        Spacer()

                                        Text(downloadManager.formattedTotalStorage)
                                            .font(.system(size: 14))
                                            .foregroundStyle(netflixMutedText)
                                    }
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 14)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .disabled(downloadManager.downloadedItems.isEmpty)

                                rowDivider

                                // Embedded Netflix iPhone Storage Meter
                                NetflixDeviceStorageBar(
                                    totalDeviceBytes: downloadManager.deviceTotalDiskBytes,
                                    freeDeviceBytes: downloadManager.deviceFreeDiskBytes,
                                    nucflixBytes: downloadManager.totalStorageBytes,
                                    formattedNucflix: downloadManager.formattedTotalStorage,
                                    formattedFree: downloadManager.formattedDeviceFreeSpace,
                                    hasDownloads: false
                                )
                            }
                            .background(netflixSurfaceGray, in: RoundedRectangle(cornerRadius: 8))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        }

                        // Section 3: ACCOUNT & MEMBERSHIP DETAILS (Netflix Account Style)
                        VStack(alignment: .leading, spacing: 8) {
                            netflixSectionHeader("Account & Subscription")

                            VStack(spacing: 0) {
                                netflixInfoRow(
                                    label: "IPTV Line",
                                    value: appState.credentials?.lineName ?? "—"
                                )
                                rowDividerIndented

                                netflixInfoRow(
                                    label: "Username",
                                    value: appState.userInfo?.username ?? appState.credentials?.username ?? "-"
                                )
                                rowDividerIndented

                                netflixInfoRow(
                                    label: "Status",
                                    value: "\(appState.userInfo?.status ?? "Active") • \(appState.userInfo?.expirationCountdownText ?? "Unlimited")",
                                    valueColor: .white
                                )
                                rowDividerIndented

                                netflixInfoRow(
                                    label: "Expiration Date",
                                    value: localExpiryShortText
                                )
                                rowDividerIndented

                                netflixInfoRow(
                                    label: "Active Streams",
                                    value: "\(appState.userInfo?.activeCons?.value ?? "0") of \(appState.userInfo?.maxConnections?.value ?? "1") allowed"
                                )
                                rowDividerIndented

                                netflixInfoRow(
                                    label: "Server Host",
                                    value: appState.credentials?.normalizedBaseURL ?? "-"
                                )
                            }
                            .background(netflixSurfaceGray, in: RoundedRectangle(cornerRadius: 8))
                        }

                        // Section 4: CATALOG & DIAGNOSTICS
                        VStack(alignment: .leading, spacing: 8) {
                            netflixSectionHeader("Catalog")

                            VStack(spacing: 0) {
                                netflixInfoRow(
                                    label: "Indexed Library",
                                    value: "\(appState.allLoadedMovies.count.formatted()) Movies • \(appState.allLoadedSeries.count.formatted()) Series • \(appState.allLoadedLiveStreams.count.formatted()) Live"
                                )
                                rowDividerIndented

                                if let syncDate = appState.lastCatalogSyncDate {
                                    netflixInfoRow(
                                        label: "Last Synced",
                                        value: syncDate.formatted(date: .abbreviated, time: .shortened)
                                    )
                                    rowDividerIndented
                                }

                                Button {
                                    Task {
                                        await appState.refreshAllCatalogs(force: true)
                                    }
                                } label: {
                                    HStack(spacing: 16) {
                                        Image(systemName: "arrow.clockwise")
                                            .font(.system(size: 18, weight: .regular))
                                            .foregroundStyle(.white.opacity(0.85))
                                            .frame(width: 24)

                                        Text(appState.isIndexingFullCatalog ? "Refreshing Catalog..." : "Refresh Catalog Now")
                                            .font(.system(size: 16, weight: .regular))
                                            .foregroundStyle(.white)

                                        Spacer()

                                        if appState.isIndexingFullCatalog {
                                            ProgressView().tint(.white)
                                        } else {
                                            Image(systemName: "chevron.right")
                                                .font(.system(size: 13, weight: .semibold))
                                                .foregroundStyle(netflixMutedText)
                                        }
                                    }
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 14)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                            .background(netflixSurfaceGray, in: RoundedRectangle(cornerRadius: 8))
                        }

                        // NucFlix account: profile, IPTV lines, sign out
                        VStack(alignment: .leading, spacing: 8) {
                            netflixSectionHeader("NucFlix Account")

                            VStack(spacing: 0) {
                                Button {
                                    dismiss()
                                    cloud.selectProfile(nil)
                                } label: {
                                    netflixSettingMenuRow(
                                        icon: "person.2",
                                        title: "Switch Profile",
                                        subtitle: "Who's watching?",
                                        value: cloud.selectedProfile?.name ?? ""
                                    )
                                }
                                .buttonStyle(.plain)

                                rowDivider

                                Button {
                                    showLines = true
                                } label: {
                                    netflixSettingMenuRow(
                                        icon: "antenna.radiowaves.left.and.right",
                                        title: "IPTV Lines",
                                        subtitle: "Shared by every profile and your TVs",
                                        value: cloud.activeLine?.name ?? ""
                                    )
                                }
                                .buttonStyle(.plain)

                                rowDivider

                                Button {
                                    showPairTV = true
                                } label: {
                                    netflixSettingMenuRow(
                                        icon: "tv",
                                        title: "Pair a TV",
                                        subtitle: "Enter the code shown on your Fire TV",
                                        value: cloud.pairedTVs.isEmpty ? "" : "\(cloud.pairedTVs.count) paired"
                                    )
                                }
                                .buttonStyle(.plain)

                                rowDivider

                                netflixInfoRow(label: "Signed in as", value: cloud.email ?? cloud.displayName ?? "—")
                            }
                            .background(netflixSurfaceGray, in: RoundedRectangle(cornerRadius: 8))
                        }
                        .sheet(isPresented: $showPairTV) {
                            PairTVView()
                                .environment(cloud)
                        }
                        .sheet(isPresented: $showLines) {
                            LinesView()
                                .environment(cloud)
                                .environment(appState)
                        }

                        // Netflix Sign Out Footer
                        VStack(spacing: 14) {
                            Button {
                                dismiss()
                                appState.signOut()
                                cloud.signOut()
                            } label: {
                                Text("Sign Out")
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 46)
                                    .background(netflixSurfaceGray, in: RoundedRectangle(cornerRadius: 6))
                            }
                            .buttonStyle(.plain)

                            Text("NucFlix for iOS • Version 2.4.0 (Build 2945)")
                                .font(.system(size: 12))
                                .foregroundStyle(Color(white: 0.42))
                        }
                        .padding(.top, 4)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 16)
                    .padding(.bottom, 28)
                }
            }
            .navigationTitle("App Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Authentic Netflix Profile Header ("My Netflix" Style)

    private var netflixProfileHeader: some View {
        HStack(spacing: 14) {
            // Classic Netflix Flat Square Profile Avatar (Exact 54x54 Canvas)
            Canvas { context, size in
                let rect = CGRect(origin: .zero, size: size)
                let bgPath = Path(roundedRect: rect, cornerRadius: 6)
                context.fill(
                    bgPath,
                    with: .linearGradient(
                        Gradient(colors: [
                            Color(red: 0.92, green: 0.06, blue: 0.10),
                            Color(red: 0.72, green: 0.02, blue: 0.05)
                        ]),
                        startPoint: .zero,
                        endPoint: CGPoint(x: 0, y: size.height)
                    )
                )

                // Left eye
                let leftEye = CGRect(x: 14, y: 17, width: 5.5, height: 5.5)
                context.fill(Path(ellipseIn: leftEye), with: .color(.white))

                // Right eye
                let rightEye = CGRect(x: 34.5, y: 17, width: 5.5, height: 5.5)
                context.fill(Path(ellipseIn: rightEye), with: .color(.white))

                // Classic Netflix Asymmetric/Curved Smile inside the square
                var smile = Path()
                smile.move(to: CGPoint(x: 13.5, y: 31.5))
                smile.addQuadCurve(
                    to: CGPoint(x: 40.5, y: 31.5),
                    control: CGPoint(x: 27, y: 42)
                )
                context.stroke(
                    smile,
                    with: .color(.white),
                    style: StrokeStyle(lineWidth: 2.8, lineCap: .round)
                )
            }
            .frame(width: 54, height: 54)

            VStack(alignment: .leading, spacing: 3) {
                Text(appState.credentials?.lineName ?? "NucFlix")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.white)

                Text("\(appState.credentials?.username ?? "") • \(appState.userInfo?.status ?? "Active")")
                    .font(.system(size: 13))
                    .foregroundStyle(netflixMutedText)
                    .lineLimit(1)
            }

            Spacer()

            Text("ACTIVE")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white.opacity(0.9))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color(white: 0.20), in: RoundedRectangle(cornerRadius: 4))
        }
        .padding(.horizontal, 4)
    }

    // MARK: - Netflix Row Building Blocks

    private var downloadQualitySubtitle: String {
        switch downloadManager.preferredQualityPreset {
        case .standard720p:
            return "Downloads faster and uses less storage."
        case .high1080p:
            return "Balanced 1080p Full HD video quality."
        case .original:
            return "Maximum server bitrate and resolution."
        case .askEveryTime:
            return "Prompt with file size before downloading."
        }
    }

    private func netflixSectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 18, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 4)
    }

    private func netflixSettingMenuRow(icon: String, title: String, subtitle: String, value: String) -> some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(.white)
                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(netflixMutedText)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            HStack(spacing: 6) {
                Text(value)
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(netflixMutedText)
                    .lineLimit(1)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color(white: 0.45))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .contentShape(Rectangle())
    }

    private func netflixInfoRow(label: String, value: String, valueColor: Color = netflixMutedText) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(.white)
            Spacer(minLength: 12)
            Text(value)
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(valueColor)
                .lineLimit(1)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private var rowDivider: some View {
        Divider()
            .overlay(Color.white.opacity(0.08))
            .padding(.leading, 56)
    }

    private var rowDividerIndented: some View {
        Divider()
            .overlay(Color.white.opacity(0.08))
            .padding(.leading, 16)
    }

    private var localExpiryShortText: String {
        guard let date = appState.userInfo?.expirationDate else { return "Unlimited" }
        return XtreamExpiryFormatter.date(date, timeZone: .current, includeTime: false)
    }
}

// MARK: - 3. Authentic Netflix iOS "Notifications" Screen

struct NotificationsView: View {
    @Environment(AppState.self) var appState
    private var notificationManager = NotificationManager.shared
    private var downloadManager = DownloadManager.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                if notificationManager.notifications.isEmpty {
                    VStack(spacing: 14) {
                        Image(systemName: "bell")
                            .font(.system(size: 40, weight: .light))
                            .foregroundStyle(netflixMutedText)
                        Text("No Notifications")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(.white)
                        Text("We'll let you know when your downloads finish or new titles arrive.")
                            .font(.system(size: 14))
                            .foregroundStyle(netflixMutedText)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 44)
                    }
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(notificationManager.notifications) { notif in
                                netflixNotificationRow(notif)
                                Divider()
                                    .overlay(Color.white.opacity(0.08))
                                    .padding(.leading, 26)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Notifications")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if !notificationManager.notifications.isEmpty {
                        Button("Clear") {
                            notificationManager.clearAll()
                        }
                        .font(.system(size: 15, weight: .regular))
                        .foregroundStyle(netflixMutedText)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        notificationManager.markAllAsRead()
                        dismiss()
                    }
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                }
            }
            .onAppear {
                notificationManager.seedFromExistingDownloads(downloadManager.downloadedItems)
                notificationManager.markAllAsRead()
            }
        }
        .preferredColorScheme(.dark)
    }

    private func netflixNotificationRow(_ notif: AppNotification) -> some View {
        let offlineItem = notif.relatedItemID.flatMap { downloadManager.downloadedItem(for: $0) }

        return Button {
            if let offlineItem {
                let resume = appState.savedProgress(for: offlineItem.id)?.positionSeconds ?? 0
                dismiss()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    appState.startPlayback(offlineItem.toPlaybackItem(resumeSeconds: resume))
                }
            }
        } label: {
            HStack(alignment: .center, spacing: 12) {
                // Unread Red Dot (Exact Netflix Notification Style)
                Circle()
                    .fill(notif.isRead ? Color.clear : AppTheme.netflixRed)
                    .frame(width: 8, height: 8)

                // Landscape Thumbnail (114x64)
                ZStack {
                    if let art = notif.artworkURL, !art.isEmpty {
                        ArtworkImageView(
                            urlString: art,
                            fallbackTitle: notif.title,
                            fallbackIcon: notif.category.iconName
                        )
                        .frame(width: 114, height: 64)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    } else {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(netflixSurfaceGray)
                            .frame(width: 114, height: 64)
                            .overlay(
                                Image(systemName: notif.category.iconName)
                                    .font(.system(size: 22, weight: .regular))
                                    .foregroundStyle(.white.opacity(0.8))
                            )
                    }

                    if offlineItem != nil {
                        Circle()
                            .fill(.black.opacity(0.55))
                            .frame(width: 28, height: 28)
                            .overlay(Circle().stroke(Color.white, lineWidth: 1.2))
                            .overlay(
                                Image(systemName: "play.fill")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(.white)
                                    .offset(x: 1)
                            )
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(notif.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(2)

                    Text(notif.message)
                        .font(.system(size: 13))
                        .foregroundStyle(netflixMutedText)
                        .lineLimit(2)

                    Text(notif.createdAt, style: .relative)
                        .font(.system(size: 12))
                        .foregroundStyle(Color(white: 0.45))
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
