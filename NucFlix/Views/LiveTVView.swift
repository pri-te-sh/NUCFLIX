import SwiftUI

struct LiveTVView: View {
    @Environment(AppState.self) var appState

    @State private var searchQuery: String = ""
    @State private var debouncedSearchQuery: String = ""
    @State private var selectedEPGChannel: XtreamLiveStream?
    @State private var showCategorySheet: Bool = false
    @State private var isGridView: Bool = false

    private let gridColumns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]

    private var activeCategoryTitle: String {
        if appState.selectedLiveCategoryID == "FAV" {
            return "★ My Favorites"
        }
        if let cat = appState.liveCategories.first(where: { $0.id == appState.selectedLiveCategoryID }) {
            return cat.cleanName
        }
        return appState.liveCategories.first?.cleanName ?? "Select Category"
    }

    private var currentStreams: [XtreamLiveStream] {
        let trimmed = debouncedSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return appState.searchLiveStreams(
                query: trimmed,
                prioritizeCategoryID: appState.selectedLiveCategoryID,
                limit: 180
            )
        }
        if appState.selectedLiveCategoryID == "FAV" {
            return appState.visibleFavoriteLiveChannels
        } else {
            return appState.liveStreamsByCategory[appState.selectedLiveCategoryID] ?? []
        }
    }

    var body: some View {
        let streams = currentStreams
        let channels = streams.filter { !$0.isSectionDivider }
        NavigationStack {
            ZStack {
                ObsidianBackgroundView()

                VStack(spacing: 0) {
                    topCategoryHeader(channelCount: channels.count)

                    quickCategoryBar

                    if appState.isLoadingLive && streams.isEmpty {
                        Spacer()
                        VStack(spacing: 12) {
                            ProgressView()
                                .tint(AppTheme.primaryRed)
                                .scaleEffect(1.2)
                            Text("Loading \(activeCategoryTitle)...")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.white.opacity(0.7))
                        }
                        Spacer()
                    } else if streams.isEmpty {
                        Spacer()
                        ContentUnavailableView(
                            "No Channels in \(activeCategoryTitle)",
                            systemImage: "tv.slash",
                            description: Text("Tap the category bar above to browse all \(appState.liveCategories.count) live categories.")
                        )
                        Spacer()
                    } else {
                        ScrollView {
                            if isGridView {
                                LazyVGrid(columns: gridColumns, spacing: 12) {
                                    ForEach(channels) { channel in
                                        channelGridCard(channel)
                                    }
                                }
                                .padding(16)
                            } else {
                                LazyVStack(spacing: 10) {
                                    ForEach(streams) { channel in
                                        if channel.isSectionDivider {
                                            sectionDividerRow(channel.cleanName)
                                        } else {
                                            channelListRow(channel)
                                        }
                                    }
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 12)
                            }
                        }
                        .refreshable {
                            await appState.refreshAllCatalogs(force: true)
                        }
                    }
                }
            }
            .navigationTitle("Live TV")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchQuery, prompt: "Search all live channels...")
            .task(id: searchQuery) {
                if searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    debouncedSearchQuery = ""
                } else {
                    try? await Task.sleep(nanoseconds: 150_000_000)
                    guard !Task.isCancelled else { return }
                    debouncedSearchQuery = searchQuery
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isGridView.toggle()
                    } label: {
                        Image(systemName: isGridView ? "list.bullet" : "square.grid.2x2")
                            .foregroundStyle(.white)
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .sensoryFeedback(.selection, trigger: isGridView)
                    .accessibilityLabel(isGridView ? "Show as list" : "Show as grid")
                }
            }
            .sheet(isPresented: $showCategorySheet) {
                CategoryExplorerSheet(
                    title: "Live TV Categories",
                    categories: appState.liveCategories,
                    selectedCategoryID: Bindable(appState).selectedLiveCategoryID,
                    favoritesCount: appState.visibleFavoriteLiveChannels.count
                ) { chosenID in
                    appState.selectLiveCategory(chosenID)
                }
            }
            .sheet(item: $selectedEPGChannel) { channel in
                EPGDrawerView(channelName: channel.cleanName, streamId: channel.streamId.value)
                    .environment(appState)
            }
            .onAppear {
                if appState.selectedLiveCategoryID.isEmpty, let first = appState.liveCategories.first {
                    appState.selectLiveCategory(first.id)
                } else if !appState.selectedLiveCategoryID.isEmpty,
                          appState.selectedLiveCategoryID != "FAV",
                          appState.liveStreamsByCategory[appState.selectedLiveCategoryID] == nil {
                    // Only fetch when not cached — avoids re-publishing AppState on every tab switch
                    appState.selectLiveCategory(appState.selectedLiveCategoryID)
                }
            }
        }
    }

    // MARK: - Prominent Category Selector Bar

    private func topCategoryHeader(channelCount: Int) -> some View {
        Button {
            showCategorySheet = true
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(AppTheme.accentGradient)
                        .frame(width: 34, height: 34)
                    Image(systemName: "line.3.horizontal.decrease")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(activeCategoryTitle)
                        .font(.system(size: 15, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text("Tap to search all \(appState.liveCategories.count) categories • \(channelCount) channels")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                }

                Spacer()

                HStack(spacing: 4) {
                    Text("Browse")
                        .font(.caption.weight(.bold))
                    Image(systemName: "chevron.down")
                        .font(.caption2.bold())
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(.white.opacity(0.1), in: Capsule())
                .foregroundStyle(.white)
            }
            .padding(12)
            .obsidianGlassCard(cornerRadius: 16)
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
        .buttonStyle(.plain)
    }

    private var quickCategoryBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                categoryChip(id: "FAV", prefix: "★", title: "Favorites (\(appState.visibleFavoriteLiveChannels.count))")
                ForEach(appState.liveCategories.prefix(30)) { cat in
                    categoryChip(id: cat.id, prefix: cat.prefixBadge, title: cat.cleanName)
                }
                if appState.liveCategories.count > 30 {
                    Button {
                        showCategorySheet = true
                    } label: {
                        Text("+ \(appState.liveCategories.count - 30) More...")
                            .font(.caption.weight(.bold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(AppTheme.primaryRed.opacity(0.2), in: Capsule())
                            .foregroundStyle(AppTheme.primaryRed)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }

    private func categoryChip(id: String, prefix: String?, title: String) -> some View {
        let isSelected = appState.selectedLiveCategoryID == id
        return Button {
            appState.selectLiveCategory(id)
        } label: {
            HStack(spacing: 5) {
                if let prefix, !prefix.isEmpty {
                    Text(prefix)
                        .font(.system(size: 9, weight: .black, design: .rounded))
                        .opacity(0.85)
                }
                Text(title)
                    .font(.caption.weight(.bold))
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 8)
            .background(
                isSelected ? AnyShapeStyle(AppTheme.accentGradient) : AnyShapeStyle(Color.white.opacity(0.07)),
                in: Capsule()
            )
            .overlay(
                Capsule().stroke(.white.opacity(isSelected ? 0.35 : 0.08), lineWidth: 0.6)
            )
            .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
    }

    private func sectionDividerRow(_ title: String) -> some View {
        HStack(spacing: 10) {
            Rectangle()
                .fill(AppTheme.accentGradient)
                .frame(width: 4, height: 16)
                .clipShape(Capsule())
            Text(title)
                .font(.system(size: 11, weight: .heavy, design: .rounded))
                .tracking(0.8)
                .foregroundStyle(.white.opacity(0.75))
            Spacer()
        }
        .padding(.top, 10)
        .padding(.bottom, 2)
        .padding(.horizontal, 4)
    }

    // MARK: - Channel List Row & Grid Card

    private func channelListRow(_ channel: XtreamLiveStream) -> some View {
        let nowEPG = appState.currentEPGProgram(for: channel.streamId.value)
        let isFav = appState.isFavoriteLive(channel.streamId.value)

        return HStack(spacing: 12) {
            Button {
                appState.startPlayback(.fromLive(channel, subtitle: nowEPG?.title))
            } label: {
                HStack(spacing: 12) {
                    ArtworkImageView(
                        urlString: channel.streamIcon,
                        fallbackTitle: channel.cleanName,
                        fallbackIcon: "tv",
                        contentMode: .fit
                    )
                    .padding(6)
                    .frame(width: 58, height: 58)
                    .background(Color.black.opacity(0.4))
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(.white.opacity(0.1), lineWidth: 0.6)
                    )

                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 6) {
                            if let prefix = channel.prefixBadge {
                                Text(prefix)
                                    .font(.system(size: 9, weight: .heavy, design: .rounded))
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 2)
                                    .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 4))
                                    .foregroundStyle(.white.opacity(0.75))
                            }

                            ForEach(channel.qualityBadges, id: \.self) { badge in
                                QualityBadgeView(text: badge)
                            }

                            if channel.tvArchive?.value == 1 {
                                QualityBadgeView(text: "CATCHUP")
                            }
                        }

                        Text(channel.cleanName)
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .lineLimit(1)

                        if let nowEPG {
                            Text(nowEPG.title)
                                .font(.caption)
                                .foregroundStyle(AppTheme.primaryRed)
                                .lineLimit(1)
                        } else {
                            Text("Live Stream • Tap to Play")
                                .font(.caption2)
                                .foregroundStyle(.white.opacity(0.45))
                        }
                    }

                    Spacer()
                }
            }
            .buttonStyle(.plain)

            Button {
                selectedEPGChannel = channel
            } label: {
                Image(systemName: "list.bullet.rectangle")
                    .font(.caption.bold())
                    .foregroundStyle(.white.opacity(0.8))
                    .frame(width: 34, height: 34)
                    .background(.white.opacity(0.08), in: Circle())
            }

            Button {
                appState.toggleFavoriteLive(channel)
            } label: {
                Image(systemName: isFav ? "star.fill" : "star")
                    .font(.subheadline)
                    .foregroundStyle(isFav ? AppTheme.gold : .white.opacity(0.4))
                    .frame(width: 34, height: 34)
            }
        }
        .padding(12)
        .obsidianGlassCard(cornerRadius: 18)
    }

    private func channelGridCard(_ channel: XtreamLiveStream) -> some View {
        let isFav = appState.isFavoriteLive(channel.streamId.value)
        return Button {
            appState.startPlayback(.fromLive(channel))
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                ZStack(alignment: .topTrailing) {
                    ArtworkImageView(
                        urlString: channel.streamIcon,
                        fallbackTitle: channel.cleanName,
                        fallbackIcon: "tv",
                        contentMode: .fit
                    )
                    .padding(14)
                    .frame(maxWidth: .infinity)
                    .frame(height: 92)
                    .background(Color.black.opacity(0.4))
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                    Button {
                        appState.toggleFavoriteLive(channel)
                    } label: {
                        Image(systemName: isFav ? "star.fill" : "star")
                            .font(.caption)
                            .foregroundStyle(isFav ? AppTheme.gold : .white.opacity(0.5))
                            .padding(8)
                    }
                }

                Text(channel.cleanName)
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                HStack(spacing: 4) {
                    LivePulseBadge()
                    ForEach(channel.qualityBadges.prefix(2), id: \.self) { b in
                        QualityBadgeView(text: b)
                    }
                }
            }
            .padding(10)
            .obsidianGlassCard(cornerRadius: 16)
        }
        .buttonStyle(.plain)
    }
}
