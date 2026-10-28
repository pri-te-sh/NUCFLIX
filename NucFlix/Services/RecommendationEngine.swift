import Foundation

// MARK: - Taste Signals

/// A single implicit-feedback signal captured from user behaviour (plays, completions, My List, detail views).
struct TasteEvent: Codable, Hashable {
    enum Kind: String, Codable {
        case detailView      // opened a title's detail page
        case play            // started playback
        case watchedMost     // watched >= 50% of a movie / episode
        case favorite        // added to My List
        case download        // downloaded for offline
    }

    enum ContentKind: String, Codable {
        case movie, series, live
    }

    var kind: Kind
    var content: ContentKind
    var itemID: Int
    var title: String
    var categoryID: String?
    var genres: [String]
    var date: Date

    /// Base strength of each signal before time decay
    var weight: Double {
        switch kind {
        case .detailView: return 1.0
        case .play: return 3.0
        case .watchedMost: return 5.0
        case .favorite: return 4.0
        case .download: return 4.0
        }
    }
}

/// Persists a rolling window of taste events per profile.
enum TasteProfileStore {
    private static let maxEvents = 400

    private static func key(_ profileID: String) -> String { "nucflix.taste.events.v1.\(profileID)" }

    static func load(profileID: String) -> [TasteEvent] {
        guard let data = UserDefaults.standard.data(forKey: key(profileID)),
              let events = try? JSONDecoder().decode([TasteEvent].self, from: data) else { return [] }
        return events
    }

    static func save(_ events: [TasteEvent], profileID: String) {
        let trimmed = Array(events.suffix(maxEvents))
        DispatchQueue.global(qos: .utility).async {
            if let data = try? JSONEncoder().encode(trimmed) {
                UserDefaults.standard.set(data, forKey: key(profileID))
            }
        }
    }

}

// MARK: - Home Feed Output

enum FeedItem: Identifiable, Hashable {
    case movie(XtreamVODStream)
    case series(XtreamSeries)

    var id: String {
        switch self {
        case .movie(let m): return "movie-\(m.streamId.value)"
        case .series(let s): return "series-\(s.seriesId.value)"
        }
    }

    var title: String {
        switch self {
        case .movie(let m): return m.cleanName
        case .series(let s): return s.cleanName
        }
    }

    var posterURL: String? {
        switch self {
        case .movie(let m): return m.streamIcon
        case .series(let s): return s.cover ?? s.backdropPath?.values.first
        }
    }

    var categoryID: String? {
        switch self {
        case .movie(let m): return m.categoryId?.value
        case .series(let s): return s.categoryId?.value
        }
    }
}

struct HeroPick: Identifiable, Hashable {
    var item: FeedItem
    /// Why this title is being featured, e.g. "Because you watched Dune" / "#1 Pick for You"
    var reason: String
    var tags: [String]
    var id: String { item.id }
}

struct HomeRail: Identifiable, Hashable {
    enum Style: Hashable { case poster, top10 }
    var id: String
    var title: String
    var items: [FeedItem]
    var style: Style = .poster
}

struct HomeFeed {
    var heroPicks: [HeroPick] = []
    var rails: [HomeRail] = []
    var isPersonalized: Bool = false
    var generatedAt = Date()
}

// MARK: - Recommendation Engine

/// On-device, privacy-preserving recommender.
///
/// Builds a decayed taste profile (category, genre and title-keyword affinities) from implicit
/// feedback, scores candidate titles from the user's strongest categories, applies diversity
/// constraints, and assembles personalized rails ("Top Picks", "Because you watched…", "New on
/// NucFlix", "Critically Acclaimed") plus a rotating hero carousel. Runs off the main thread.
enum RecommendationEngine {
    struct Snapshot {
        var events: [TasteEvent]
        var movies: [XtreamVODStream]            // full catalog (or everything loaded so far)
        var series: [XtreamSeries]
        var moviesByCategory: [String: [XtreamVODStream]]
        var seriesByCategory: [String: [XtreamSeries]]
        var vodCategoryNames: [String: String]
        var seriesCategoryNames: [String: String]
        var watchHistory: [WatchHistoryEntry]
        var favoriteMovieIDs: Set<Int>
        var favoriteSeriesIDs: Set<Int>
        var refreshSeed: Int
        var now: Date = Date()
    }

    private static let decayHalfLifeDays: Double = 21

    // MARK: Taste Profile

    private struct TasteProfile {
        var categoryAffinity: [String: Double] = [:]  // "movie:<catID>" / "series:<catID>"
        var genreAffinity: [String: Double] = [:]
        var keywordAffinity: [String: Double] = [:]
        var totalWeight: Double = 0

        func normalized(_ dict: [String: Double]) -> [String: Double] {
            guard let maxValue = dict.values.max(), maxValue > 0 else { return [:] }
            return dict.mapValues { $0 / maxValue }
        }
    }

    private static let stopWords: Set<String> = [
        "the", "a", "an", "of", "and", "in", "on", "to", "for", "with", "part", "season", "movie",
        "hd", "fhd", "uhd", "4k", "1080p", "720p", "hevc", "multi", "sub", "dub", "vf", "vostfr",
        "ii", "iii", "iv", "2", "3", "4", "5", "la", "le", "el", "de", "der", "die", "das"
    ]

    static func keywords(from title: String) -> [String] {
        AppState.fastNormalize(title)
            .split(separator: " ")
            .map(String.init)
            .filter { $0.count >= 3 && !stopWords.contains($0) && Int($0) == nil }
    }

    static func genres(from raw: String?) -> [String] {
        guard let raw, !raw.isEmpty else { return [] }
        return raw
            .replacingOccurrences(of: "/", with: ",")
            .replacingOccurrences(of: "&", with: ",")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).capitalized }
            .filter { !$0.isEmpty && $0.count < 24 }
    }

    private static func buildProfile(_ events: [TasteEvent], now: Date) -> TasteProfile {
        var profile = TasteProfile()
        for event in events where event.content != .live {
            let ageDays = max(now.timeIntervalSince(event.date) / 86_400, 0)
            let decayed = event.weight * pow(0.5, ageDays / decayHalfLifeDays)
            profile.totalWeight += decayed
            if let cat = event.categoryID, !cat.isEmpty {
                profile.categoryAffinity["\(event.content.rawValue):\(cat)", default: 0] += decayed
            }
            for genre in event.genres {
                profile.genreAffinity[genre, default: 0] += decayed
            }
            for word in keywords(from: event.title) {
                profile.keywordAffinity[word, default: 0] += decayed * 0.5
            }
        }
        return profile
    }

    // MARK: Helpers

    private static func rating(_ raw: FlexibleString?) -> Double {
        guard let value = raw?.value, let d = Double(value) else { return 0 }
        return d > 10 ? d / 10 : d
    }

    private static func addedTimestamp(_ raw: FlexibleString?) -> TimeInterval {
        guard let value = raw?.value, let t = TimeInterval(value) else { return 0 }
        return t
    }

    /// Deterministic per-item jitter so the feed varies day-to-day (and on pull-to-refresh) but is stable within a session
    private static func jitter(_ id: Int, seed: Int) -> Double {
        var x = UInt64(bitPattern: Int64(id &* 2_654_435_761 &+ seed &* 40_503))
        x ^= x >> 33
        x = x &* 0xff51afd7ed558ccd
        x ^= x >> 33
        return Double(x % 10_000) / 10_000
    }

    private static func hasArtwork(_ item: FeedItem) -> Bool {
        guard let url = item.posterURL else { return false }
        return url.hasPrefix("http")
    }

    /// Caps items per category for a varied, non-repetitive rail
    private static func diversified(_ ranked: [FeedItem], perCategory: Int, limit: Int, excluding: Set<String>) -> [FeedItem] {
        var counts: [String: Int] = [:]
        var seenTitles = Set<String>()
        var result: [FeedItem] = []
        for item in ranked where !excluding.contains(item.id) {
            let cat = item.categoryID ?? ""
            let titleKey = AppState.fastNormalize(item.title)
            guard counts[cat, default: 0] < perCategory, seenTitles.insert(titleKey).inserted else { continue }
            counts[cat, default: 0] += 1
            result.append(item)
            if result.count >= limit { break }
        }
        return result
    }

    private static func timeOfDayTitle(_ now: Date) -> String {
        let hour = Calendar.current.component(.hour, from: now)
        switch hour {
        case 5..<12: return "Your Morning Picks"
        case 12..<17: return "Top Picks for You"
        case 17..<22: return "Tonight's Picks for You"
        default: return "Late-Night Picks for You"
        }
    }

    // MARK: Build

    static func build(_ snap: Snapshot) -> HomeFeed {
        let profile = buildProfile(snap.events, now: snap.now)
        let catAff = profile.normalized(profile.categoryAffinity)
        let genreAff = profile.normalized(profile.genreAffinity)
        let keywordAff = profile.normalized(profile.keywordAffinity)
        let isPersonalized = profile.totalWeight > 2.5
        let daySeed = Calendar.current.ordinality(of: .day, in: .era, for: snap.now) ?? 0
        let seed = daySeed &+ snap.refreshSeed &* 7919

        // Titles the user already finished or is mid-way through are not "recommendations"
        var consumedMovieIDs = Set<Int>()
        var consumedSeriesIDs = Set<Int>()
        for entry in snap.watchHistory {
            if entry.contentType == .movie, let sid = entry.streamID { consumedMovieIDs.insert(sid) }
            if let seriesID = entry.seriesID { consumedSeriesIDs.insert(seriesID) }
        }

        let now = snap.now.timeIntervalSince1970
        func recencyBoost(_ added: TimeInterval) -> Double {
            guard added > 0 else { return 0 }
            let days = (now - added) / 86_400
            if days < 0 { return 0 }
            return max(0, 1 - days / 60)  // linear fade over ~2 months
        }

        func keywordScore(_ title: String) -> Double {
            guard !keywordAff.isEmpty else { return 0 }
            var best = 0.0
            for word in keywords(from: title) {
                best = max(best, keywordAff[word] ?? 0)
            }
            return best
        }

        func genreScore(_ raw: String?) -> Double {
            guard !genreAff.isEmpty else { return 0 }
            let gs = genres(from: raw)
            guard !gs.isEmpty else { return 0 }
            return gs.map { genreAff[$0] ?? 0 }.reduce(0, +) / Double(gs.count)
        }

        func scoreMovie(_ m: XtreamVODStream) -> Double {
            let cat = catAff["movie:\(m.categoryId?.value ?? "")"] ?? 0
            let r = rating(m.rating) / 10
            return 3.0 * cat
                + 1.2 * keywordScore(m.name)
                + 0.9 * r
                + 0.8 * recencyBoost(addedTimestamp(m.added))
                + 0.35 * jitter(m.streamId.value, seed: seed)
        }

        func scoreSeries(_ s: XtreamSeries) -> Double {
            let cat = catAff["series:\(s.categoryId?.value ?? "")"] ?? 0
            let r = rating(s.rating) / 10
            return 3.0 * cat
                + 2.0 * genreScore(s.genre)
                + 1.2 * keywordScore(s.name)
                + 0.9 * r
                + 0.6 * recencyBoost(addedTimestamp(s.lastModified))
                + 0.35 * jitter(s.seriesId.value, seed: seed)
        }

        // Candidate pools: strongest categories first (bounded work), backfilled with fresh/popular titles
        let topMovieCats = catAff.filter { $0.key.hasPrefix("movie:") }
            .sorted { $0.value > $1.value }.prefix(8).map { String($0.key.dropFirst(6)) }
        let topSeriesCats = catAff.filter { $0.key.hasPrefix("series:") }
            .sorted { $0.value > $1.value }.prefix(8).map { String($0.key.dropFirst(7)) }

        var moviePool: [XtreamVODStream] = topMovieCats.flatMap { snap.moviesByCategory[$0] ?? [] }
        var seriesPool: [XtreamSeries] = topSeriesCats.flatMap { snap.seriesByCategory[$0] ?? [] }

        // Fresh arrivals across the whole catalog (cheap partial selection)
        let freshMovies = Array(snap.movies.lazy.filter { addedTimestamp($0.added) > 0 }
            .sorted { addedTimestamp($0.added) > addedTimestamp($1.added) }
            .prefix(400))
        let freshSeries = Array(snap.series
            .sorted { addedTimestamp($0.lastModified) > addedTimestamp($1.lastModified) }
            .prefix(300))
        moviePool.append(contentsOf: freshMovies)
        seriesPool.append(contentsOf: freshSeries)
        if moviePool.count < 200 { moviePool.append(contentsOf: snap.movies.prefix(600)) }
        if seriesPool.count < 150 { seriesPool.append(contentsOf: snap.series.prefix(400)) }

        var seenMovie = Set<Int>()
        moviePool = moviePool.filter { seenMovie.insert($0.streamId.value).inserted && !consumedMovieIDs.contains($0.streamId.value) }
        var seenSeries = Set<Int>()
        seriesPool = seriesPool.filter { seenSeries.insert($0.seriesId.value).inserted && !consumedSeriesIDs.contains($0.seriesId.value) }

        let rankedMovies = moviePool.map { ($0, scoreMovie($0)) }.sorted { $0.1 > $1.1 }
        let rankedSeries = seriesPool.map { ($0, scoreSeries($0)) }.sorted { $0.1 > $1.1 }

        // Interleave movies & series by score for blended rails
        var blended: [(FeedItem, Double)] = rankedMovies.prefix(250).map { (.movie($0.0), $0.1) }
            + rankedSeries.prefix(250).map { (.series($0.0), $0.1) }
        blended.sort { $0.1 > $1.1 }
        let blendedItems = blended.map(\.0)

        var feed = HomeFeed(isPersonalized: isPersonalized)
        var used = Set<String>()

        // HERO: top personalized picks with artwork (or fresh + acclaimed on cold start)
        let lastWatchedTitle = snap.events.last(where: { $0.kind != .detailView && $0.content != .live })?.title
        var heroCandidates = blendedItems.filter(hasArtwork)
        if !isPersonalized {
            heroCandidates = diversified(heroCandidates, perCategory: 1, limit: 12, excluding: [])
        }
        for (index, item) in diversified(heroCandidates, perCategory: 2, limit: 6, excluding: []).enumerated() {
            let reason: String
            if isPersonalized {
                if index == 0 {
                    reason = "#1 Pick for You"
                } else if index == 1, let last = lastWatchedTitle {
                    reason = "Because you watched \(AppState.cleanTitle(last))"
                } else {
                    reason = "Recommended for You"
                }
            } else {
                reason = index == 0 ? "New on NucFlix" : "Trending Now"
            }
            var tags: [String] = []
            switch item {
            case .movie(let m):
                tags.append("Film")
                if let cat = snap.vodCategoryNames[m.categoryId?.value ?? ""] { tags.append(cat) }
                let r = rating(m.rating)
                if r >= 0.1 { tags.append(String(format: "★ %.1f", r)) }
            case .series(let s):
                tags.append("Series")
                tags.append(contentsOf: genres(from: s.genre).prefix(2))
                if tags.count < 3, let cat = snap.seriesCategoryNames[s.categoryId?.value ?? ""] { tags.append(cat) }
            }
            feed.heroPicks.append(HeroPick(item: item, reason: reason, tags: Array(tags.prefix(4))))
            used.insert(item.id)
        }

        // RAIL: Top Picks (time-of-day aware title)
        let topPicks = diversified(blendedItems, perCategory: isPersonalized ? 4 : 2, limit: 20, excluding: used)
        if !topPicks.isEmpty {
            feed.rails.append(HomeRail(id: "top-picks", title: isPersonalized ? timeOfDayTitle(snap.now) : "Popular on NucFlix", items: topPicks))
            topPicks.prefix(8).forEach { used.insert($0.id) }
        }

        // RAILS: "Because you watched <X>" for the last 2 distinct strong-signal titles
        var anchors: [TasteEvent] = []
        var anchorKeys = Set<String>()
        for event in snap.events.reversed() where event.kind != .detailView && event.content != .live {
            let key = "\(event.content.rawValue)-\(event.itemID)"
            if anchorKeys.insert(key).inserted { anchors.append(event) }
            if anchors.count >= 2 { break }
        }
        for anchor in anchors {
            let anchorWords = Set(keywords(from: anchor.title))
            let anchorGenres = Set(anchor.genres)
            var similar: [(FeedItem, Double)] = []
            func similarity(title: String, cat: String?, genreRaw: String?, r: Double, id: Int) -> Double {
                let words = Set(keywords(from: title))
                let overlap = anchorWords.isEmpty ? 0 : Double(words.intersection(anchorWords).count) / Double(anchorWords.count)
                let gs = Set(genres(from: genreRaw))
                let gOverlap = anchorGenres.isEmpty || gs.isEmpty ? 0 : Double(gs.intersection(anchorGenres).count) / Double(anchorGenres.count)
                let sameCat = (cat != nil && cat == anchor.categoryID) ? 1.0 : 0
                return 2.5 * overlap + 2.0 * gOverlap + 1.2 * sameCat + 0.4 * (r / 10) + 0.2 * jitter(id, seed: seed)
            }
            let sameCatMovies = snap.moviesByCategory[anchor.categoryID ?? ""] ?? []
            let sameCatSeries = snap.seriesByCategory[anchor.categoryID ?? ""] ?? []
            let movieCandidates = anchor.content == .movie ? sameCatMovies : Array(sameCatMovies.prefix(200))
            let seriesCandidates = anchor.content == .series ? sameCatSeries : Array(sameCatSeries.prefix(200))
            for m in movieCandidates.prefix(1500) where m.streamId.value != anchor.itemID && !consumedMovieIDs.contains(m.streamId.value) {
                similar.append((.movie(m), similarity(title: m.name, cat: m.categoryId?.value, genreRaw: nil, r: rating(m.rating), id: m.streamId.value)))
            }
            for s in seriesCandidates.prefix(1500) where s.seriesId.value != anchor.itemID && !consumedSeriesIDs.contains(s.seriesId.value) {
                similar.append((.series(s), similarity(title: s.name, cat: s.categoryId?.value, genreRaw: s.genre, r: rating(s.rating), id: s.seriesId.value)))
            }
            // Genre-matched series from elsewhere in the catalog
            if !anchorGenres.isEmpty {
                for (s, _) in rankedSeries.prefix(300) where s.seriesId.value != anchor.itemID {
                    similar.append((.series(s), similarity(title: s.name, cat: s.categoryId?.value, genreRaw: s.genre, r: rating(s.rating), id: s.seriesId.value)))
                }
            }
            similar.sort { $0.1 > $1.1 }
            let items = diversified(similar.map(\.0), perCategory: 12, limit: 18, excluding: used)
            if items.count >= 4 {
                feed.rails.append(HomeRail(id: "byw-\(anchor.content.rawValue)-\(anchor.itemID)", title: "Because you watched \(AppState.cleanTitle(anchor.title))", items: items))
                items.prefix(6).forEach { used.insert($0.id) }
            }
        }

        // RAIL: New on NucFlix (fresh arrivals, biased toward the user's categories)
        var fresh: [(FeedItem, Double)] = freshMovies.prefix(250).map { m in
            let cat = catAff["movie:\(m.categoryId?.value ?? "")"] ?? 0
            return (.movie(m), recencyBoost(addedTimestamp(m.added)) + 0.8 * cat)
        }
        fresh += freshSeries.prefix(150).map { s in
            let cat = catAff["series:\(s.categoryId?.value ?? "")"] ?? 0
            return (.series(s), recencyBoost(addedTimestamp(s.lastModified)) + 0.8 * cat)
        }
        fresh.sort { $0.1 > $1.1 }
        let freshItems = diversified(fresh.map(\.0).filter(hasArtwork), perCategory: 5, limit: 18, excluding: used)
        if freshItems.count >= 4 {
            feed.rails.append(HomeRail(id: "new", title: "New on NucFlix", items: freshItems))
        }

        // RAIL: Top 10 Series Today (personalized ranking)
        let top10 = diversified(rankedSeries.map { FeedItem.series($0.0) }.filter(hasArtwork), perCategory: 3, limit: 10, excluding: used)
        if top10.count >= 5 {
            feed.rails.append(HomeRail(id: "top10", title: "Top 10 Shows for You Today", items: top10, style: .top10))
            top10.forEach { used.insert($0.id) }
        }

        // RAIL: favourite genre ("Because you love Crime")
        if let favoriteGenre = genreAff.max(by: { $0.value < $1.value })?.key, isPersonalized {
            let genreItems = rankedSeries
                .filter { genres(from: $0.0.genre).contains(favoriteGenre) }
                .map { FeedItem.series($0.0) }
            let items = diversified(genreItems, perCategory: 6, limit: 18, excluding: used)
            if items.count >= 4 {
                feed.rails.append(HomeRail(id: "genre-\(favoriteGenre)", title: "\(favoriteGenre) Shows You'll Love", items: items))
            }
        }

        // RAIL: favourite movie category ("More from <Category>")
        if let topCat = topMovieCats.first, let catName = snap.vodCategoryNames[topCat] {
            let items = diversified(
                (snap.moviesByCategory[topCat] ?? []).map { ($0, scoreMovie($0)) }.sorted { $0.1 > $1.1 }.map { FeedItem.movie($0.0) },
                perCategory: 30, limit: 18, excluding: used)
            if items.count >= 4 {
                feed.rails.append(HomeRail(id: "cat-\(topCat)", title: "More from \(catName)", items: items))
            }
        }

        // RAIL: Critically Acclaimed (rating ≥ 7.5)
        let acclaimed = blended
            .filter { pair in
                switch pair.0 {
                case .movie(let m): return rating(m.rating) >= 7.5
                case .series(let s): return rating(s.rating) >= 7.5
                }
            }
            .map(\.0)
        let acclaimedItems = diversified(acclaimed.filter(hasArtwork), perCategory: 4, limit: 18, excluding: used)
        if acclaimedItems.count >= 4 {
            feed.rails.append(HomeRail(id: "acclaimed", title: "Critically Acclaimed", items: acclaimedItems))
        }

        return feed
    }
}

extension AppState {
    /// Thread-safe cleaned display title (uses the memoized formatter)
    nonisolated static func cleanTitle(_ raw: String) -> String {
        XtreamTextFormatter.format(raw).cleanTitle
    }
}
