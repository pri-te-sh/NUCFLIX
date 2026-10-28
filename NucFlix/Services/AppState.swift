import Foundation
import SwiftUI
import UIKit

enum StreamQualityPreference: String, Codable, CaseIterable, Identifiable {
    case autoMax = "auto_max"
    case fullHD1080p = "1080p"
    case hd720pSaver = "720p"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .autoMax: return "Auto (4K UHD / Maximum Bitrate)"
        case .fullHD1080p: return "Full HD (1080p Preferred)"
        case .hd720pSaver: return "HD Data Saver (720p)"
        }
    }

    var shortLabel: String {
        switch self {
        case .autoMax: return "4K / Max"
        case .fullHD1080p: return "1080p HD"
        case .hd720pSaver: return "720p Saver"
        }
    }
}

struct CatalogSearchIndex: Sendable {
    let normalizedTitles: [String]
    let prefixMap3: [String: [Int]]
    let prefixMap2: [String: [Int]]

    init(
        normalizedTitles: [String] = [],
        prefixMap3: [String: [Int]] = [:],
        prefixMap2: [String: [Int]] = [:]
    ) {
        self.normalizedTitles = normalizedTitles
        self.prefixMap3 = prefixMap3
        self.prefixMap2 = prefixMap2
    }

    static func build(from rawNames: [String]) -> CatalogSearchIndex {
        var normalized: [String] = []
        normalized.reserveCapacity(rawNames.count)
        var map3: [String: [Int]] = [:]
        var map2: [String: [Int]] = [:]

        for (idx, raw) in rawNames.enumerated() {
            let norm = AppState.fastNormalize(raw)
            normalized.append(norm)

            var seen3 = Set<Substring>()
            var seen2 = Set<Substring>()
            for word in norm.split(separator: " ") {
                if word.utf8.count >= 3 {
                    let p3 = word.prefix(3)
                    if seen3.insert(p3).inserted {
                        map3[String(p3), default: []].append(idx)
                    }
                }
                if word.utf8.count >= 2 {
                    let p2 = word.prefix(2)
                    if seen2.insert(p2).inserted {
                        map2[String(p2), default: []].append(idx)
                    }
                }
            }
        }
        return CatalogSearchIndex(normalizedTitles: normalized, prefixMap3: map3, prefixMap2: map2)
    }

    func matchingIndices(for tokens: [String], limit: Int) -> [Int] {
        guard !tokens.isEmpty, !normalizedTitles.isEmpty else { return [] }

        // Find the smallest candidate posting list from word prefixes
        var bestPostingList: [Int]? = nil
        for token in tokens {
            let count = token.utf8.count
            let list: [Int]?
            if count >= 3 {
                list = prefixMap3[String(token.prefix(3))]
            } else if count == 2 {
                list = prefixMap2[token]
            } else {
                list = nil
            }
            if let list = list {
                if bestPostingList == nil || list.count < bestPostingList!.count {
                    bestPostingList = list
                }
            }
        }

        var results: [Int] = []
        results.reserveCapacity(min(limit, 128))
        var matchedSet = Set<Int>()

        if let candidates = bestPostingList {
            for idx in candidates {
                let title = normalizedTitles[idx]
                if tokens.allSatisfy({ title.contains($0) }) {
                    results.append(idx)
                    matchedSet.insert(idx)
                    if results.count >= limit {
                        return results
                    }
                }
            }
        }

        // If word-prefix hits already filled a healthy result set, return immediately (< 0.05ms)
        if results.count >= min(limit, 30) {
            return results
        }

        // Fallback pass over pre-normalized strings for mid-word substring queries (zero allocations)
        for (idx, title) in normalizedTitles.enumerated() {
            if !matchedSet.contains(idx) && tokens.allSatisfy({ title.contains($0) }) {
                results.append(idx)
                if results.count >= limit {
                    break
                }
            }
        }

        return results
    }
}

@MainActor
@Observable
final class AppState {
    // MARK: - Auth & Session State
    var credentials: XtreamCredentials?
    /// The person profile and Xtream line this session is for (see `activate(line:profile:uid:)`).
    private(set) var activeProfileID: String?
    private(set) var activeLineID: String?
    private(set) var isKidsProfile = false
    @ObservationIgnored private(set) var cloudSync: CloudSync?
    /// Recommendation signals are kept per person.
    private var tasteProfileID: String? { activeProfileID }
    var userInfo: XtreamUserInfo?
    var serverInfo: XtreamServerInfo?
    var isAuthenticating: Bool = false
    var authError: String?

    // MARK: - Categories
    /// Visible categories (adult categories removed unless NSFW content is enabled)
    private(set) var liveCategories: [XtreamCategory] = []
    private(set) var vodCategories: [XtreamCategory] = []
    private(set) var seriesCategories: [XtreamCategory] = []

    // MARK: - NSFW / Adult Content Filter
    /// Off by default. When off, adult categories, titles, search results and recommendations are hidden.
    var showAdultContent: Bool = false {
        didSet {
            guard oldValue != showAdultContent else { return }
            UserDefaults.standard.set(showAdultContent, forKey: Keys.showAdultContent)
            applyContentFilter()
        }
    }
    @ObservationIgnored private var rawLiveCategories: [XtreamCategory] = []
    @ObservationIgnored private var rawVodCategories: [XtreamCategory] = []
    @ObservationIgnored private var rawSeriesCategories: [XtreamCategory] = []
    @ObservationIgnored private var adultLiveCategoryIDs = Set<String>()
    @ObservationIgnored private var adultVodCategoryIDs = Set<String>()
    @ObservationIgnored private var adultSeriesCategoryIDs = Set<String>()
    /// Categories hidden by the AI tags (SmartAI): adult ones, and for kids profiles everything not judged
    /// suitable for young children.
    @ObservationIgnored private var aiHiddenLiveCategoryIDs = Set<String>()
    @ObservationIgnored private var aiHiddenVodCategoryIDs = Set<String>()
    @ObservationIgnored private var aiHiddenSeriesCategoryIDs = Set<String>()
    @ObservationIgnored private var smartTagsTask: Task<Void, Never>?
    @ObservationIgnored private var adultLiveStreamIDs = Set<Int>()
    @ObservationIgnored private var adultMovieIDs = Set<Int>()

    // MARK: - Selected Category & Per-Category Stream Caches
    var selectedLiveCategoryID: String = ""
    var liveStreamsByCategory: [String: [XtreamLiveStream]] = [:]
    var isLoadingLive: Bool = false

    var selectedVODCategoryID: String = ""
    var vodStreamsByCategory: [String: [XtreamVODStream]] = [:]
    var isLoadingVOD: Bool = false

    var selectedSeriesCategoryID: String = ""
    var seriesByCategory: [String: [XtreamSeries]] = [:]
    var isLoadingSeries: Bool = false

    // MARK: - Full Server Catalog Index (All 81,000+ Live, Movies & Series for Instant Global Search)
    private(set) var allLiveCatalog: [XtreamLiveStream] = []
    private(set) var allMoviesCatalog: [XtreamVODStream] = []
    private(set) var allSeriesCatalog: [XtreamSeries] = []
    private(set) var isIndexingFullCatalog: Bool = false
    private(set) var lastCatalogSyncDate: Date? = nil

    // Pre-Computed Inverted Token Indexes & Memoized Search Caches (Sub-Millisecond Search)
    @ObservationIgnored private var moviesSearchIndex = CatalogSearchIndex()
    @ObservationIgnored private var seriesSearchIndex = CatalogSearchIndex()
    @ObservationIgnored private var liveSearchIndex = CatalogSearchIndex()

    @ObservationIgnored private var lastMovieQueryKey: String = ""
    @ObservationIgnored private var lastMovieSearchResults: [XtreamVODStream] = []
    @ObservationIgnored private var lastSeriesQueryKey: String = ""
    @ObservationIgnored private var lastSeriesSearchResults: [XtreamSeries] = []
    @ObservationIgnored private var lastLiveQueryKey: String = ""
    @ObservationIgnored private var lastLiveSearchResults: [XtreamLiveStream] = []

    // MARK: - Curated Home Rails
    var spotlightSeries: [XtreamSeries] = []
    var featuredLiveChannels: [XtreamLiveStream] = []
    var featuredMovies: [XtreamVODStream] = []
    var featuredSeries: [XtreamSeries] = []

    // MARK: - EPG Cache (streamId -> [XtreamEPGItem])
    var epgCache: [Int: [XtreamEPGItem]] = [:]
    @ObservationIgnored private var epgInFlight: Set<Int> = []

    // MARK: - Favorites & Watch History
    var favoriteLiveChannels: [XtreamLiveStream] = [] {
        didSet { favoriteLiveIDs = Set(favoriteLiveChannels.map { $0.streamId.value }) }
    }
    var favoriteMovies: [XtreamVODStream] = [] {
        didSet { favoriteMovieIDs = Set(favoriteMovies.map { $0.streamId.value }) }
    }
    var favoriteSeries: [XtreamSeries] = [] {
        didSet { favoriteSeriesIDs = Set(favoriteSeries.map { $0.seriesId.value }) }
    }
    // O(1) favorite lookups for per-cell checks
    @ObservationIgnored private var favoriteLiveIDs: Set<Int> = []
    @ObservationIgnored private var favoriteMovieIDs: Set<Int> = []
    @ObservationIgnored private var favoriteSeriesIDs: Set<Int> = []

    // O(1) quality-variant lookup maps (built off-main alongside the search index)
    @ObservationIgnored private var movieIndicesByTMDB: [String: [Int]] = [:]
    @ObservationIgnored private var movieIndicesByTitle: [String: [Int]] = [:]
    @ObservationIgnored private var seriesPositionByID: [Int: Int] = [:]
    @ObservationIgnored private var catalogPreloadTask: Task<Void, Never>?
    @ObservationIgnored private var moviePositionByID: [Int: Int] = [:]

    // MARK: - Personalization (on-device recommendation engine)
    /// Personalized hero carousel + rails for the Home screen
    private(set) var homeFeed = HomeFeed()
    @ObservationIgnored private var tasteEvents: [TasteEvent] = []
    @ObservationIgnored private var watchedMostRecorded = Set<String>()
    @ObservationIgnored private var feedRebuildTask: Task<Void, Never>?
    @ObservationIgnored private var feedRefreshSeed = 0
    @ObservationIgnored private var seriesInfoCache: [Int: XtreamSeriesInfoResponse] = [:]

    /// Netflix-style "Autoplay next episode" preference (on by default)
    var autoplayNextEpisode: Bool = true {
        didSet {
            UserDefaults.standard.set(autoplayNextEpisode, forKey: Keys.autoplayNextEpisode)
            if oldValue != autoplayNextEpisode { cloudSync?.saveAutoplay(autoplayNextEpisode) }
        }
    }

    /// O(1) series lookup once the full catalog is indexed (falls back to loaded categories)
    func seriesByID(_ seriesID: Int) -> XtreamSeries? {
        if let pos = seriesPositionByID[seriesID], pos < allSeriesCatalog.count {
            return allSeriesCatalog[pos]
        }
        for list in seriesByCategory.values {
            if let match = list.first(where: { $0.seriesId.value == seriesID }) {
                return match
            }
        }
        return nil
    }
    var watchHistory: [WatchHistoryEntry] = []

    // MARK: - Player & Preferences
    var activePlayback: PlaybackItem?
    var preferredLiveFormat: LiveStreamFormat = .hlsLive {
        didSet {
            UserDefaults.standard.set(preferredLiveFormat.rawValue, forKey: Keys.preferredLiveFormat)
        }
    }
    var preferredStreamQuality: StreamQualityPreference = .autoMax {
        didSet {
            UserDefaults.standard.set(preferredStreamQuality.rawValue, forKey: Keys.preferredStreamQuality)
        }
    }
    var hardwareAccelerationEnabled: Bool = true {
        didSet {
            UserDefaults.standard.set(hardwareAccelerationEnabled, forKey: Keys.hardwareAcceleration)
        }
    }

    @ObservationIgnored private let api = XtreamAPIService.shared

    private enum Keys {
        static let preferredLiveFormat = "xtream.preferredLiveFormat.v2"
        static let preferredStreamQuality = "xtream.preferredStreamQuality.v1"
        static let hardwareAcceleration = "xtream.hardwareAcceleration.v1"
        static let showAdultContent = "nucflix.showAdultContent.v1"
        static let autoplayNextEpisode = "nucflix.autoplayNextEpisode.v1"
    }

    init() {
        if let rawFormat = UserDefaults.standard.string(forKey: Keys.preferredLiveFormat),
           let format = LiveStreamFormat(rawValue: rawFormat) {
            self.preferredLiveFormat = format
        }
        if let rawStreamQual = UserDefaults.standard.string(forKey: Keys.preferredStreamQuality),
           let streamQual = StreamQualityPreference(rawValue: rawStreamQual) {
            self.preferredStreamQuality = streamQual
        }
        if UserDefaults.standard.object(forKey: Keys.hardwareAcceleration) != nil {
            self.hardwareAccelerationEnabled = UserDefaults.standard.bool(forKey: Keys.hardwareAcceleration)
        }
        self.showAdultContent = UserDefaults.standard.bool(forKey: Keys.showAdultContent)
        if UserDefaults.standard.object(forKey: Keys.autoplayNextEpisode) != nil {
            self.autoplayNextEpisode = UserDefaults.standard.bool(forKey: Keys.autoplayNextEpisode)
        }
        // Automatically refresh catalog in the background when returning to the app after >= 30 minutes
        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                await self.autoRefreshIfStale()
            }
        }
    }

    /// Automatically refreshes the catalog if more than 30 minutes have elapsed since the last sync
    func autoRefreshIfStale(maxAgeSeconds: TimeInterval = 1800) async {
        guard credentials != nil, !isAuthenticating, !isIndexingFullCatalog else { return }
        if let lastSync = lastCatalogSyncDate, Date().timeIntervalSince(lastSync) < maxAgeSeconds {
            return
        }
        await refreshAllCatalogs(force: true)
    }

    // MARK: - Computed All Loaded Items (for instant Search & Favorites)

    var allLoadedLiveStreams: [XtreamLiveStream] {
        if !allLiveCatalog.isEmpty {
            return allLiveCatalog
        }
        var seen = Set<Int>()
        var result: [XtreamLiveStream] = []
        for list in liveStreamsByCategory.values {
            for item in list where !item.isSectionDivider {
                if seen.insert(item.streamId.value).inserted {
                    result.append(item)
                }
            }
        }
        return result
    }

    var allLoadedMovies: [XtreamVODStream] {
        if !allMoviesCatalog.isEmpty {
            return allMoviesCatalog
        }
        var seen = Set<Int>()
        var result: [XtreamVODStream] = []
        for list in vodStreamsByCategory.values {
            for item in list {
                if seen.insert(item.streamId.value).inserted {
                    result.append(item)
                }
            }
        }
        return result
    }

    var allLoadedSeries: [XtreamSeries] {
        if !allSeriesCatalog.isEmpty {
            return allSeriesCatalog
        }
        var seen = Set<Int>()
        var result: [XtreamSeries] = []
        for list in seriesByCategory.values {
            for item in list {
                if seen.insert(item.seriesId.value).inserted {
                    result.append(item)
                }
            }
        }
        return result
    }

    // MARK: - Sub-Millisecond Inverted-Index & Single-Pass Full-Catalog Search

    nonisolated static func fastNormalize(_ text: String) -> String {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(text.utf8.count)
        var lastWasSpace = true
        for scalar in text.unicodeScalars {
            let v = scalar.value
            if v >= 65 && v <= 90 { // A-Z -> a-z
                bytes.append(UInt8(v + 32))
                lastWasSpace = false
            } else if (v >= 97 && v <= 122) || (v >= 48 && v <= 57) { // a-z, 0-9
                bytes.append(UInt8(v))
                lastWasSpace = false
            } else if v == 39 || v == 8217 { // ' or ’ -> strip
                continue
            } else if v < 128 { // ASCII punctuation/whitespace -> single space
                if !lastWasSpace {
                    bytes.append(32)
                    lastWasSpace = true
                }
            } else {
                for b in String(scalar).lowercased().utf8 {
                    bytes.append(b)
                }
                lastWasSpace = false
            }
        }
        if lastWasSpace && !bytes.isEmpty {
            bytes.removeLast()
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    nonisolated static func tokenizeQuery(_ rawQuery: String) -> [String] {
        let normalized = fastNormalize(rawQuery)
        guard !normalized.isEmpty else { return [] }
        return normalized.split(separator: " ").map(String.init)
    }

    func searchMovies(query: String, prioritizeCategoryID: String? = nil, limit: Int = 150) -> [XtreamVODStream] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let pool = allLoadedMovies
        let cacheKey = "\(trimmed.lowercased())|\(prioritizeCategoryID ?? "")|\(limit)|\(pool.count)|\(showAdultContent)"
        if cacheKey == lastMovieQueryKey {
            return lastMovieSearchResults
        }

        let tokens = Self.tokenizeQuery(trimmed)
        guard !tokens.isEmpty else { return [] }

        var exactCleanMatches: [XtreamVODStream] = []
        var priorityMatches: [XtreamVODStream] = []
        var otherMatches: [XtreamVODStream] = []
        let normalizedQuery = tokens.joined(separator: " ")

        let candidateIndices: [Int]
        if moviesSearchIndex.normalizedTitles.count == pool.count {
            candidateIndices = moviesSearchIndex.matchingIndices(for: tokens, limit: limit * 3)
        } else {
            var fallback: [Int] = []
            for (idx, movie) in pool.enumerated() {
                let norm = Self.fastNormalize(movie.name)
                if tokens.allSatisfy({ norm.contains($0) }) {
                    fallback.append(idx)
                    if fallback.count >= limit * 2 { break }
                }
            }
            candidateIndices = fallback
        }

        for idx in candidateIndices {
            let movie = pool[idx]
            if !showAdultContent && isAdultContent(movie) { continue }
            let normTitle = (idx < moviesSearchIndex.normalizedTitles.count)
                ? moviesSearchIndex.normalizedTitles[idx]
                : Self.fastNormalize(movie.name)

            if normTitle == normalizedQuery || normTitle.hasPrefix(normalizedQuery) || normTitle.contains(" \(normalizedQuery)") {
                exactCleanMatches.append(movie)
            } else if let catID = prioritizeCategoryID, movie.categoryId?.value == catID {
                priorityMatches.append(movie)
            } else {
                otherMatches.append(movie)
            }
            if exactCleanMatches.count + priorityMatches.count + otherMatches.count >= limit * 2 {
                break
            }
        }

        let results = Array((exactCleanMatches + priorityMatches + otherMatches).prefix(limit))
        lastMovieQueryKey = cacheKey
        lastMovieSearchResults = results
        return results
    }

    func searchSeries(query: String, prioritizeCategoryID: String? = nil, limit: Int = 150) -> [XtreamSeries] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let pool = allLoadedSeries
        let cacheKey = "\(trimmed.lowercased())|\(prioritizeCategoryID ?? "")|\(limit)|\(pool.count)|\(showAdultContent)"
        if cacheKey == lastSeriesQueryKey {
            return lastSeriesSearchResults
        }

        let tokens = Self.tokenizeQuery(trimmed)
        guard !tokens.isEmpty else { return [] }

        var exactCleanMatches: [XtreamSeries] = []
        var priorityMatches: [XtreamSeries] = []
        var otherMatches: [XtreamSeries] = []
        let normalizedQuery = tokens.joined(separator: " ")

        let candidateIndices: [Int]
        if seriesSearchIndex.normalizedTitles.count == pool.count {
            candidateIndices = seriesSearchIndex.matchingIndices(for: tokens, limit: limit * 3)
        } else {
            var fallback: [Int] = []
            for (idx, series) in pool.enumerated() {
                let norm = Self.fastNormalize(series.name)
                if tokens.allSatisfy({ norm.contains($0) }) {
                    fallback.append(idx)
                    if fallback.count >= limit * 2 { break }
                }
            }
            candidateIndices = fallback
        }

        for idx in candidateIndices {
            let series = pool[idx]
            if !showAdultContent && isAdultContent(series) { continue }
            let normTitle = (idx < seriesSearchIndex.normalizedTitles.count)
                ? seriesSearchIndex.normalizedTitles[idx]
                : Self.fastNormalize(series.name)

            if normTitle == normalizedQuery || normTitle.hasPrefix(normalizedQuery) || normTitle.contains(" \(normalizedQuery)") {
                exactCleanMatches.append(series)
            } else if let catID = prioritizeCategoryID, series.categoryId?.value == catID {
                priorityMatches.append(series)
            } else {
                otherMatches.append(series)
            }
            if exactCleanMatches.count + priorityMatches.count + otherMatches.count >= limit * 2 {
                break
            }
        }

        let results = Array((exactCleanMatches + priorityMatches + otherMatches).prefix(limit))
        lastSeriesQueryKey = cacheKey
        lastSeriesSearchResults = results
        return results
    }

    func searchLiveStreams(query: String, prioritizeCategoryID: String? = nil, limit: Int = 150) -> [XtreamLiveStream] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let pool = allLoadedLiveStreams
        let cacheKey = "\(trimmed.lowercased())|\(prioritizeCategoryID ?? "")|\(limit)|\(pool.count)|\(showAdultContent)"
        if cacheKey == lastLiveQueryKey {
            return lastLiveSearchResults
        }

        let tokens = Self.tokenizeQuery(trimmed)
        guard !tokens.isEmpty else { return [] }

        var priorityMatches: [XtreamLiveStream] = []
        var otherMatches: [XtreamLiveStream] = []

        let candidateIndices: [Int]
        if liveSearchIndex.normalizedTitles.count == pool.count {
            candidateIndices = liveSearchIndex.matchingIndices(for: tokens, limit: limit * 2)
        } else {
            var fallback: [Int] = []
            for (idx, channel) in pool.enumerated() where !channel.isSectionDivider {
                let norm = Self.fastNormalize(channel.name)
                if tokens.allSatisfy({ norm.contains($0) }) {
                    fallback.append(idx)
                    if fallback.count >= limit { break }
                }
            }
            candidateIndices = fallback
        }

        for idx in candidateIndices {
            let channel = pool[idx]
            guard !channel.isSectionDivider else { continue }
            if !showAdultContent && isAdultContent(channel) { continue }
            if let catID = prioritizeCategoryID, channel.categoryId?.value == catID {
                priorityMatches.append(channel)
            } else {
                otherMatches.append(channel)
            }
            if priorityMatches.count + otherMatches.count >= limit {
                break
            }
        }

        let results = Array((priorityMatches + otherMatches).prefix(limit))
        lastLiveQueryKey = cacheKey
        lastLiveSearchResults = results
        return results
    }

    // MARK: - Line sign-in

    private func signIn(with creds: XtreamCredentials) async {
        isAuthenticating = true
        authError = nil

        do {
            // Resolves HTTPS → HTTP automatically for panels without TLS, and hands back
            // the credentials that actually worked so the scheme is persisted for streams.
            let (authResponse, workingCredentials) = try await api.authenticateResolvingScheme(credentials: creds)
            self.credentials = workingCredentials
            DownloadManager.shared.lineCredentials = workingCredentials
            DownloadManager.shared.lineMaxConnections = authResponse.userInfo?.maxConnections.flatMap { Int($0.value) }
            self.userInfo = authResponse.userInfo
            self.serverInfo = authResponse.serverInfo

            NotificationManager.shared.recordAccountStatus(
                lineName: workingCredentials.lineName,
                status: authResponse.userInfo?.status ?? "Active",
                countdownText: authResponse.userInfo?.expirationCountdownText ?? "Unlimited",
                activeCons: authResponse.userInfo?.activeCons?.value ?? "0",
                maxCons: authResponse.userInfo?.maxConnections?.value ?? "1"
            )

            isAuthenticating = false
            await refreshAllCatalogs()
        } catch {
            isAuthenticating = false
            self.authError = error.localizedDescription
        }
    }

    func signOut() {
        credentials = nil
        DownloadManager.shared.lineCredentials = nil
        DownloadManager.shared.lineMaxConnections = nil
        userInfo = nil
        serverInfo = nil
        liveCategories = []
        vodCategories = []
        seriesCategories = []
        rawLiveCategories = []
        rawVodCategories = []
        rawSeriesCategories = []
        adultLiveCategoryIDs = []
        adultVodCategoryIDs = []
        adultSeriesCategoryIDs = []
        aiHiddenLiveCategoryIDs = []
        aiHiddenVodCategoryIDs = []
        aiHiddenSeriesCategoryIDs = []
        smartTagsTask?.cancel()
        SmartAI.shared.stopTags()
        SmartAI.shared.reset()
        adultLiveStreamIDs = []
        adultMovieIDs = []
        liveStreamsByCategory = [:]
        vodStreamsByCategory = [:]
        seriesByCategory = [:]
        allLiveCatalog = []
        allMoviesCatalog = []
        allSeriesCatalog = []
        moviesSearchIndex = CatalogSearchIndex()
        seriesSearchIndex = CatalogSearchIndex()
        liveSearchIndex = CatalogSearchIndex()
        catalogPreloadTask?.cancel()
        catalogPreloadTask = nil
        movieIndicesByTMDB = [:]
        movieIndicesByTitle = [:]
        seriesPositionByID = [:]
        moviePositionByID = [:]
        feedRebuildTask?.cancel()
        homeFeed = HomeFeed()
        tasteEvents = []
        watchedMostRecorded = []
        lastMovieQueryKey = ""
        lastMovieSearchResults = []
        lastSeriesQueryKey = ""
        lastSeriesSearchResults = []
        lastLiveQueryKey = ""
        lastLiveSearchResults = []
        isIndexingFullCatalog = false
        spotlightSeries = []
        featuredLiveChannels = []
        featuredMovies = []
        featuredSeries = []
        epgCache = [:]
        activePlayback = nil
        cloudSync?.stop()
        cloudSync = nil
        activeProfileID = nil
        activeLineID = nil
        isKidsProfile = false
        favoriteLiveChannels = []
        favoriteMovies = []
        favoriteSeries = []
        watchHistory = []
    }

    // MARK: - Cloud session (person profile + Xtream line from Firebase)

    /// Starts (or switches) the session for a person profile watching through an Xtream line. The line's
    /// login is only held in memory; favorites and watch progress come live from Firestore.
    func activate(line: CloudLine, profile: CloudProfile, uid: String) async {
        let lineCreds = line.credentials
        let sameLine = activeLineID == line.id && credentials?.username == lineCreds.username
            && credentials?.password == lineCreds.password && credentials?.normalizedBaseURL == lineCreds.normalizedBaseURL
        if sameLine && activeProfileID == profile.id && userInfo != nil { return }

        if !sameLine { signOut() }
        cloudSync?.stop()
        activeProfileID = profile.id
        activeLineID = line.id
        isKidsProfile = profile.kids
        applySmartTags(immediately: true)
        resetUserData()
        autoplayNextEpisode = profile.autoplayNext
        if profile.kids { showAdultContent = false }
        let sync = CloudSync(appState: self, uid: uid, profileID: profile.id, lineID: line.id)
        cloudSync = sync
        sync.start()
        if sameLine && userInfo != nil {
            scheduleHomeFeedRebuild(delay: 0)
        } else {
            await signIn(with: line.credentials)
        }
    }

    func applyCloudFavorites(live: [XtreamLiveStream], movies: [XtreamVODStream], series: [XtreamSeries]) {
        favoriteLiveChannels = live
        favoriteMovies = movies
        favoriteSeries = series
    }

    func applyCloudHistory(_ entries: [WatchHistoryEntry]) {
        watchHistory = Array(entries.prefix(50))
        scheduleHomeFeedRebuild(delay: 2)
    }

    // MARK: - Fast Category-Driven Catalog Loading

    func refreshAllCatalogs(force: Bool = false) async {
        guard let creds = credentials else { return }
        isLoadingLive = true
        isLoadingVOD = true
        isLoadingSeries = true

        async let lCats = api.fetchLiveCategories(credentials: creds)
        async let vCats = api.fetchVODCategories(credentials: creds)
        async let sCats = api.fetchSeriesCategories(credentials: creds)

        let (loadedLiveCats, loadedVodCats, loadedSeriesCats) = await (
            (try? lCats) ?? [],
            (try? vCats) ?? [],
            (try? sCats) ?? []
        )

        self.rawLiveCategories = loadedLiveCats
        self.rawVodCategories = loadedVodCats
        self.rawSeriesCategories = loadedSeriesCats
        self.adultLiveCategoryIDs = Set(loadedLiveCats.filter { Self.isAdultCategoryName($0.categoryName) }.map(\.id))
        self.adultVodCategoryIDs = Set(loadedVodCats.filter { Self.isAdultCategoryName($0.categoryName) }.map(\.id))
        self.adultSeriesCategoryIDs = Set(loadedSeriesCats.filter { Self.isAdultCategoryName($0.categoryName) }.map(\.id))
        startSmartTags()
        applyVisibleCategories()

        if selectedLiveCategoryID.isEmpty, let first = self.liveCategories.first {
            selectedLiveCategoryID = first.id
        }
        if selectedVODCategoryID.isEmpty, let first = self.vodCategories.first {
            selectedVODCategoryID = first.id
        }
        // Prefer Netflix / Apple / Trending series category for initial Spotlight if present
        let preferredSeriesCat = self.seriesCategories.first(where: {
            $0.categoryName.localizedCaseInsensitiveContains("NETFLIX") ||
            $0.categoryName.localizedCaseInsensitiveContains("APPLE") ||
            $0.categoryName.localizedCaseInsensitiveContains("ENGLISH")
        }) ?? self.seriesCategories.first

        if selectedSeriesCategoryID.isEmpty, let first = preferredSeriesCat {
            selectedSeriesCategoryID = first.id
        }

        // Load initial categories concurrently (takes < 0.5s total!)
        await withTaskGroup(of: Void.self) { group in
            for cat in self.liveCategories.prefix(3) {
                group.addTask { await self.loadLiveCategory(id: cat.id, force: force) }
            }
            for cat in self.vodCategories.prefix(2) {
                group.addTask { await self.loadVODCategory(id: cat.id, force: force) }
            }
            if let sCat = preferredSeriesCat {
                group.addTask { await self.loadSeriesCategory(id: sCat.id, force: force) }
            }
            for cat in self.seriesCategories.prefix(2) where cat.id != preferredSeriesCat?.id {
                group.addTask { await self.loadSeriesCategory(id: cat.id, force: force) }
            }
        }

        rebuildFeaturedHomeRails(preferredSeriesCatID: preferredSeriesCat?.id)
        scheduleHomeFeedRebuild(delay: 0, reshuffle: force)
        isLoadingLive = false
        isLoadingVOD = false
        isLoadingSeries = false
        lastCatalogSyncDate = Date()

        // Immediately index all 81,000+ Movies, Series, and Live Channels in the background for global search
        catalogPreloadTask?.cancel()
        catalogPreloadTask = Task {
            await preloadFullCatalogInBackground()
        }
    }

    func preloadFullCatalogInBackground() async {
        guard let creds = credentials, !isIndexingFullCatalog else { return }
        isIndexingFullCatalog = true
        defer { isIndexingFullCatalog = false }

        async let fullMoviesTask = api.fetchVODStreams(credentials: creds, categoryId: nil)
        async let fullSeriesTask = api.fetchSeries(credentials: creds, categoryId: nil)
        async let fullLiveTask = api.fetchLiveStreams(credentials: creds, categoryId: nil)

        // Each section is grouped + indexed off the main thread, then committed with a single
        // observable assignment (instead of one publish + full dictionary copy per category).
        if let fullMovies = try? await fullMoviesTask, !fullMovies.isEmpty {
            let built = await Task.detached(priority: .userInitiated) { () -> ([String: [XtreamVODStream]], CatalogSearchIndex, [String: [Int]], [String: [Int]], [Int: Int]) in
                let grouped = Dictionary(grouping: fullMovies) { $0.categoryId?.value ?? "" }
                let index = CatalogSearchIndex.build(from: fullMovies.map(\.name))
                var byTMDB: [String: [Int]] = [:]
                var byTitle: [String: [Int]] = [:]
                var positions: [Int: Int] = [:]
                positions.reserveCapacity(fullMovies.count)
                for (idx, movie) in fullMovies.enumerated() {
                    let tmdb = movie.tmdb?.value.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    if !tmdb.isEmpty && tmdb != "0" {
                        byTMDB[tmdb, default: []].append(idx)
                    }
                    byTitle[movie.cleanName.lowercased(), default: []].append(idx)
                    if positions[movie.streamId.value] == nil { positions[movie.streamId.value] = idx }
                }
                return (grouped, index, byTMDB, byTitle, positions)
            }.value
            guard !Task.isCancelled, credentials?.id == creds.id else { return }
            self.allMoviesCatalog = fullMovies
            self.moviesSearchIndex = built.1
            self.movieIndicesByTMDB = built.2
            self.movieIndicesByTitle = built.3
            self.moviePositionByID = built.4
            self.learnAdultFlags(movies: fullMovies)
            self.lastMovieQueryKey = ""
            var merged = self.vodStreamsByCategory
            for (catID, list) in built.0 where !catID.isEmpty {
                merged[catID] = list
            }
            self.vodStreamsByCategory = merged
        }

        if let fullSeries = try? await fullSeriesTask, !fullSeries.isEmpty {
            let (groupedSeries, seriesIndex, positions) = await Task.detached(priority: .userInitiated) {
                let grouped = Dictionary(grouping: fullSeries) { $0.categoryId?.value ?? "" }
                let index = CatalogSearchIndex.build(from: fullSeries.map(\.name))
                var positions: [Int: Int] = [:]
                positions.reserveCapacity(fullSeries.count)
                for (idx, s) in fullSeries.enumerated() where positions[s.seriesId.value] == nil {
                    positions[s.seriesId.value] = idx
                }
                return (grouped, index, positions)
            }.value
            guard !Task.isCancelled, credentials?.id == creds.id else { return }
            self.allSeriesCatalog = fullSeries
            self.seriesSearchIndex = seriesIndex
            self.seriesPositionByID = positions
            self.lastSeriesQueryKey = ""
            var merged = self.seriesByCategory
            for (catID, list) in groupedSeries where !catID.isEmpty {
                merged[catID] = list
            }
            self.seriesByCategory = merged
        }

        if let fullLive = try? await fullLiveTask, !fullLive.isEmpty {
            let (groupedLive, filteredLive, liveIndex) = await Task.detached(priority: .userInitiated) {
                let grouped = Dictionary(grouping: fullLive) { $0.categoryId?.value ?? "" }
                let filtered = fullLive.filter { !$0.isSectionDivider }
                let index = CatalogSearchIndex.build(from: filtered.map(\.name))
                return (grouped, filtered, index)
            }.value
            guard !Task.isCancelled, credentials?.id == creds.id else { return }
            self.allLiveCatalog = filteredLive
            self.learnAdultFlags(live: fullLive)
            self.liveSearchIndex = liveIndex
            self.lastLiveQueryKey = ""
            var merged = self.liveStreamsByCategory
            for (catID, list) in groupedLive where !catID.isEmpty {
                merged[catID] = list
            }
            self.liveStreamsByCategory = merged
        }
        self.lastCatalogSyncDate = Date()
        scheduleHomeFeedRebuild(delay: 0)
        NotificationManager.shared.recordCatalogSynced(
            moviesCount: self.allMoviesCatalog.count,
            seriesCount: self.allSeriesCatalog.count,
            liveCount: self.allLiveCatalog.count,
            artworkURL: self.featuredMovies.first?.streamIcon
        )
    }

    func selectLiveCategory(_ categoryID: String) {
        selectedLiveCategoryID = categoryID
        guard categoryID != "FAV" else { return }
        Task {
            await loadLiveCategory(id: categoryID)
        }
    }

    func loadLiveCategory(id categoryID: String, force: Bool = false) async {
        guard let creds = credentials, !categoryID.isEmpty, categoryID != "FAV" else { return }
        if !force, let cached = liveStreamsByCategory[categoryID], !cached.isEmpty {
            return
        }
        if selectedLiveCategoryID == categoryID {
            isLoadingLive = true
        }
        let streams = (try? await api.fetchLiveStreams(credentials: creds, categoryId: categoryID)) ?? []
        liveStreamsByCategory[categoryID] = streams
        if selectedLiveCategoryID == categoryID {
            isLoadingLive = false
        }
        if featuredLiveChannels.isEmpty {
            featuredLiveChannels = Array(streams.filter { !$0.isSectionDivider }.prefix(20))
        }
    }

    func selectVODCategory(_ categoryID: String) {
        selectedVODCategoryID = categoryID
        guard categoryID != "FAV" else { return }
        Task {
            await loadVODCategory(id: categoryID)
        }
    }

    func loadVODCategory(id categoryID: String, force: Bool = false) async {
        guard let creds = credentials, !categoryID.isEmpty, categoryID != "FAV" else { return }
        if !force, let cached = vodStreamsByCategory[categoryID], !cached.isEmpty {
            return
        }
        if selectedVODCategoryID == categoryID {
            isLoadingVOD = true
        }
        let streams = (try? await api.fetchVODStreams(credentials: creds, categoryId: categoryID)) ?? []
        vodStreamsByCategory[categoryID] = streams
        if selectedVODCategoryID == categoryID {
            isLoadingVOD = false
        }
        if featuredMovies.isEmpty {
            featuredMovies = Array(streams.prefix(20))
        }
    }

    /// Loads paired 4K / HD / HEVC companion categories so alternate resolutions of the same movie are discovered automatically
    func loadCompanionVODCategories(for movie: XtreamVODStream) async {
        let catID = movie.categoryId?.value ?? ""
        let prefix = (movie.prefixBadge ?? "").uppercased()
        var companionIDs: [String] = []

        if ["1652", "1938", "88", "773", "1651", "2125"].contains(catID) || prefix.contains("IN") {
            companionIDs = ["1938", "88", "1652", "773"]
        } else if ["219", "1925", "137", "437"].contains(catID) || prefix.contains("NF") {
            companionIDs = ["219", "137", "437", "1925"]
        } else if ["1007", "440"].contains(catID) || prefix.contains("AMZ") {
            companionIDs = ["1007", "440"]
        } else if ["1069", "325"].contains(catID) || prefix.contains("DSNP") {
            companionIDs = ["1069", "325"]
        } else if ["431", "327"].contains(catID) || prefix.contains("ATVP") {
            companionIDs = ["431", "327"]
        } else if ["1536", "1535"].contains(catID) {
            companionIDs = ["1536", "1535"]
        } else if ["1923", "92"].contains(catID) {
            companionIDs = ["1923", "92"]
        } else if ["217", "163", "275"].contains(catID) || prefix.contains("EN") {
            companionIDs = ["217", "163"]
        }

        for id in companionIDs where vodStreamsByCategory[id] == nil {
            await loadVODCategory(id: id)
        }
    }

    /// Finds all resolution variants (4K, 1080p HD, HEVC) of a movie by TMDB ID or clean title across loaded categories
    func findMatchingQualityVariants(for primaryMovie: XtreamVODStream) -> [XtreamVODStream] {
        let targetName = primaryMovie.cleanName.lowercased()
        let targetTMDB = primaryMovie.tmdb?.value.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var matches: [XtreamVODStream] = [primaryMovie]
        var seenIDs: Set<Int> = [primaryMovie.streamId.value]

        // Fast path: O(1) lookups into maps pre-built off the main thread
        if !movieIndicesByTitle.isEmpty, !allMoviesCatalog.isEmpty {
            var indices: [Int] = movieIndicesByTitle[targetName] ?? []
            if !targetTMDB.isEmpty && targetTMDB != "0" {
                indices.append(contentsOf: movieIndicesByTMDB[targetTMDB] ?? [])
            }
            for idx in indices where idx < allMoviesCatalog.count {
                let candidate = allMoviesCatalog[idx]
                if seenIDs.insert(candidate.streamId.value).inserted {
                    matches.append(candidate)
                }
            }
            return matches
        }

        // Fallback before the full catalog is indexed: scan only the categories loaded so far (cheap TMDB check first)
        for candidate in allLoadedMovies where !seenIDs.contains(candidate.streamId.value) {
            let candTMDB = candidate.tmdb?.value.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let tmdbMatch = !targetTMDB.isEmpty && targetTMDB != "0" && candTMDB == targetTMDB
            if tmdbMatch || candidate.cleanName.lowercased() == targetName {
                seenIDs.insert(candidate.streamId.value)
                matches.append(candidate)
            }
        }
        return matches
    }

    func selectSeriesCategory(_ categoryID: String) {
        selectedSeriesCategoryID = categoryID
        guard categoryID != "FAV" else { return }
        Task {
            await loadSeriesCategory(id: categoryID)
        }
    }

    func loadSeriesCategory(id categoryID: String, force: Bool = false) async {
        guard let creds = credentials, !categoryID.isEmpty, categoryID != "FAV" else { return }
        if !force, let cached = seriesByCategory[categoryID], !cached.isEmpty {
            return
        }
        if selectedSeriesCategoryID == categoryID {
            isLoadingSeries = true
        }
        let list = (try? await api.fetchSeries(credentials: creds, categoryId: categoryID)) ?? []
        seriesByCategory[categoryID] = list
        if selectedSeriesCategoryID == categoryID {
            isLoadingSeries = false
        }
        if featuredSeries.isEmpty {
            featuredSeries = Array(list.prefix(20))
        }
    }

    private func rebuildFeaturedHomeRails(preferredSeriesCatID: String?) {
        var liveRail: [XtreamLiveStream] = []
        for cat in liveCategories.prefix(3) {
            if let items = liveStreamsByCategory[cat.id] {
                liveRail.append(contentsOf: items.filter { !$0.isSectionDivider && (showAdultContent || !isAdultContent($0)) }.prefix(8))
            }
        }
        self.featuredLiveChannels = Array(liveRail.prefix(24))

        var vodRail: [XtreamVODStream] = []
        for cat in vodCategories.prefix(2) {
            if let items = vodStreamsByCategory[cat.id] {
                vodRail.append(contentsOf: items.filter { showAdultContent || !isAdultContent($0) }.prefix(12))
            }
        }
        self.featuredMovies = Array(vodRail.prefix(24))

        if let sID = preferredSeriesCatID, let sItems = seriesByCategory[sID], !sItems.isEmpty, showAdultContent || !(adultSeriesCategoryIDs.contains(sID) || aiHiddenSeriesCategoryIDs.contains(sID)) {
            self.featuredSeries = Array(sItems.prefix(24))
            self.spotlightSeries = Array(sItems.filter { ($0.backdropPath?.values.isEmpty == false) || ($0.cover?.isEmpty == false) }.prefix(6))
        } else {
            let safeSeries = allLoadedSeries.lazy.filter { self.showAdultContent || !self.isAdultContent($0) }
            self.featuredSeries = Array(safeSeries.prefix(24))
            self.spotlightSeries = Array(safeSeries.prefix(6))
        }
    }

    // MARK: - EPG Loading

    func loadEPGIfNeeded(for streamId: Int, force: Bool = false) {
        guard let creds = credentials else { return }
        if !force, epgCache[streamId] != nil || epgInFlight.contains(streamId) {
            return
        }
        epgInFlight.insert(streamId)
        Task {
            let items = (try? await api.fetchShortEPG(credentials: creds, streamId: streamId, limit: 12)) ?? []
            self.epgCache[streamId] = items
            self.epgInFlight.remove(streamId)
        }
    }

    func currentEPGProgram(for streamId: Int) -> XtreamEPGItem? {
        guard let items = epgCache[streamId], !items.isEmpty else { return nil }
        return items.first(where: { $0.isNowPlaying }) ?? items.first
    }

    // MARK: - Favorites Management

    func isFavoriteLive(_ streamId: Int) -> Bool {
        favoriteLiveIDs.contains(streamId)
    }

    func toggleFavoriteLive(_ channel: XtreamLiveStream) {
        if let idx = favoriteLiveChannels.firstIndex(where: { $0.streamId.value == channel.streamId.value }) {
            favoriteLiveChannels.remove(at: idx)
        } else {
            favoriteLiveChannels.insert(channel, at: 0)
        }
        cloudSync?.setFavorite(isFavoriteLive(channel.streamId.value), kind: "live", id: channel.streamId.value,
                               title: channel.name, artwork: channel.streamIcon, categoryId: channel.categoryId?.value)
    }

    func isFavoriteMovie(_ streamId: Int) -> Bool {
        favoriteMovieIDs.contains(streamId)
    }

    func toggleFavoriteMovie(_ movie: XtreamVODStream) {
        if let idx = favoriteMovies.firstIndex(where: { $0.streamId.value == movie.streamId.value }) {
            favoriteMovies.remove(at: idx)
        } else {
            favoriteMovies.insert(movie, at: 0)
            recordTaste(.favorite, movie: movie)
        }
        cloudSync?.setFavorite(isFavoriteMovie(movie.streamId.value), kind: "movie", id: movie.streamId.value, title: movie.name,
                               artwork: movie.streamIcon, ext: movie.containerExtension, categoryId: movie.categoryId?.value)
    }

    func isFavoriteSeries(_ seriesId: Int) -> Bool {
        favoriteSeriesIDs.contains(seriesId)
    }

    func toggleFavoriteSeries(_ series: XtreamSeries) {
        if let idx = favoriteSeries.firstIndex(where: { $0.seriesId.value == series.seriesId.value }) {
            favoriteSeries.remove(at: idx)
        } else {
            favoriteSeries.insert(series, at: 0)
            recordTaste(.favorite, series: series)
        }
        cloudSync?.setFavorite(isFavoriteSeries(series.seriesId.value), kind: "series", id: series.seriesId.value,
                               title: series.name, artwork: series.cover, categoryId: series.categoryId?.value)
    }

    // MARK: - Watch History & Continue Watching

    func startPlayback(_ item: PlaybackItem) {
        var mutableItem = item
        if item.resumeSeconds <= 0,
           item.contentType != .live,
           let existing = watchHistory.first(where: { $0.id == item.id }),
           !existing.isWatched {
            mutableItem.resumeSeconds = existing.positionSeconds
        }
        activePlayback = mutableItem
        recordPlaybackProgress(item: mutableItem, positionSeconds: mutableItem.resumeSeconds, durationSeconds: 0)
        recordTaste(.play, playback: mutableItem)
    }

    func recordPlaybackProgress(item: PlaybackItem, positionSeconds: Double, durationSeconds: Double) {
        let existing = watchHistory.first(where: { $0.id == item.id })
        let resolvedDuration = durationSeconds > 0 ? durationSeconds : (existing?.durationSeconds ?? 0)
        let resolvedPosition = positionSeconds > 0 ? positionSeconds : (existing?.positionSeconds ?? 0)

        let entry = WatchHistoryEntry(
            id: item.id,
            contentType: item.contentType,
            title: item.title,
            subtitle: item.subtitle,
            artworkURL: item.artworkURL,
            streamID: item.streamID,
            episodeID: item.episodeID,
            seriesID: item.seriesID,
            containerExtension: item.containerExtension,
            positionSeconds: resolvedPosition,
            durationSeconds: resolvedDuration,
            lastWatchedAt: Date()
        )

        watchHistory.removeAll { $0.id == item.id }
        watchHistory.insert(entry, at: 0)
        if watchHistory.count > 50 {
            watchHistory = Array(watchHistory.prefix(50))
        }
        cloudSync?.saveProgress(entry)

        if entry.progressFraction >= 0.5, item.contentType != .live,
           watchedMostRecorded.insert(item.id).inserted {
            recordTaste(.watchedMost, playback: item)
        }
    }

    // MARK: - Next Episode (Binge Autoplay)

    /// Cached series info (seasons + episodes) used for next-episode lookups
    func seriesInfo(for seriesID: Int) async -> XtreamSeriesInfoResponse? {
        if let cached = seriesInfoCache[seriesID] { return cached }
        guard let creds = credentials,
              let info = try? await api.fetchSeriesInfo(credentials: creds, seriesId: seriesID),
              !info.episodesBySeason.isEmpty else { return nil }
        seriesInfoCache[seriesID] = info
        return info
    }

    /// Resolves the episode that follows `item` (next in season, else first episode of the next season)
    func nextEpisode(after item: PlaybackItem) async -> PlaybackItem? {
        guard item.contentType == .seriesEpisode,
              let seriesID = item.seriesID,
              let currentEpisodeID = item.episodeID,
              let info = await seriesInfo(for: seriesID) else { return nil }

        let seasons = info.sortedSeasonNumbers
        for (seasonIndex, season) in seasons.enumerated() {
            guard let episodes = info.episodesBySeason[season],
                  let idx = episodes.firstIndex(where: { $0.episodeId.value == currentEpisodeID }) else { continue }
            let next: (episode: XtreamEpisode, season: Int)?
            if idx + 1 < episodes.count {
                next = (episodes[idx + 1], season)
            } else if seasonIndex + 1 < seasons.count,
                      let first = info.episodesBySeason[seasons[seasonIndex + 1]]?.first {
                next = (first, seasons[seasonIndex + 1])
            } else {
                next = nil
            }
            guard let next else { return nil }
            if let series = seriesByID(seriesID) {
                return .fromEpisode(series: series, episode: next.episode, seasonNumber: next.season)
            }
            let itemID = "episode-\(next.episode.episodeId.value)"
            return PlaybackItem(
                id: itemID,
                contentType: .seriesEpisode,
                title: item.title,
                subtitle: "S\(next.season) E\(next.episode.episodeNum.value) • \(next.episode.title)",
                artworkURL: next.episode.info?.movieImage ?? item.artworkURL,
                streamID: nil,
                episodeID: next.episode.episodeId.value,
                containerExtension: next.episode.containerExtension ?? "mp4",
                seriesID: seriesID,
                resumeSeconds: 0,
                localFileURL: DownloadManager.shared.localFileURL(for: itemID)
            )
        }
        return nil
    }

    /// Starts a new episode inside the already-presented player (no dismiss/re-present):
    /// applies saved resume position, records history and taste signals.
    func prepareInPlacePlayback(_ item: PlaybackItem) -> PlaybackItem {
        var mutableItem = item
        if item.resumeSeconds <= 0,
           let existing = watchHistory.first(where: { $0.id == item.id }),
           !existing.isWatched {
            mutableItem.resumeSeconds = existing.positionSeconds
        }
        recordPlaybackProgress(item: mutableItem, positionSeconds: mutableItem.resumeSeconds, durationSeconds: 0)
        recordTaste(.play, playback: mutableItem)
        return mutableItem
    }

    // MARK: - Personalization Signals & Home Feed

    /// Detail page opened (optionally with genres resolved from the info endpoint)
    func recordDetailView(movie: XtreamVODStream, genre: String? = nil) {
        recordTaste(.detailView, movie: movie, genre: genre)
    }

    func recordDetailView(series: XtreamSeries) {
        recordTaste(.detailView, series: series)
    }

    func recordDownload(movie: XtreamVODStream) {
        recordTaste(.download, movie: movie)
    }

    func recordDownload(series: XtreamSeries) {
        recordTaste(.download, series: series)
    }

    private func recordTaste(_ kind: TasteEvent.Kind, movie: XtreamVODStream, genre: String? = nil) {
        appendTaste(TasteEvent(
            kind: kind, content: .movie, itemID: movie.streamId.value, title: movie.name,
            categoryID: movie.categoryId?.value, genres: RecommendationEngine.genres(from: genre), date: Date()
        ))
    }

    private func recordTaste(_ kind: TasteEvent.Kind, series: XtreamSeries) {
        appendTaste(TasteEvent(
            kind: kind, content: .series, itemID: series.seriesId.value, title: series.name,
            categoryID: series.categoryId?.value, genres: RecommendationEngine.genres(from: series.genre), date: Date()
        ))
    }

    private func recordTaste(_ kind: TasteEvent.Kind, playback item: PlaybackItem) {
        switch item.contentType {
        case .movie:
            guard let sid = item.streamID else { return }
            if let movie = movieByID(sid) {
                // Carry over genres learned from an earlier detail view of the same title
                let knownGenres = tasteEvents.last(where: { $0.content == .movie && $0.itemID == sid && !$0.genres.isEmpty })?.genres ?? []
                var event = TasteEvent(kind: kind, content: .movie, itemID: sid, title: movie.name,
                                       categoryID: movie.categoryId?.value, genres: knownGenres, date: Date())
                event.genres = knownGenres
                appendTaste(event)
            } else {
                appendTaste(TasteEvent(kind: kind, content: .movie, itemID: sid, title: item.title,
                                       categoryID: nil, genres: [], date: Date()))
            }
        case .seriesEpisode:
            guard let seriesID = item.seriesID, let series = seriesByID(seriesID) else { return }
            recordTaste(kind, series: series)
        case .live:
            break
        }
    }

    private func appendTaste(_ event: TasteEvent) {
        guard let profileID = tasteProfileID else { return }
        // Collapse rapid duplicate signals (e.g. re-opening the same detail page)
        if let last = tasteEvents.last, last.kind == event.kind, last.itemID == event.itemID,
           event.date.timeIntervalSince(last.date) < 60 {
            return
        }
        tasteEvents.append(event)
        if tasteEvents.count > 400 {
            tasteEvents.removeFirst(tasteEvents.count - 400)
        }
        TasteProfileStore.save(tasteEvents, profileID: profileID)
        // Strong signals refresh the feed soon; browsing signals batch up
        scheduleHomeFeedRebuild(delay: event.kind == .detailView ? 20 : 3)
    }

    func movieByID(_ streamID: Int) -> XtreamVODStream? {
        if let pos = moviePositionByID[streamID], pos < allMoviesCatalog.count {
            return allMoviesCatalog[pos]
        }
        for list in vodStreamsByCategory.values {
            if let match = list.first(where: { $0.streamId.value == streamID }) {
                return match
            }
        }
        return nil
    }

    /// Re-ranks the personalized Home feed off the main thread (debounced)
    func scheduleHomeFeedRebuild(delay: TimeInterval = 0.5, reshuffle: Bool = false) {
        if reshuffle { feedRefreshSeed += 1 }
        feedRebuildTask?.cancel()
        feedRebuildTask = Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            guard let self, !Task.isCancelled else { return }
            await self.rebuildHomeFeedNow()
        }
    }

    private func rebuildHomeFeedNow() async {
        guard let profileID = tasteProfileID else { return }
        let allowAdult = showAdultContent
        let adultVodCats = adultVodCategoryIDs.union(aiHiddenVodCategoryIDs)
        let adultSeriesCats = adultSeriesCategoryIDs.union(aiHiddenSeriesCategoryIDs)
        let adultMovies = adultMovieIDs
        let rawMovies = allMoviesCatalog.isEmpty ? Array(vodStreamsByCategory.values.joined()) : allMoviesCatalog
        let rawSeries = allSeriesCatalog.isEmpty ? Array(seriesByCategory.values.joined()) : allSeriesCatalog
        let (safeMovies, safeSeries, safeMoviesByCat, safeSeriesByCat, safeEvents): ([XtreamVODStream], [XtreamSeries], [String: [XtreamVODStream]], [String: [XtreamSeries]], [TasteEvent])
        if allowAdult {
            (safeMovies, safeSeries, safeMoviesByCat, safeSeriesByCat, safeEvents) = (rawMovies, rawSeries, vodStreamsByCategory, seriesByCategory, tasteEvents)
        } else {
            let movieDicts = vodStreamsByCategory
            let seriesDicts = seriesByCategory
            let events = tasteEvents
            (safeMovies, safeSeries, safeMoviesByCat, safeSeriesByCat, safeEvents) = await Task.detached(priority: .utility) {
                let isAdultMovie: (XtreamVODStream) -> Bool = { m in
                    m.isAdult || adultMovies.contains(m.streamId.value) || adultVodCats.contains(m.categoryId?.value ?? "")
                }
                let isAdultSeries: (XtreamSeries) -> Bool = { adultSeriesCats.contains($0.categoryId?.value ?? "") }
                return (
                    rawMovies.filter { !isAdultMovie($0) },
                    rawSeries.filter { !isAdultSeries($0) },
                    movieDicts.filter { !adultVodCats.contains($0.key) }.mapValues { $0.filter { !isAdultMovie($0) } },
                    seriesDicts.filter { !adultSeriesCats.contains($0.key) },
                    events.filter { e in
                        switch e.content {
                        case .movie: return !adultVodCats.contains(e.categoryID ?? "") && !adultMovies.contains(e.itemID)
                        case .series: return !adultSeriesCats.contains(e.categoryID ?? "")
                        case .live: return false
                        }
                    }
                )
            }.value
        }
        let snapshot = RecommendationEngine.Snapshot(
            events: safeEvents,
            movies: safeMovies,
            series: safeSeries,
            moviesByCategory: safeMoviesByCat,
            seriesByCategory: safeSeriesByCat,
            vodCategoryNames: Dictionary(vodCategories.map { ($0.id, $0.cleanName) }, uniquingKeysWith: { a, _ in a }),
            seriesCategoryNames: Dictionary(seriesCategories.map { ($0.id, $0.cleanName) }, uniquingKeysWith: { a, _ in a }),
            watchHistory: watchHistory,
            favoriteMovieIDs: favoriteMovieIDs,
            favoriteSeriesIDs: favoriteSeriesIDs,
            refreshSeed: feedRefreshSeed
        )
        guard !snapshot.movies.isEmpty || !snapshot.series.isEmpty else { return }
        let feed = await Task.detached(priority: .utility) {
            RecommendationEngine.build(snapshot)
        }.value
        guard !Task.isCancelled, tasteProfileID == profileID else { return }
        homeFeed = feed
    }

    func clearWatchHistory() {
        cloudSync?.clearProgress(watchHistory)
        watchHistory.removeAll()
    }

    /// Writes any playback position not yet saved (called when the player closes).
    func flushCloudProgress() {
        cloudSync?.flush()
    }

    func savedProgress(for itemID: String) -> WatchHistoryEntry? {
        watchHistory.first { $0.id == itemID }
    }

    // MARK: - NSFW Content Filtering

    /// Matches provider "adult" category naming (e.g. "FOR ADULTS", "XXX", "18+") while
    /// excluding false positives like "Adult Swim" (cartoons).
    nonisolated static func isAdultCategoryName(_ name: String) -> Bool {
        let upper = name.uppercased()
        if upper.contains("ADULT SWIM") || upper.contains("ADULT-SWIM") || upper.contains("YOUNG ADULT") {
            return false
        }
        let patterns = [
            #"\bFOR ADULTS?\b"#, #"\bADULTS?\b"#, #"\bXXX\b"#, #"\bPORN"#, #"(^|[^0-9])18\s?\+"#,
            #"\+\s?18\b"#, #"\bEROTI[CK]"#, #"\bNSFW\b"#, #"\bHENTAI\b"#, #"\bPLAYBOY\b"#
        ]
        return patterns.contains { upper.range(of: $0, options: .regularExpression) != nil }
    }

    func isAdultContent(_ channel: XtreamLiveStream) -> Bool {
        channel.isAdult
            || adultLiveStreamIDs.contains(channel.streamId.value)
            || adultLiveCategoryIDs.contains(channel.categoryId?.value ?? "")
            || aiHiddenLiveCategoryIDs.contains(channel.categoryId?.value ?? "")
    }

    func isAdultContent(_ movie: XtreamVODStream) -> Bool {
        movie.isAdult
            || adultMovieIDs.contains(movie.streamId.value)
            || adultVodCategoryIDs.contains(movie.categoryId?.value ?? "")
            || aiHiddenVodCategoryIDs.contains(movie.categoryId?.value ?? "")
    }

    func isAdultContent(_ series: XtreamSeries) -> Bool {
        adultSeriesCategoryIDs.contains(series.categoryId?.value ?? "")
            || aiHiddenSeriesCategoryIDs.contains(series.categoryId?.value ?? "")
    }

    /// Whether a Continue Watching / history entry should be hidden by the NSFW filter
    func isAdultContent(_ entry: WatchHistoryEntry) -> Bool {
        guard !showAdultContent else { return false }
        switch entry.contentType {
        case .live:
            return entry.streamID.map { adultLiveStreamIDs.contains($0) } ?? false
        case .movie:
            guard let sid = entry.streamID else { return false }
            if adultMovieIDs.contains(sid) { return true }
            if let movie = movieByID(sid) { return isAdultContent(movie) }
            return false
        case .seriesEpisode:
            guard let seriesID = entry.seriesID, let series = seriesByID(seriesID) else { return false }
            return isAdultContent(series)
        }
    }

    /// Watch history with NSFW items removed when the filter is on
    var visibleWatchHistory: [WatchHistoryEntry] {
        showAdultContent ? watchHistory : watchHistory.filter { !isAdultContent($0) }
    }

    /// Next episode for series whose latest watched episode is finished, keyed by series ID.
    /// Filled by `refreshUpNext()`; the lookup needs the series' episode list from the provider.
    var upNextBySeries: [Int: WatchHistoryEntry] = [:]

    /// Netflix-style row: one card per series (its latest episode, or the next one once that's finished),
    /// finished movies dropped, newest first.
    var continueWatchingEntries: [WatchHistoryEntry] {
        var seenSeries = Set<Int>()
        var rows: [WatchHistoryEntry] = []
        for entry in visibleWatchHistory {
            if entry.contentType == .seriesEpisode, let seriesID = entry.seriesID {
                guard seenSeries.insert(seriesID).inserted else { continue }
                if !entry.isWatched {
                    rows.append(entry)
                } else if let next = upNextBySeries[seriesID],
                          !(watchHistory.first { $0.id == next.id }?.isWatched ?? false) {
                    rows.append(next)
                }
            } else if !entry.isWatched {
                rows.append(entry)
            }
        }
        return rows
    }

    /// Resolves the episode after each finished one at the top of a series' history.
    func refreshUpNext() async {
        var seenSeries = Set<Int>()
        for entry in visibleWatchHistory {
            guard entry.contentType == .seriesEpisode, let seriesID = entry.seriesID,
                  seenSeries.insert(seriesID).inserted, entry.isWatched,
                  upNextBySeries[seriesID]?.lastWatchedAt != entry.lastWatchedAt else { continue }
            guard let next = await nextEpisode(after: entry.toPlaybackItem()) else {
                upNextBySeries.removeValue(forKey: seriesID)
                continue
            }
            upNextBySeries[seriesID] = WatchHistoryEntry(
                id: next.id, contentType: .seriesEpisode, title: next.title, subtitle: next.subtitle,
                artworkURL: next.artworkURL ?? entry.artworkURL, streamID: nil, episodeID: next.episodeID,
                seriesID: seriesID, containerExtension: next.containerExtension,
                positionSeconds: 0, durationSeconds: 0, lastWatchedAt: entry.lastWatchedAt)
        }
    }

    var visibleFavoriteMovies: [XtreamVODStream] {
        showAdultContent ? favoriteMovies : favoriteMovies.filter { !isAdultContent($0) }
    }

    var visibleFavoriteSeries: [XtreamSeries] {
        showAdultContent ? favoriteSeries : favoriteSeries.filter { !isAdultContent($0) }
    }

    var visibleFavoriteLiveChannels: [XtreamLiveStream] {
        showAdultContent ? favoriteLiveChannels : favoriteLiveChannels.filter { !isAdultContent($0) }
    }

    /// Learns adult stream IDs and categories from the provider's `is_adult` flags
    private func learnAdultFlags(movies: [XtreamVODStream]) {
        var ids = Set<Int>()
        var cats = adultVodCategoryIDs
        for m in movies where m.isAdult {
            ids.insert(m.streamId.value)
            if let c = m.categoryId?.value, !c.isEmpty { cats.insert(c) }
        }
        adultMovieIDs = ids
        if cats != adultVodCategoryIDs {
            adultVodCategoryIDs = cats
            applyVisibleCategories()
        }
    }

    private func learnAdultFlags(live: [XtreamLiveStream]) {
        var ids = Set<Int>()
        var cats = adultLiveCategoryIDs
        for c in live where c.isAdult {
            ids.insert(c.streamId.value)
            if let cat = c.categoryId?.value, !cat.isEmpty { cats.insert(cat) }
        }
        adultLiveStreamIDs = ids
        if cats != adultLiveCategoryIDs {
            adultLiveCategoryIDs = cats
            applyVisibleCategories()
        }
    }

    private func applyVisibleCategories() {
        if showAdultContent {
            liveCategories = rawLiveCategories
            vodCategories = rawVodCategories
            seriesCategories = rawSeriesCategories
        } else {
            liveCategories = rawLiveCategories.filter { !adultLiveCategoryIDs.contains($0.id) && !aiHiddenLiveCategoryIDs.contains($0.id) }
            vodCategories = rawVodCategories.filter { !adultVodCategoryIDs.contains($0.id) && !aiHiddenVodCategoryIDs.contains($0.id) }
            seriesCategories = rawSeriesCategories.filter { !adultSeriesCategoryIDs.contains($0.id) && !aiHiddenSeriesCategoryIDs.contains($0.id) }
        }
        // Never leave a hidden category selected while the filter is on
        if !showAdultContent {
            if !liveCategories.contains(where: { $0.id == selectedLiveCategoryID }) { selectedLiveCategoryID = liveCategories.first?.id ?? "" }
            if !vodCategories.contains(where: { $0.id == selectedVODCategoryID }) { selectedVODCategoryID = vodCategories.first?.id ?? "" }
            if !seriesCategories.contains(where: { $0.id == selectedSeriesCategoryID }) { selectedSeriesCategoryID = seriesCategories.first?.id ?? "" }
        }
    }

    // MARK: - AI category tags

    /// Follows the line's AI tags (kids-safe, adult, language, genre) and tags new categories in the background.
    private func startSmartTags() {
        guard let lineID = activeLineID else { return }
        SmartAI.shared.startTags(lineID: lineID, categories: [
            (kind: "live", cats: rawLiveCategories), (kind: "movie", cats: rawVodCategories), (kind: "series", cats: rawSeriesCategories)
        ]) { [weak self] in
            self?.applySmartTags()
        }
        applySmartTags(immediately: true)
    }

    /// Recomputes which categories the tags hide; re-filters the catalog (debounced) when that changed.
    private func applySmartTags(immediately: Bool = false) {
        let kids = isKidsProfile
        func hidden(_ kind: String, _ cats: [XtreamCategory]) -> Set<String> {
            Set(cats.filter { cat in
                guard let tag = SmartAI.shared.tag(kind, cat.id) else { return false }
                return tag.adult > 0.5 || (kids && tag.kids < 0.5)
            }.map(\.id))
        }
        let live = hidden("live", rawLiveCategories)
        let vod = hidden("movie", rawVodCategories)
        let series = hidden("series", rawSeriesCategories)
        guard live != aiHiddenLiveCategoryIDs || vod != aiHiddenVodCategoryIDs || series != aiHiddenSeriesCategoryIDs else { return }
        aiHiddenLiveCategoryIDs = live
        aiHiddenVodCategoryIDs = vod
        aiHiddenSeriesCategoryIDs = series
        smartTagsTask?.cancel()
        if immediately {
            applyVisibleCategories()
            return
        }
        smartTagsTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard let self, !Task.isCancelled, !self.showAdultContent else { return }
            self.applyContentFilter()
        }
    }

    /// Smart search: the catalog filtered by AI-read filters ("funny hindi movies from the 2010s"). Language and
    /// genre come from the category tags, years from the title. Best matches first.
    func smartSearchResults(_ f: SmartAI.SearchFilters, limit: Int = 60) -> (live: [XtreamLiveStream], movies: [XtreamVODStream], series: [XtreamSeries]) {
        let words = f.keywords.map { $0.lowercased() }
        func score(kind: String, categoryID: String?, name: String, year: Int?, rating: Double) -> Double? {
            let tag = SmartAI.shared.tag(kind, categoryID)
            let genreHit = tag.map { f.genres.contains($0.genre ?? "") } ?? false
            if !f.languages.isEmpty && !(tag.map { f.languages.contains($0.lang ?? "") } ?? false) { return nil }
            if !f.genres.isEmpty && !genreHit && words.isEmpty { return nil }
            if let from = f.yearFrom, (year ?? 0) < from { return nil }
            if let to = f.yearTo, (year ?? Int.max) > to { return nil }
            let lower = name.lowercased()
            let hits = words.filter { lower.contains($0) }.count
            if !words.isEmpty && hits == 0 && !(!f.genres.isEmpty && genreHit) { return nil }
            switch f.sort {
            case "newest": return Double(year ?? 0)
            case "rating": return rating
            default: return Double(hits * 3 + (genreHit ? 2 : 0)) + rating / 10
            }
        }
        func pick<T>(_ kind: String, _ items: [T], _ fields: (T) -> (cat: String?, name: String, year: Int?, rating: Double)) -> [T] {
            guard f.kind == "any" || f.kind == kind else { return [] }
            var scored: [(Double, T)] = []
            for item in items {
                let x = fields(item)
                if let s = score(kind: kind, categoryID: x.cat, name: x.name, year: x.year, rating: x.rating) { scored.append((s, item)) }
            }
            return scored.sorted { $0.0 > $1.0 }.prefix(limit).map(\.1)
        }
        let rating = { (s: String?) in Double(s ?? "") ?? 0 }
        let live = pick("live", allLoadedLiveStreams.filter { !$0.isSectionDivider && (showAdultContent || !isAdultContent($0)) }) {
            ($0.categoryId?.value, $0.cleanName, nil, 0)
        }
        let movies = pick("movie", allLoadedMovies.filter { showAdultContent || !isAdultContent($0) }) {
            ($0.categoryId?.value, $0.cleanName, SmartAI.year(in: $0.name), rating($0.rating?.value))
        }
        let series = pick("series", allLoadedSeries.filter { showAdultContent || !isAdultContent($0) }) {
            ($0.categoryId?.value, $0.cleanName, SmartAI.year(in: $0.releaseDate ?? "") ?? SmartAI.year(in: $0.name), rating($0.rating?.value))
        }
        return (live, movies, series)
    }

    /// Other channels that look like the same station (another quality or source), best first.
    func liveAlternatives(to item: PlaybackItem) -> [XtreamLiveStream] {
        guard item.contentType == .live else { return [] }
        let key = SmartAI.channelKey(XtreamTextFormatter.format(item.title).cleanTitle)
        guard !key.isEmpty else { return [] }
        return Array(allLoadedLiveStreams.lazy.filter {
            $0.streamId.value != item.streamID && !$0.isSectionDivider && SmartAI.channelKey($0.cleanName) == key
                && (self.showAdultContent || !self.isAdultContent($0))
        }.prefix(5))
    }

    /// Re-applies the NSFW filter everywhere after the setting changes
    private func applyContentFilter() {
        applyVisibleCategories()
        lastMovieQueryKey = ""
        lastSeriesQueryKey = ""
        lastLiveQueryKey = ""
        rebuildFeaturedHomeRails(preferredSeriesCatID: nil)
        scheduleHomeFeedRebuild(delay: 0)
    }

    // MARK: - Persistence Helpers

    /// Clears the per-person state; favorites and history then arrive from CloudSync.
    private func resetUserData() {
        let profileID = tasteProfileID ?? ""
        tasteEvents = TasteProfileStore.load(profileID: profileID)
        watchedMostRecorded = Set(tasteEvents.filter { $0.kind == .watchedMost }.map { "\($0.content == .movie ? "movie" : "series")-\($0.itemID)" })
        favoriteLiveChannels = []
        favoriteMovies = []
        favoriteSeries = []
        watchHistory = []
        homeFeed = HomeFeed()
    }
}
