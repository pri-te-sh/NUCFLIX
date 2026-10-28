import Foundation

// MARK: - Fast Lenient Decoding

fileprivate extension KeyedDecodingContainer {
    /// Exactly equivalent to `try? decode(type, forKey: key)` (including how `null` values are
    /// handed to the Flexible* types), but skips the throw/catch of a `keyNotFound` error when
    /// the key is simply absent — which matters when decoding ~50K catalog rows.
    func lenientDecode<T: Decodable>(_ type: T.Type, forKey key: Key) -> T? {
        guard contains(key) else { return nil }
        return try? decode(type, forKey: key)
    }
}

// MARK: - Authentication & Server Info

struct XtreamAuthResponse: Codable {
    let userInfo: XtreamUserInfo?
    let serverInfo: XtreamServerInfo?

    enum CodingKeys: String, CodingKey {
        case userInfo = "user_info"
        case serverInfo = "server_info"
    }
}

struct XtreamUserInfo: Codable {
    var username: String?
    var password: String?
    var message: String?
    var auth: FlexibleInt?
    var status: String?
    var expDate: FlexibleString?
    var isTrial: FlexibleString?
    var activeCons: FlexibleString?
    var createdAt: FlexibleString?
    var maxConnections: FlexibleString?
    var allowedOutputFormats: [String]?

    enum CodingKeys: String, CodingKey {
        case username, password, message, auth, status
        case expDate = "exp_date"
        case isTrial = "is_trial"
        case activeCons = "active_cons"
        case createdAt = "created_at"
        case maxConnections = "max_connections"
        case allowedOutputFormats = "allowed_output_formats"
    }

    var isAuthenticated: Bool {
        if let auth = auth?.value, auth == 1 { return true }
        if let status = status?.lowercased(), status == "active" { return true }
        return false
    }

    /// Expiry instant exactly as the provider panel reports it (Unix epoch seconds).
    /// `nil` means the panel did not report an expiry (treated as unlimited).
    var expirationDate: Date? {
        guard let raw = expDate?.value, !raw.isEmpty, raw != "null",
              let timestamp = TimeInterval(raw), timestamp > 0 else {
            return nil
        }
        return Date(timeIntervalSince1970: timestamp)
    }

    /// Whole calendar days left before the line dies. `0` = expires today, negative = expired.
    var daysRemaining: Int? {
        guard let expirationDate else { return nil }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let expiryDay = calendar.startOfDay(for: expirationDate)
        return calendar.dateComponents([.day], from: today, to: expiryDay).day
    }

    /// Human readable countdown, e.g. "80 days left" / "Expires today" / "Expired 3 days ago".
    var expirationCountdownText: String {
        guard let days = daysRemaining else { return "Unlimited" }
        if days < 0 { return "Expired \(abs(days)) day\(abs(days) == 1 ? "" : "s") ago" }
        if days == 0 { return "Expires today" }
        if days == 1 { return "1 day left" }
        return "\(days) days left"
    }
}

// MARK: - Expiry Formatting Helpers

/// Formats provider timestamps. Xtream panels stamp `exp_date` in their own time zone
/// (e.g. Europe/Amsterdam), so the same instant can land on a different calendar day
/// locally — these helpers let the UI show both sides instead of one confusing date.
enum XtreamExpiryFormatter {
    /// Resolves a panel time zone identifier such as "Europe/Amsterdam".
    static func timeZone(_ identifier: String?) -> TimeZone? {
        guard let identifier, !identifier.isEmpty else { return nil }
        return TimeZone(identifier: identifier)
    }

    /// Formatters are expensive to create; cache one per (time zone, includeTime) combination.
    /// NSCache is thread-safe and a cached formatter is never mutated after creation.
    private static let formatterCache = NSCache<NSString, DateFormatter>()

    /// Medium date, optionally with the clock time.
    static func date(_ date: Date, timeZone: TimeZone?, includeTime: Bool) -> String {
        let key = "\(includeTime ? 1 : 0)|\(timeZone?.identifier ?? "-")" as NSString
        let formatter: DateFormatter
        if let cached = formatterCache.object(forKey: key) {
            formatter = cached
        } else {
            formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = includeTime ? .short : .none
            if let timeZone {
                formatter.timeZone = timeZone
            }
            formatterCache.setObject(formatter, forKey: key)
        }
        return formatter.string(from: date)
    }
}

struct XtreamServerInfo: Codable {
    var url: String?
    var port: FlexibleString?
    var httpsPort: FlexibleString?
    var serverProtocol: String?
    var rtmpPort: FlexibleString?
    var timezone: String?
    var timestampNow: FlexibleInt?
    var timeNow: String?

    enum CodingKeys: String, CodingKey {
        case url, port, timezone
        case httpsPort = "https_port"
        case serverProtocol = "server_protocol"
        case rtmpPort = "rtmp_port"
        case timestampNow = "timestamp_now"
        case timeNow = "time_now"
    }
}

// MARK: - Shared Category Model

struct XtreamCategory: Codable, Identifiable, Hashable {
    var id: String { categoryId.value }
    var categoryId: FlexibleString
    var categoryName: String
    var parentId: FlexibleInt?

    enum CodingKeys: String, CodingKey {
        case categoryId = "category_id"
        case categoryName = "category_name"
        case parentId = "parent_id"
    }

    var formatted: FormattedMediaTitle {
        XtreamTextFormatter.format(categoryName)
    }

    var cleanName: String {
        formatted.cleanTitle
    }

    var prefixBadge: String? {
        formatted.prefixTag
    }

    var qualityBadges: [String] {
        formatted.badges
    }

    init(id: String, name: String, parentId: Int = 0) {
        self.categoryId = FlexibleString(id)
        self.categoryName = name
        self.parentId = FlexibleInt(parentId)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.categoryId = (container.lenientDecode(FlexibleString.self, forKey: .categoryId)) ?? FlexibleString("0")
        self.categoryName = (container.lenientDecode(String.self, forKey: .categoryName)) ?? "Uncategorized"
        self.parentId = container.lenientDecode(FlexibleInt.self, forKey: .parentId)
    }
}

// MARK: - Live TV Stream

struct XtreamLiveStream: Codable, Identifiable, Hashable {
    var id: Int { streamId.value }
    var num: FlexibleInt?
    var name: String
    var streamType: String?
    var streamId: FlexibleInt
    var streamIcon: String?
    var epgChannelId: FlexibleString?
    var added: FlexibleString?
    var categoryId: FlexibleString?
    var tvArchive: FlexibleInt?
    var tvArchiveDuration: FlexibleInt?
    /// Provider-supplied adult flag (`is_adult` = "1")
    var isAdultFlag: FlexibleString?

    var isAdult: Bool { isAdultFlag?.value == "1" }

    enum CodingKeys: String, CodingKey {
        case num, name
        case isAdultFlag = "is_adult"
        case streamType = "stream_type"
        case streamId = "stream_id"
        case streamIcon = "stream_icon"
        case epgChannelId = "epg_channel_id"
        case added
        case categoryId = "category_id"
        case tvArchive = "tv_archive"
        case tvArchiveDuration = "tv_archive_duration"
    }

    var formatted: FormattedMediaTitle {
        XtreamTextFormatter.format(name)
    }

    var cleanName: String {
        formatted.cleanTitle
    }

    var prefixBadge: String? {
        formatted.prefixTag
    }

    var qualityBadges: [String] {
        formatted.badges
    }

    var isSectionDivider: Bool {
        formatted.isSectionDivider
    }

    init(
        num: Int = 1,
        name: String,
        streamId: Int,
        streamIcon: String? = nil,
        epgChannelId: String? = nil,
        categoryId: String = "1",
        tvArchive: Int = 0
    ) {
        self.num = FlexibleInt(num)
        self.name = name
        self.streamType = "live"
        self.streamId = FlexibleInt(streamId)
        self.streamIcon = streamIcon
        self.epgChannelId = epgChannelId.map { FlexibleString($0) }
        self.categoryId = FlexibleString(categoryId)
        self.tvArchive = FlexibleInt(tvArchive)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.num = container.lenientDecode(FlexibleInt.self, forKey: .num)
        self.name = (container.lenientDecode(FlexibleString.self, forKey: .name)?.value) ?? "Channel"
        self.streamType = container.lenientDecode(String.self, forKey: .streamType)
        self.streamId = (container.lenientDecode(FlexibleInt.self, forKey: .streamId)) ?? FlexibleInt(0)
        self.streamIcon = container.lenientDecode(String.self, forKey: .streamIcon)
        self.epgChannelId = container.lenientDecode(FlexibleString.self, forKey: .epgChannelId)
        self.added = container.lenientDecode(FlexibleString.self, forKey: .added)
        self.categoryId = container.lenientDecode(FlexibleString.self, forKey: .categoryId)
        self.tvArchive = container.lenientDecode(FlexibleInt.self, forKey: .tvArchive)
        self.tvArchiveDuration = container.lenientDecode(FlexibleInt.self, forKey: .tvArchiveDuration)
        self.isAdultFlag = container.lenientDecode(FlexibleString.self, forKey: .isAdultFlag)
    }
}

// MARK: - EPG (Electronic Program Guide)

struct XtreamEPGResponse: Codable {
    var epgListings: [XtreamEPGItem]?

    enum CodingKeys: String, CodingKey {
        case epgListings = "epg_listings"
    }
}

struct XtreamEPGItem: Codable, Identifiable, Hashable {
    var id: String { "\(rawId.value)-\(startTimestamp.value)" }
    var rawId: FlexibleString
    var epgId: FlexibleString?
    var titleRaw: String
    var lang: String?
    var start: String?
    var end: String?
    var descriptionRaw: String?
    var channelId: String?
    var startTimestamp: FlexibleInt
    var stopTimestamp: FlexibleInt

    enum CodingKeys: String, CodingKey {
        case rawId = "id"
        case epgId = "epg_id"
        case titleRaw = "title"
        case lang, start, end
        case descriptionRaw = "description"
        case channelId = "channel_id"
        case startTimestamp = "start_timestamp"
        case stopTimestamp = "stop_timestamp"
    }

    var title: String {
        titleRaw.decodedBase64OrSelf
    }

    var descriptionText: String {
        descriptionRaw?.decodedBase64OrSelf ?? ""
    }

    var startDate: Date? {
        guard startTimestamp.value > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(startTimestamp.value))
    }

    var endDate: Date? {
        guard stopTimestamp.value > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(stopTimestamp.value))
    }

    var isNowPlaying: Bool {
        let now = Int(Date().timeIntervalSince1970)
        return startTimestamp.value <= now && stopTimestamp.value > now
    }

    var progress: Double {
        let now = Double(Date().timeIntervalSince1970)
        let startVal = Double(startTimestamp.value)
        let stopVal = Double(stopTimestamp.value)
        guard stopVal > startVal else { return 0 }
        return min(max((now - startVal) / (stopVal - startVal), 0), 1)
    }

    private static let timeRangeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter
    }()

    var formattedTimeRange: String {
        guard let s = startDate, let e = endDate else {
            return "\(start ?? "") - \(end ?? "")"
        }
        let formatter = Self.timeRangeFormatter
        return "\(formatter.string(from: s)) – \(formatter.string(from: e))"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.rawId = (container.lenientDecode(FlexibleString.self, forKey: .rawId)) ?? FlexibleString(UUID().uuidString)
        self.epgId = container.lenientDecode(FlexibleString.self, forKey: .epgId)
        self.titleRaw = (container.lenientDecode(FlexibleString.self, forKey: .titleRaw)?.value) ?? "Program"
        self.lang = container.lenientDecode(String.self, forKey: .lang)
        self.start = container.lenientDecode(String.self, forKey: .start)
        self.end = container.lenientDecode(String.self, forKey: .end)
        self.descriptionRaw = container.lenientDecode(FlexibleString.self, forKey: .descriptionRaw)?.value
        self.channelId = container.lenientDecode(FlexibleString.self, forKey: .channelId)?.value
        self.startTimestamp = (container.lenientDecode(FlexibleInt.self, forKey: .startTimestamp)) ?? FlexibleInt(0)
        self.stopTimestamp = (container.lenientDecode(FlexibleInt.self, forKey: .stopTimestamp)) ?? FlexibleInt(0)
    }
}

// MARK: - VOD (Movies)

struct XtreamVODStream: Codable, Identifiable, Hashable {
    var id: Int { streamId.value }
    var num: FlexibleInt?
    var name: String
    var streamType: String?
    var streamId: FlexibleInt
    var streamIcon: String?
    var rating: FlexibleString?
    var rating5Based: FlexibleDouble?
    var tmdb: FlexibleString?
    var added: FlexibleString?
    var categoryId: FlexibleString?
    var containerExtension: String?
    /// Provider-supplied adult flag (`is_adult` = "1")
    var isAdultFlag: FlexibleString?

    var isAdult: Bool { isAdultFlag?.value == "1" }

    enum CodingKeys: String, CodingKey {
        case num, name, tmdb
        case isAdultFlag = "is_adult"
        case streamType = "stream_type"
        case streamId = "stream_id"
        case streamIcon = "stream_icon"
        case rating
        case rating5Based = "rating_5based"
        case added
        case categoryId = "category_id"
        case containerExtension = "container_extension"
    }

    var displayRating: String? {
        if let r = rating?.value, !r.isEmpty, r != "0", r != "0.0" {
            return r
        }
        if let r5 = rating5Based?.value, r5 > 0 {
            return String(format: "%.1f", r5 * 2.0)
        }
        return nil
    }

    var formatted: FormattedMediaTitle {
        XtreamTextFormatter.format(name)
    }

    var cleanName: String {
        formatted.cleanTitle
    }

    var prefixBadge: String? {
        formatted.prefixTag
    }

    var qualityBadges: [String] {
        formatted.badges
    }

    init(
        num: Int = 1,
        name: String,
        streamId: Int,
        streamIcon: String? = nil,
        rating: String = "8.2",
        categoryId: String = "1",
        containerExtension: String = "mp4"
    ) {
        self.num = FlexibleInt(num)
        self.name = name
        self.streamType = "movie"
        self.streamId = FlexibleInt(streamId)
        self.streamIcon = streamIcon
        self.rating = FlexibleString(rating)
        self.rating5Based = FlexibleDouble((Double(rating) ?? 8.0) / 2.0)
        self.categoryId = FlexibleString(categoryId)
        self.containerExtension = containerExtension
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.num = container.lenientDecode(FlexibleInt.self, forKey: .num)
        self.name = (container.lenientDecode(FlexibleString.self, forKey: .name)?.value) ?? "Movie"
        self.streamType = container.lenientDecode(String.self, forKey: .streamType)
        self.streamId = (container.lenientDecode(FlexibleInt.self, forKey: .streamId)) ?? FlexibleInt(0)
        self.streamIcon = container.lenientDecode(String.self, forKey: .streamIcon)
        self.rating = container.lenientDecode(FlexibleString.self, forKey: .rating)
        self.rating5Based = container.lenientDecode(FlexibleDouble.self, forKey: .rating5Based)
        self.tmdb = container.lenientDecode(FlexibleString.self, forKey: .tmdb)
        self.added = container.lenientDecode(FlexibleString.self, forKey: .added)
        self.categoryId = container.lenientDecode(FlexibleString.self, forKey: .categoryId)
        self.containerExtension = container.lenientDecode(String.self, forKey: .containerExtension)
        self.isAdultFlag = container.lenientDecode(FlexibleString.self, forKey: .isAdultFlag)
    }
}

struct XtreamVODInfoResponse: Codable {
    var info: XtreamVODInfoDetail?
    var movieData: XtreamVODMovieData?

    enum CodingKeys: String, CodingKey {
        case info
        case movieData = "movie_data"
    }
}

struct XtreamVODInfoDetail: Codable {
    var name: String?
    var coverBig: String?
    var movieImage: String?
    var releaseDate: String?
    var episodeRunTime: FlexibleString?
    var youtubeTrailer: String?
    var director: String?
    var actors: String?
    var cast: String?
    var description: String?
    var plot: String?
    var age: String?
    var country: String?
    var genre: String?
    var backdropPath: FlexibleStringArray?
    var durationSecs: FlexibleInt?
    var duration: String?
    var rating: FlexibleString?

    enum CodingKeys: String, CodingKey {
        case name, director, actors, cast, description, plot, age, country, genre, duration, rating
        case coverBig = "cover_big"
        case movieImage = "movie_image"
        case releaseDate = "releasedate"
        case episodeRunTime = "episode_run_time"
        case youtubeTrailer = "youtube_trailer"
        case backdropPath = "backdrop_path"
        case durationSecs = "duration_secs"
    }

    var resolvedPlot: String {
        if let plot, !plot.isEmpty { return plot }
        if let description, !description.isEmpty { return description }
        return "No synopsis available for this title."
    }

    var resolvedCast: String? {
        if let cast, !cast.isEmpty { return cast }
        if let actors, !actors.isEmpty { return actors }
        return nil
    }

    var resolvedBackdrop: String? {
        backdropPath?.values.first ?? coverBig ?? movieImage
    }
}

struct XtreamVODMovieData: Codable {
    var streamId: FlexibleInt?
    var name: String?
    var containerExtension: String?

    enum CodingKeys: String, CodingKey {
        case streamId = "stream_id"
        case name
        case containerExtension = "container_extension"
    }
}

// MARK: - TV Series

struct XtreamSeries: Codable, Identifiable, Hashable {
    var id: Int { seriesId.value }
    var num: FlexibleInt?
    var name: String
    var seriesId: FlexibleInt
    var cover: String?
    var plot: String?
    var cast: String?
    var director: String?
    var genre: String?
    var releaseDate: String?
    var lastModified: FlexibleString?
    var rating: FlexibleString?
    var rating5Based: FlexibleDouble?
    var backdropPath: FlexibleStringArray?
    var youtubeTrailer: String?
    var episodeRunTime: FlexibleString?
    var categoryId: FlexibleString?

    enum CodingKeys: String, CodingKey {
        case num, name, cover, plot, cast, director, genre, rating
        case seriesId = "series_id"
        case releaseDate = "releaseDate"
        case lastModified = "last_modified"
        case rating5Based = "rating_5based"
        case backdropPath = "backdrop_path"
        case youtubeTrailer = "youtube_trailer"
        case episodeRunTime = "episode_run_time"
        case categoryId = "category_id"
    }

    var displayRating: String? {
        if let r = rating?.value, !r.isEmpty, r != "0", r != "0.0" {
            return r
        }
        if let r5 = rating5Based?.value, r5 > 0 {
            return String(format: "%.1f", r5 * 2.0)
        }
        return nil
    }

    var formatted: FormattedMediaTitle {
        XtreamTextFormatter.format(name)
    }

    var cleanName: String {
        formatted.cleanTitle
    }

    var prefixBadge: String? {
        formatted.prefixTag
    }

    var qualityBadges: [String] {
        formatted.badges
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.num = container.lenientDecode(FlexibleInt.self, forKey: .num)
        self.name = (container.lenientDecode(FlexibleString.self, forKey: .name)?.value) ?? "Series"
        self.seriesId = (container.lenientDecode(FlexibleInt.self, forKey: .seriesId)) ?? FlexibleInt(0)
        self.cover = container.lenientDecode(String.self, forKey: .cover)
        self.plot = container.lenientDecode(String.self, forKey: .plot)
        self.cast = container.lenientDecode(String.self, forKey: .cast)
        self.director = container.lenientDecode(String.self, forKey: .director)
        self.genre = container.lenientDecode(String.self, forKey: .genre)
        self.releaseDate = container.lenientDecode(FlexibleString.self, forKey: .releaseDate)?.value
        self.lastModified = container.lenientDecode(FlexibleString.self, forKey: .lastModified)
        self.rating = container.lenientDecode(FlexibleString.self, forKey: .rating)
        self.rating5Based = container.lenientDecode(FlexibleDouble.self, forKey: .rating5Based)
        self.backdropPath = container.lenientDecode(FlexibleStringArray.self, forKey: .backdropPath)
        self.youtubeTrailer = container.lenientDecode(String.self, forKey: .youtubeTrailer)
        self.episodeRunTime = container.lenientDecode(FlexibleString.self, forKey: .episodeRunTime)
        self.categoryId = container.lenientDecode(FlexibleString.self, forKey: .categoryId)
    }
}

struct XtreamSeriesInfoResponse: Codable {
    var seasons: [XtreamSeason]
    var info: XtreamVODInfoDetail?
    var episodesBySeason: [Int: [XtreamEpisode]]

    enum CodingKeys: String, CodingKey {
        case seasons, info, episodes
    }

    init(seasons: [XtreamSeason] = [], info: XtreamVODInfoDetail? = nil, episodesBySeason: [Int: [XtreamEpisode]] = [:]) {
        self.seasons = seasons
        self.info = info
        self.episodesBySeason = episodesBySeason
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.seasons = (container.lenientDecode([XtreamSeason].self, forKey: .seasons)) ?? []
        self.info = container.lenientDecode(XtreamVODInfoDetail.self, forKey: .info)

        // Xtream Codes returns `episodes` either as a Dictionary `{"1": [...]}` or an Array `[[...]]`
        var parsed: [Int: [XtreamEpisode]] = [:]
        if let dict = container.lenientDecode([String: [XtreamEpisode]].self, forKey: .episodes) {
            for (key, list) in dict {
                let sNum = Int(key) ?? 1
                parsed[sNum] = list.sorted { $0.episodeNum.value < $1.episodeNum.value }
            }
        } else if let arr = container.lenientDecode([[XtreamEpisode]].self, forKey: .episodes) {
            for (index, list) in arr.enumerated() where !list.isEmpty {
                let sNum = list.first?.season?.value ?? (index + 1)
                parsed[sNum] = list.sorted { $0.episodeNum.value < $1.episodeNum.value }
            }
        }
        self.episodesBySeason = parsed
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(seasons, forKey: .seasons)
        try container.encodeIfPresent(info, forKey: .info)
        let stringDict = Dictionary(uniqueKeysWithValues: episodesBySeason.map { (String($0.key), $0.value) })
        try container.encode(stringDict, forKey: .episodes)
    }

    var sortedSeasonNumbers: [Int] {
        let fromEpisodes = Set(episodesBySeason.keys)
        let fromSeasons = Set(seasons.map { $0.seasonNumber.value }.filter { episodesBySeason[$0] != nil })
        return Array(fromEpisodes.union(fromSeasons)).sorted()
    }
}

struct XtreamSeason: Codable, Identifiable, Hashable {
    var id: Int { seasonNumber.value }
    var seasonNumber: FlexibleInt
    var name: String?
    var episodeCount: FlexibleInt?
    var cover: String?

    enum CodingKeys: String, CodingKey {
        case name, cover
        case seasonNumber = "season_number"
        case episodeCount = "episode_count"
    }
}

struct XtreamEpisode: Codable, Identifiable, Hashable {
    var id: String { episodeId.value }
    var episodeId: FlexibleString
    var episodeNum: FlexibleInt
    var title: String
    var containerExtension: String?
    var info: XtreamEpisodeInfo?
    var season: FlexibleInt?

    enum CodingKeys: String, CodingKey {
        case episodeId = "id"
        case episodeNum = "episode_num"
        case title
        case containerExtension = "container_extension"
        case info, season
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.episodeId = (container.lenientDecode(FlexibleString.self, forKey: .episodeId)) ?? FlexibleString(UUID().uuidString)
        self.episodeNum = (container.lenientDecode(FlexibleInt.self, forKey: .episodeNum)) ?? FlexibleInt(1)
        self.title = (container.lenientDecode(FlexibleString.self, forKey: .title)?.value) ?? "Episode"
        self.containerExtension = container.lenientDecode(String.self, forKey: .containerExtension)
        self.info = container.lenientDecode(XtreamEpisodeInfo.self, forKey: .info)
        self.season = container.lenientDecode(FlexibleInt.self, forKey: .season)
    }
}

struct XtreamEpisodeInfo: Codable, Hashable {
    var movieImage: String?
    var plot: String?
    var durationSecs: FlexibleInt?
    var duration: String?
    var rating: FlexibleDouble?

    enum CodingKeys: String, CodingKey {
        case movieImage = "movie_image"
        case plot
        case durationSecs = "duration_secs"
        case duration, rating
    }
}
