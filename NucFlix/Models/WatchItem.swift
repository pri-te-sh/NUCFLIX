import Foundation
import SwiftUI
import AVFoundation
import UIKit
import UserNotifications

enum MediaContentType: String, Codable, Hashable {
    case live
    case movie
    case seriesEpisode
}

enum DownloadQualityPreset: String, Codable, CaseIterable, Identifiable {
    case askEveryTime = "ask"
    case original = "original"
    case high1080p = "high1080p"
    case standard720p = "standard720p"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .askEveryTime: return "Ask Every Time (Show File Size)"
        case .original: return "Maximum / Original (4K / 1080p Direct)"
        case .high1080p: return "High (1080p HD Preferred)"
        case .standard720p: return "Standard / Data Saver (720p)"
        }
    }

    var shortLabel: String {
        switch self {
        case .askEveryTime: return "Ask Quality"
        case .original: return "Original (Best)"
        case .high1080p: return "High (1080p)"
        case .standard720p: return "Standard (720p)"
        }
    }

    var sizeScaleFactor: Double {
        switch self {
        case .askEveryTime, .original: return 1.0
        case .high1080p: return 0.52
        case .standard720p: return 0.28
        }
    }
}

/// Represents a playable media item across Live TV, VOD Movies, and Series Episodes.
struct PlaybackItem: Identifiable, Equatable {
    let id: String
    let contentType: MediaContentType
    let title: String
    let subtitle: String?
    let artworkURL: String?
    let streamID: Int?
    let episodeID: String?
    let containerExtension: String?
    let seriesID: Int?
    var resumeSeconds: Double = 0
    var localFileURL: URL? = nil

    static func fromLive(_ channel: XtreamLiveStream, subtitle: String? = nil) -> PlaybackItem {
        PlaybackItem(
            id: "live-\(channel.streamId.value)",
            contentType: .live,
            title: channel.name,
            subtitle: subtitle ?? "Live TV",
            artworkURL: channel.streamIcon,
            streamID: channel.streamId.value,
            episodeID: nil,
            containerExtension: nil,
            seriesID: nil
        )
    }

    static func fromMovie(_ movie: XtreamVODStream, resumeSeconds: Double = 0) -> PlaybackItem {
        let itemID = "movie-\(movie.streamId.value)"
        return PlaybackItem(
            id: itemID,
            contentType: .movie,
            title: movie.name,
            subtitle: "Movie",
            artworkURL: movie.streamIcon,
            streamID: movie.streamId.value,
            episodeID: nil,
            containerExtension: movie.containerExtension ?? "mp4",
            seriesID: nil,
            resumeSeconds: resumeSeconds,
            localFileURL: DownloadManager.shared.localFileURL(for: itemID)
        )
    }

    static func fromEpisode(
        series: XtreamSeries,
        episode: XtreamEpisode,
        seasonNumber: Int,
        resumeSeconds: Double = 0
    ) -> PlaybackItem {
        let itemID = "episode-\(episode.episodeId.value)"
        return PlaybackItem(
            id: itemID,
            contentType: .seriesEpisode,
            title: series.name,
            subtitle: "S\(seasonNumber) E\(episode.episodeNum.value) • \(episode.title)",
            artworkURL: episode.info?.movieImage ?? series.cover,
            streamID: nil,
            episodeID: episode.episodeId.value,
            containerExtension: episode.containerExtension ?? "mp4",
            seriesID: series.seriesId.value,
            resumeSeconds: resumeSeconds,
            localFileURL: DownloadManager.shared.localFileURL(for: itemID)
        )
    }
}

/// Persisted record for Watch History & Continue Watching
struct WatchHistoryEntry: Codable, Identifiable, Hashable {
    var id: String                   // e.g., "live-101", "movie-5001", "episode-9001"
    var contentType: MediaContentType
    var title: String
    var subtitle: String?
    var artworkURL: String?
    var streamID: Int?
    var episodeID: String?
    var seriesID: Int?
    var containerExtension: String?
    var positionSeconds: Double
    var durationSeconds: Double
    var lastWatchedAt: Date

    var progressFraction: Double {
        guard durationSeconds > 10 else { return 0 }
        return min(max(positionSeconds / durationSeconds, 0), 1)
    }

    func toPlaybackItem() -> PlaybackItem {
        PlaybackItem(
            id: id,
            contentType: contentType,
            title: title,
            subtitle: subtitle,
            artworkURL: artworkURL,
            streamID: streamID,
            episodeID: episodeID,
            containerExtension: containerExtension,
            seriesID: seriesID,
            resumeSeconds: contentType == .live ? 0 : positionSeconds,
            localFileURL: DownloadManager.shared.localFileURL(for: id)
        )
    }
}

// MARK: - Offline Downloads Models & Background-Capable Manager

struct DownloadedMediaItem: Codable, Identifiable, Hashable {
    let id: String                   // "movie-123" or "episode-456"
    let contentType: MediaContentType
    let title: String
    let subtitle: String?
    let artworkURL: String?
    let streamID: Int?
    let episodeID: String?
    let seriesID: Int?
    let containerExtension: String
    let localFileName: String
    let fileSizeBytes: Int64
    let downloadedAt: Date

    var cleanTitle: String {
        XtreamTextFormatter.format(title).cleanTitle
    }

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: fileSizeBytes, countStyle: .file)
    }

    var localFileURL: URL {
        DownloadManager.downloadsDirectory.appendingPathComponent(localFileName)
    }

    func toPlaybackItem(resumeSeconds: Double = 0) -> PlaybackItem {
        PlaybackItem(
            id: id,
            contentType: contentType,
            title: title,
            subtitle: subtitle,
            artworkURL: artworkURL,
            streamID: streamID,
            episodeID: episodeID,
            containerExtension: containerExtension,
            seriesID: seriesID,
            resumeSeconds: resumeSeconds,
            localFileURL: localFileURL
        )
    }
}

struct ActiveDownloadItem: Identifiable, Equatable, Codable {
    let id: String
    let contentType: MediaContentType
    let title: String
    let subtitle: String?
    let artworkURL: String?
    let streamID: Int?
    let episodeID: String?
    let seriesID: Int?
    let containerExtension: String
    /// Full stream URL. It embeds the Xtream username and password, so it is only kept in memory;
    /// `download_state.json` stores `redactedSourceURLString` instead.
    var sourceURLString: String
    var qualityLabel: String = "Original"
    var compressPreset: String? = nil
    var sizeScaleFactor: Double = 1.0
    var progress: Double
    var bytesWritten: Int64
    var totalBytes: Int64
    var retryCount: Int = 0
    /// Why the item is waiting or why it failed ("Waiting for a free connection…"); shown instead of progress.
    var statusNote: String?

    var cleanTitle: String {
        XtreamTextFormatter.format(title).cleanTitle
    }

    private static let credentialSegments = try! NSRegularExpression(pattern: "/(movie|series)/[^/]+/[^/]+/")
    private static let usernamePlaceholder = "{username}"
    private static let passwordPlaceholder = "{password}"

    /// Copy safe to write to disk: the login in the URL path is replaced by placeholders.
    var redacted: ActiveDownloadItem {
        var copy = self
        let range = NSRange(sourceURLString.startIndex..., in: sourceURLString)
        copy.sourceURLString = Self.credentialSegments.stringByReplacingMatches(
            in: sourceURLString, range: range,
            withTemplate: "/$1/\(Self.usernamePlaceholder)/\(Self.passwordPlaceholder)/")
        return copy
    }

    /// The real URL for a (possibly redacted) item, using the line that is signed in right now.
    func resolvedSourceURL(using credentials: XtreamCredentials?) -> URL? {
        guard sourceURLString.contains(Self.passwordPlaceholder) else { return URL(string: sourceURLString) }
        guard let credentials, sourceURLString.hasPrefix(credentials.normalizedBaseURL + "/") else { return nil }
        return URL(string: sourceURLString
            .replacingOccurrences(of: Self.usernamePlaceholder, with: credentials.encodedUsername)
            .replacingOccurrences(of: Self.passwordPlaceholder, with: credentials.encodedPassword))
    }

    var progressDetailText: String {
        if let statusNote { return statusNote }
        let written = ByteCountFormatter.string(fromByteCount: bytesWritten, countStyle: .file)
        if totalBytes > 0 {
            let total = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
            return "\(Int(progress * 100))% • \(written) / \(total) (\(qualityLabel))"
        }
        return "Downloading (\(qualityLabel)) • \(written)"
    }
}

struct DownloadQualityCandidate: Identifiable, Equatable {
    let id: String
    let title: String
    let subtitle: String
    let badge: String
    let movie: XtreamVODStream?
    let resolvedExtension: String
    let streamURL: URL
    let compressPreset: String?
    var sizeScaleFactor: Double = 1.0
}

/// On-disk snapshot of in-flight + queued downloads so they survive app termination and
/// background relaunches by the system (written to Library/Application Support).
private struct PersistedDownloadState: Codable {
    var version: Int = 1
    var active: [ActiveDownloadItem]
    var queued: [ActiveDownloadItem]
    var failed: [ActiveDownloadItem]?
    /// Written by older builds (a single slot); folded into `failed` on load.
    var lastFailed: ActiveDownloadItem?
}

/// Which of the two URLSessions a task belongs to.
private enum DownloadSessionKind: Hashable {
    case foreground
    case background

    /// Thread-safe: derived from the immutable configuration identifier.
    init(session: URLSession) {
        self = session.configuration.identifier == DownloadManager.backgroundSessionIdentifier ? .background : .foreground
    }
}

/// Task identifiers are only unique per session, so tasks are keyed by (session, identifier).
private struct DownloadTaskKey: Hashable {
    let kind: DownloadSessionKind
    let taskIdentifier: Int

    init(kind: DownloadSessionKind, task: URLSessionTask) {
        self.kind = kind
        self.taskIdentifier = task.taskIdentifier
    }
}

/// The transfer currently linked to a download item.
private struct LinkedDownloadTask {
    let task: URLSessionDownloadTask
    let kind: DownloadSessionKind
    /// True when started via `downloadTask(withResumeData:)` — progress must never move backwards.
    let startedFromResumeData: Bool

    var key: DownloadTaskKey { DownloadTaskKey(kind: kind, task: task) }
}

/// Keeps the screen from auto-locking while any reason holds (watching, downloading). Main thread only.
enum ScreenAwake {
    enum Reason { case playback, downloads }
    private static var reasons: Set<Reason> = []

    static func set(_ reason: Reason, _ on: Bool) {
        if on { reasons.insert(reason) } else { reasons.remove(reason) }
        UIApplication.shared.isIdleTimerDisabled = !reasons.isEmpty
    }
}

/// Hybrid download engine:
/// - While the app is in the foreground, transfers run on an in-process `URLSession` at full speed.
/// - On entering the background they are handed off (via resume data) to a background `URLSession`,
///   so they continue while the app is suspended, locked, or terminated by the system. iOS relaunches
///   the app in the background to deliver completion events
///   (see `AppDelegate.application(_:handleEventsForBackgroundURLSession:completionHandler:)`).
/// - On returning to the foreground, background transfers are handed back to the in-process session.
///
/// Threading model:
/// - All observable state, `downloadTasks`, handoff bookkeeping, `backgroundCompletionHandler` and
///   persistence scheduling are only touched on the main thread.
/// - URLSession delegate callbacks (both sessions) arrive on a private serial `delegateQueue`; they only
///   read thread-safe task properties (`taskDescription`, `response`, `taskIdentifier`), touch
///   delegate-queue-only state (`progressThrottleTimes`), move the finished temp file, then hop to main.
/// - File writes (state JSON, resume data) are serialized on `ioQueue`.
@Observable
final class DownloadManager: NSObject, URLSessionDownloadDelegate {
    static let shared = DownloadManager()

    static let backgroundSessionIdentifier = "com.priteshbhavsar.NucFlix.downloads"
    /// Upper bound of the user-selectable concurrent downloads setting (1...3).
    static let maxConcurrentDownloadsLimit = 3
    private static let userAgent = "IPTVSmartersPlayer/3.0 (iOS; iPhone; Scale/3.00)"
    private static let progressPublishInterval: TimeInterval = 0.5
    private static let progressPersistInterval: TimeInterval = 5

    private(set) var downloadedItems: [DownloadedMediaItem] = []
    private(set) var activeDownloads: [String: ActiveDownloadItem] = [:]
    private(set) var queuedDownloads: [ActiveDownloadItem] = []
    /// The signed-in IPTV line (memory only), used to rebuild download URLs saved without the login.
    var lineCredentials: XtreamCredentials? {
        didSet { if lineCredentials != nil { advanceQueueIfNeeded() } }
    }
    var lastDownloadError: String?
    /// Downloads that gave up after their retries. Kept (and persisted) until the user retries or removes
    /// them, so a failure never just makes an item vanish from the list.
    private(set) var failedDownloads: [ActiveDownloadItem] = []
    /// The line's `max_connections` from the provider. Every download is one connection, so running more
    /// than the line allows only gets refused (HTTP 509/884) or kicks another stream off.
    var lineMaxConnections: Int? {
        didSet {
            guard lineMaxConnections != oldValue else { return }
            enforceConcurrencyLimit()
            advanceQueueIfNeeded()
        }
    }
    private var concurrencyLimit: Int {
        min(maxConcurrentDownloads, max(1, lineMaxConnections ?? Self.maxConcurrentDownloadsLimit))
    }
    /// Provider answers that mean "this line has no free connection right now" (or rate limiting).
    private static let busyStatusCodes: Set<Int> = [429, 458, 503, 509, 884]
    private static let busyRetryLimit = 8
    /// Delays before retrying a transfer whose connection dropped.
    private static let networkRetryDelays: [TimeInterval] = [2, 5, 15, 30, 60]
    var preferredQualityPreset: DownloadQualityPreset = .original {
        didSet {
            UserDefaults.standard.set(preferredQualityPreset.rawValue, forKey: "xtream.downloadQualityPreset.v1")
        }
    }
    /// Downloads run fastest in-process; once the iPhone auto-locks they move to the slower system
    /// background session (and, on a 1-connection line, every move costs a reconnect).
    var keepAwakeWhileDownloading: Bool = UserDefaults.standard.object(forKey: "nucflix.keepAwakeWhileDownloading") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(keepAwakeWhileDownloading, forKey: "nucflix.keepAwakeWhileDownloading")
            updateScreenAwake()
        }
    }

    var hasPendingDownloads: Bool { !activeDownloads.isEmpty || !queuedDownloads.isEmpty }

    private func updateScreenAwake() {
        guard Thread.isMainThread else { return }
        ScreenAwake.set(.downloads, keepAwakeWhileDownloading && hasPendingDownloads)
    }

    var maxConcurrentDownloads: Int = 1 {
        didSet {
            UserDefaults.standard.set(maxConcurrentDownloads, forKey: "xtream.maxConcurrentDownloads.v1")
            enforceConcurrencyLimit()
            advanceQueueIfNeeded()
            persistStateNow()
        }
    }

    /// Completion handler handed to us by the system when it relaunches the app for background
    /// session events. Invoked (on main) from `urlSessionDidFinishEvents(forBackgroundURLSession:)`.
    /// Main thread only.
    @ObservationIgnored var backgroundCompletionHandler: (() -> Void)?

    // MARK: Session & Task Bookkeeping (main thread only unless noted)

    /// Created exactly once. Recreating the session with the same identifier on relaunch reconnects
    /// it to transfers the system kept running while the app was not in memory.
    /// Used while the app is in the background (transfers run out-of-process in nsurlsessiond).
    @ObservationIgnored private lazy var backgroundSession: URLSession = makeBackgroundSession()

    /// In-process session used while the app is in the foreground: full speed, no nsurlsessiond
    /// throttling. Tasks are handed off to/from `backgroundSession` on app state transitions.
    @ObservationIgnored private lazy var foregroundSession: URLSession = makeForegroundSession()

    /// Main thread only. True while the app is foregrounded (new transfers go to `foregroundSession`).
    @ObservationIgnored private var isAppInForeground = true

    /// Main thread only. Tasks we cancelled ourselves to move them between sessions; their
    /// cancellation callbacks must not be treated as failures / user cancels.
    @ObservationIgnored private var handoffCancelledTaskKeys: Set<DownloadTaskKey> = []
    /// Main thread only. Items currently between sessions (old task cancelled, waiting for resume data).
    @ObservationIgnored private var itemsInHandoff: Set<String> = []
    /// Short assertion covering the foreground -> background handoff itself.
    @ObservationIgnored private var handoffAssertionID: UIBackgroundTaskIdentifier = .invalid
    /// Foreground-session items that can't produce resume data (no Range support) and are kept
    /// running in-process under `keepAliveAssertionID` while the app is in the background.
    @ObservationIgnored private var keptAliveForegroundItems: Set<String> = []
    @ObservationIgnored private var keepAliveAssertionID: UIBackgroundTaskIdentifier = .invalid
    /// Main thread only. Outstanding `cancel(byProducingResumeData:)` handoff callbacks.
    @ObservationIgnored private var pendingHandoffCount = 0

    private let delegateQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.priteshbhavsar.NucFlix.downloads.delegate"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility
        return queue
    }()

    @ObservationIgnored private var downloadTasks: [String: LinkedDownloadTask] = [:]
    /// False until `getAllTasks` has been reconciled with restored state; the queue scheduler waits for it.
    @ObservationIgnored private var hasReattachedTasks = false

    /// Delegate-queue only: last progress publish time per (session, task identifier) (0.5s throttle).
    @ObservationIgnored private var progressThrottleTimes: [DownloadTaskKey: TimeInterval] = [:]

    // MARK: Persistence State

    private let ioQueue = DispatchQueue(label: "com.priteshbhavsar.NucFlix.downloads.io", qos: .utility)
    @ObservationIgnored private var lastStatePersistTime: TimeInterval = 0
    @ObservationIgnored private var pendingThrottledPersist: DispatchWorkItem?

    // Cached disk capacity values (avoids filesystem syscalls on every SwiftUI render)
    @ObservationIgnored private var cachedTotalDiskBytes: Int64 = 0
    @ObservationIgnored private var cachedFreeDiskBytes: Int64 = 0
    @ObservationIgnored private var diskStatsLastRefresh: TimeInterval = 0
    private static let diskStatsTTL: TimeInterval = 5

    /// Created once (lazily, thread-safe via `static let`) and excluded from iCloud backup.
    static let downloadsDirectory: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let dir = docs.appendingPathComponent("NucFlixDownloads", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var mutableDir = dir
            try? mutableDir.setResourceValues(values)
        }
        return dir
    }()

    private static let manifestURL: URL = downloadsDirectory.appendingPathComponent("downloads_manifest.json")

    /// Staging area (same volume as the final destination) where finished temp files are moved
    /// synchronously inside `didFinishDownloadingTo`, before URLSession deletes them.
    private static let incomingDirectory: URL = {
        let dir = downloadsDirectory.appendingPathComponent(".incoming", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// Library/Application Support/NucFlixDownloadState
    private static let stateDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("NucFlixDownloadState", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private static let stateURL: URL = stateDirectory.appendingPathComponent("download_state.json")

    private static let resumeDataDirectory: URL = {
        let dir = stateDirectory.appendingPathComponent("ResumeData", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    override private init() {
        super.init()
        if let raw = UserDefaults.standard.string(forKey: "xtream.downloadQualityPreset.v1"),
           let preset = DownloadQualityPreset(rawValue: raw) {
            self.preferredQualityPreset = preset
        }
        let savedMax = UserDefaults.standard.integer(forKey: "xtream.maxConcurrentDownloads.v1")
        if savedMax >= 1 && savedMax <= Self.maxConcurrentDownloadsLimit {
            self.maxConcurrentDownloads = savedMax
        }
        loadManifest()
        cleanIncomingDirectory()
        restorePersistedState()
        // A background relaunch (system delivering session events) starts with applicationState
        // == .background; restarts then go to the background session. A normal launch is .inactive.
        if Thread.isMainThread {
            isAppInForeground = UIApplication.shared.applicationState != .background
        }
        // Touch the background session so it is recreated now and the system can deliver pending events.
        _ = backgroundSession
        reattachToSystemTasks()
        setupAppLifecycleObservers()
    }

    /// Called by `AppDelegate` when the system relaunches the app for background session events.
    /// Accessing `shared` already recreates the session; this just makes that explicit.
    func ensureBackgroundSessionActive() {
        _ = backgroundSession
    }

    private func makeForegroundSession() -> URLSession {
        let config = URLSessionConfiguration.default
        config.httpMaximumConnectionsPerHost = Self.maxConcurrentDownloadsLimit
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 7 * 24 * 60 * 60
        config.waitsForConnectivity = false
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.networkServiceType = .responsiveData
        config.allowsCellularAccess = true
        config.allowsExpensiveNetworkAccess = true
        config.allowsConstrainedNetworkAccess = true
        config.httpAdditionalHeaders = [
            "User-Agent": Self.userAgent
        ]
        return URLSession(configuration: config, delegate: self, delegateQueue: delegateQueue)
    }

    private func session(for kind: DownloadSessionKind) -> URLSession {
        kind == .foreground ? foregroundSession : backgroundSession
    }

    /// Session for newly started / restarted transfers given the current app state.
    private var preferredSessionKind: DownloadSessionKind {
        isAppInForeground ? .foreground : .background
    }

    private func makeBackgroundSession() -> URLSession {
        let config = URLSessionConfiguration.background(withIdentifier: Self.backgroundSessionIdentifier)
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        config.allowsCellularAccess = true
        config.allowsExpensiveNetworkAccess = true
        config.allowsConstrainedNetworkAccess = true
        // The session is created once, but the concurrency setting can change at runtime (1...3);
        // allow the setting's maximum per host and let the queue scheduler enforce the live value.
        config.httpMaximumConnectionsPerHost = Self.maxConcurrentDownloadsLimit
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 7 * 24 * 60 * 60
        config.httpAdditionalHeaders = [
            "User-Agent": Self.userAgent
        ]
        return URLSession(configuration: config, delegate: self, delegateQueue: delegateQueue)
    }

    // MARK: - Relaunch Restore & Task Re-Attachment

    private func restorePersistedState() {
        guard let data = try? Data(contentsOf: Self.stateURL),
              let state = try? JSONDecoder().decode(PersistedDownloadState.self, from: data) else { return }

        var restoredActive: [String: ActiveDownloadItem] = [:]
        for item in state.active where !isDownloaded(item.id) {
            restoredActive[item.id] = item
        }
        var seen = Set(restoredActive.keys)
        var restoredQueue: [ActiveDownloadItem] = []
        for item in state.queued where !seen.contains(item.id) && !isDownloaded(item.id) {
            seen.insert(item.id)
            restoredQueue.append(item)
        }
        activeDownloads = restoredActive
        queuedDownloads = restoredQueue
        failedDownloads = (state.failed ?? []) + (state.lastFailed.map { [$0] } ?? [])
        failedDownloads.removeAll { isDownloaded($0.id) || restoredActive[$0.id] != nil || seen.contains($0.id) }
    }

    private func reattachToSystemTasks() {
        // Only the background session can have transfers that outlived the previous process.
        backgroundSession.getAllTasks { [weak self] tasks in
            let systemTasks = tasks.compactMap { $0 as? URLSessionDownloadTask }
            DispatchQueue.main.async {
                self?.relink(systemTasks: systemTasks)
            }
        }
    }

    /// Reconciles restored state with the transfers the system is still running for us.
    private func relink(systemTasks: [URLSessionDownloadTask]) {
        var liveByItemID: [String: URLSessionDownloadTask] = [:]
        for task in systemTasks {
            guard let itemID = task.taskDescription, !itemID.isEmpty else {
                task.cancel()
                continue
            }
            let key = DownloadTaskKey(kind: .background, task: task)
            if handoffCancelledTaskKeys.contains(key) { continue }
            // A queued item that somehow still has a live transfer gets promoted back to active.
            if activeDownloads[itemID] == nil, let qIdx = queuedDownloads.firstIndex(where: { $0.id == itemID }) {
                activeDownloads[itemID] = queuedDownloads.remove(at: qIdx)
            }
            guard activeDownloads[itemID] != nil, liveByItemID[itemID] == nil else {
                // Orphan (cancelled by the user / state lost) or duplicate transfer: stop wasting bandwidth.
                task.cancel()
                continue
            }
            if let existing = downloadTasks[itemID], existing.key != key {
                // Already restarted in this process (e.g. after a force-quit cancellation event).
                task.cancel()
                continue
            }
            if itemsInHandoff.contains(itemID) {
                task.cancel()
                continue
            }
            liveByItemID[itemID] = task
        }

        for (itemID, task) in liveByItemID {
            if downloadTasks[itemID] == nil {
                downloadTasks[itemID] = LinkedDownloadTask(task: task, kind: .background, startedFromResumeData: true)
            }
            if task.state == .suspended {
                task.resume()
            }
        }

        // Active items whose transfer no longer exists: resume from persisted resume data if present,
        // otherwise restart. Anything beyond the concurrency limit goes back to the front of the queue.
        let missing = activeDownloads.values
            .filter { downloadTasks[$0.id] == nil && !itemsInHandoff.contains($0.id) }
            .sorted { $0.progress > $1.progress }
        var requeued: [ActiveDownloadItem] = []
        for item in missing {
            if downloadTasks.count < concurrencyLimit {
                beginDownload(active: item, clearsFailure: false)
            } else {
                activeDownloads.removeValue(forKey: item.id)
                requeued.append(item)
            }
        }
        if !requeued.isEmpty {
            queuedDownloads.insert(contentsOf: requeued, at: 0)
        }

        hasReattachedTasks = true
        advanceQueueIfNeeded()
        persistStateNow()

        // Normal (foreground) launch with transfers the system kept running: pull them in-process.
        if isAppInForeground && Thread.isMainThread && UIApplication.shared.applicationState == .active {
            handOffBackgroundTasksToForeground()
        }
    }

    private func cleanIncomingDirectory() {
        let fm = FileManager.default
        guard let leftovers = try? fm.contentsOfDirectory(at: Self.incomingDirectory, includingPropertiesForKeys: nil) else { return }
        for url in leftovers {
            try? fm.removeItem(at: url)
        }
    }

    // MARK: - State & Resume Data Persistence

    /// Writes immediately (enqueue / start / finish / cancel / failure).
    private func persistStateNow() {
        updateScreenAwake()
        pendingThrottledPersist?.cancel()
        pendingThrottledPersist = nil
        lastStatePersistTime = ProcessInfo.processInfo.systemUptime
        let state = PersistedDownloadState(
            active: activeDownloads.values.map(\.redacted),
            queued: queuedDownloads.map(\.redacted),
            failed: failedDownloads.map(\.redacted)
        )
        guard let data = try? JSONEncoder().encode(state) else { return }
        ioQueue.async {
            try? data.write(to: Self.stateURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }

    /// Progress-tick persistence: at most once every `progressPersistInterval` seconds.
    private func persistStateThrottled() {
        let elapsed = ProcessInfo.processInfo.systemUptime - lastStatePersistTime
        if elapsed >= Self.progressPersistInterval {
            persistStateNow()
            return
        }
        guard pendingThrottledPersist == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingThrottledPersist = nil
            self.persistStateNow()
        }
        pendingThrottledPersist = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (Self.progressPersistInterval - elapsed), execute: work)
    }

    /// Blocks until all queued file writes have hit disk.
    private func flushPendingWrites() {
        ioQueue.sync {}
    }

    private static func resumeDataURL(for itemID: String) -> URL {
        let safeName = itemID.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? itemID
        return resumeDataDirectory.appendingPathComponent("\(safeName).resumedata")
    }

    /// Thread-safe (serialized on `ioQueue`).
    private func savePersistedResumeData(_ data: Data, for itemID: String) {
        let url = Self.resumeDataURL(for: itemID)
        ioQueue.async {
            try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }

    /// Reads and deletes persisted resume data (so an invalid blob can't cause a resume loop).
    private func consumePersistedResumeData(for itemID: String) -> Data? {
        let url = Self.resumeDataURL(for: itemID)
        return ioQueue.sync {
            guard let data = try? Data(contentsOf: url) else { return nil }
            try? FileManager.default.removeItem(at: url)
            return data
        }
    }

    private func deletePersistedResumeData(for itemID: String) {
        let url = Self.resumeDataURL(for: itemID)
        ioQueue.async {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func deleteAllPersistedResumeData() {
        let dir = Self.resumeDataDirectory
        ioQueue.async {
            let fm = FileManager.default
            guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
            for file in files {
                try? fm.removeItem(at: file)
            }
        }
    }

    // MARK: - Fast Remote Stream Size Probe (Without Downloading File)

    func probeRemoteFileSize(url: URL) async -> Int64? {
        var headReq = URLRequest(url: url)
        headReq.httpMethod = "HEAD"
        headReq.timeoutInterval = 6
        headReq.setValue("IPTVSmartersPlayer/3.0 (iOS; iPhone; Scale/3.00)", forHTTPHeaderField: "User-Agent")

        if let (_, response) = try? await URLSession.shared.data(for: headReq),
           let http = response as? HTTPURLResponse,
           http.expectedContentLength > 10_000 {
            return http.expectedContentLength
        }

        // Fallback: 2-byte Range GET to read Content-Range header ("bytes 0-1/1458291200")
        var rangeReq = URLRequest(url: url)
        rangeReq.httpMethod = "GET"
        rangeReq.timeoutInterval = 6
        rangeReq.setValue("bytes=0-1", forHTTPHeaderField: "Range")
        rangeReq.setValue("IPTVSmartersPlayer/3.0 (iOS; iPhone; Scale/3.00)", forHTTPHeaderField: "User-Agent")

        if let (_, response) = try? await URLSession.shared.bytes(for: rangeReq),
           let http = response as? HTTPURLResponse {
            if let contentRange = http.value(forHTTPHeaderField: "Content-Range"),
               let slashIndex = contentRange.lastIndex(of: "/"),
               let total = Int64(contentRange[contentRange.index(after: slashIndex)...].trimmingCharacters(in: .whitespaces)),
               total > 10_000 {
                return total
            }
            if http.expectedContentLength > 10_000 {
                return http.expectedContentLength
            }
        }
        return nil
    }

    // MARK: - App Lifecycle & Hybrid Session Handoff

    private func setupAppLifecycleObservers() {
        let center = NotificationCenter.default
        center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handOffForegroundTasksToBackground()
        }
        center.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // New transfers started from here on use the in-process session.
            self?.isAppInForeground = true
        }
        center.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handOffBackgroundTasksToForeground()
        }
    }

    /// True if the server response indicates URLSession can produce resume data
    /// (byte-range support + a validator), i.e. `cancel(byProducingResumeData:)` won't lose progress.
    private static func canProduceResumeData(_ task: URLSessionTask) -> Bool {
        guard let http = task.response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else { return false }
        let acceptRanges = (http.value(forHTTPHeaderField: "Accept-Ranges") ?? "").lowercased()
        let supportsRanges = acceptRanges.contains("bytes") || http.statusCode == 206
        let hasValidator = http.value(forHTTPHeaderField: "ETag") != nil
            || http.value(forHTTPHeaderField: "Last-Modified") != nil
        return supportsRanges && hasValidator
    }

    /// App entered the background: move in-process transfers to the background session.
    private func handOffForegroundTasksToBackground() {
        isAppInForeground = false
        let foregroundItems = downloadTasks.filter { $0.value.kind == .foreground }
        guard !foregroundItems.isEmpty else {
            if !activeDownloads.isEmpty || !queuedDownloads.isEmpty { persistStateNow() }
            return
        }

        // Short assertion so the handoff (waiting for resume data) can finish after suspension starts.
        if handoffAssertionID == .invalid {
            handoffAssertionID = UIApplication.shared.beginBackgroundTask(withName: "NucFlixDownloadHandoff") { [weak self] in
                self?.endHandoffAssertion()
            }
        }

        for (itemID, linked) in foregroundItems {
            let task = linked.task
            guard task.state == .running || task.state == .suspended else { continue } // finishing: let callbacks land
            if task.response == nil && !linked.startedFromResumeData {
                // Nothing downloaded yet: restart directly in the background session.
                moveTaskBetweenSessions(itemID: itemID, linked: linked, useResumeData: false)
            } else if Self.canProduceResumeData(task) || (task.response == nil && linked.startedFromResumeData) {
                moveTaskBetweenSessions(itemID: itemID, linked: linked, useResumeData: true)
            } else {
                // Server lacks Range support: cancelling would lose all progress. Keep it running
                // in-process for as long as iOS allows; on expiry it restarts in the background session.
                keptAliveForegroundItems.insert(itemID)
            }
        }

        if !keptAliveForegroundItems.isEmpty {
            beginKeepAliveAssertion()
        }
        endHandoffAssertionIfIdle()
        persistStateNow()
    }

    /// App became active: pull background-session transfers back in-process for full speed.
    private func handOffBackgroundTasksToForeground() {
        isAppInForeground = true
        keptAliveForegroundItems.removeAll()
        endKeepAliveAssertion()
        // Before relaunch re-attachment finishes the background tasks aren't linked yet; relink() calls us.
        guard hasReattachedTasks else { return }

        let backgroundItems = downloadTasks.filter { $0.value.kind == .background }
        // Moving a transfer means closing its connection and opening a new one. A line that allows a single
        // connection usually refuses the new one (HTTP 509) until the provider notices the old one closed,
        // so a transfer that is already receiving data stays in the background session.
        let singleConnectionLine = (lineMaxConnections ?? Self.maxConcurrentDownloadsLimit) <= 1
        for (itemID, linked) in backgroundItems {
            let task = linked.task
            guard task.state == .running || task.state == .suspended else { continue }
            if singleConnectionLine && task.response != nil { continue }
            if task.response == nil && !linked.startedFromResumeData {
                moveTaskBetweenSessions(itemID: itemID, linked: linked, useResumeData: false)
            } else if Self.canProduceResumeData(task) {
                moveTaskBetweenSessions(itemID: itemID, linked: linked, useResumeData: true)
            }
            // Otherwise leave it running in the background session so no progress is lost.
        }
    }

    /// Cancels `linked` (marking the cancellation as ours so it isn't treated as a failure/user cancel)
    /// and restarts the item in the session matching the current app state, with resume data if requested.
    private func moveTaskBetweenSessions(itemID: String, linked: LinkedDownloadTask, useResumeData: Bool) {
        downloadTasks.removeValue(forKey: itemID)
        handoffCancelledTaskKeys.insert(linked.key)
        itemsInHandoff.insert(itemID)
        if useResumeData {
            pendingHandoffCount += 1
            linked.task.cancel(byProducingResumeData: { [weak self] data in
                DispatchQueue.main.async {
                    self?.completeHandoff(itemID: itemID, resumeData: data, countedAsPending: true)
                }
            })
        } else {
            linked.task.cancel()
            completeHandoff(itemID: itemID, resumeData: nil, countedAsPending: false)
        }
    }

    private func completeHandoff(itemID: String, resumeData: Data?, countedAsPending: Bool) {
        if countedAsPending {
            pendingHandoffCount = max(0, pendingHandoffCount - 1)
        }
        itemsInHandoff.remove(itemID)
        defer { endHandoffAssertionIfIdle() }
        // Skip if cancelled by the user or completed while the handoff was in flight.
        guard let active = activeDownloads[itemID], downloadTasks[itemID] == nil else { return }
        // Target session is chosen at completion time, so a quick foreground/background flip is respected.
        beginDownload(active: active, resumeData: resumeData, clearsFailure: false)
    }

    private func endHandoffAssertionIfIdle() {
        if pendingHandoffCount == 0 {
            endHandoffAssertion()
        }
    }

    private func endHandoffAssertion() {
        guard handoffAssertionID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(handoffAssertionID)
        handoffAssertionID = .invalid
    }

    private func beginKeepAliveAssertion() {
        guard keepAliveAssertionID == .invalid else { return }
        keepAliveAssertionID = UIApplication.shared.beginBackgroundTask(withName: "NucFlixForegroundDownloadKeepAlive") { [weak self] in
            self?.keepAliveAssertionExpired()
        }
        if keepAliveAssertionID == .invalid {
            // No background time granted: move them to the background session right away.
            keepAliveAssertionExpired()
        }
    }

    /// Background time is up: restart the remaining non-resumable in-process transfers from scratch
    /// in the background session so they still complete while the app is suspended.
    private func keepAliveAssertionExpired() {
        for itemID in keptAliveForegroundItems {
            guard let linked = downloadTasks[itemID], linked.kind == .foreground else { continue }
            moveTaskBetweenSessions(itemID: itemID, linked: linked, useResumeData: false)
        }
        keptAliveForegroundItems.removeAll()
        persistStateNow()
        flushPendingWrites()
        endKeepAliveAssertion()
    }

    private func endKeepAliveAssertion() {
        guard keepAliveAssertionID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(keepAliveAssertionID)
        keepAliveAssertionID = .invalid
    }

    /// Call when a kept-alive in-process item finishes, fails or is cancelled.
    private func releaseKeepAlive(for itemID: String) {
        guard keptAliveForegroundItems.remove(itemID) != nil else { return }
        if keptAliveForegroundItems.isEmpty {
            endKeepAliveAssertion()
        }
    }

    // MARK: - Query State

    func isDownloaded(_ itemID: String) -> Bool {
        guard let item = downloadedItems.first(where: { $0.id == itemID }) else { return false }
        return FileManager.default.fileExists(atPath: item.localFileURL.path)
    }

    func isQueued(_ itemID: String) -> Bool {
        queuedDownloads.contains { $0.id == itemID }
    }

    /// Returns 1-based queue position (#1, #2, ...) if waiting in queue
    func queuePosition(for itemID: String) -> Int? {
        guard let idx = queuedDownloads.firstIndex(where: { $0.id == itemID }) else { return nil }
        return idx + 1
    }

    func downloadedItem(for itemID: String) -> DownloadedMediaItem? {
        guard let item = downloadedItems.first(where: { $0.id == itemID }),
              FileManager.default.fileExists(atPath: item.localFileURL.path) else {
            return nil
        }
        return item
    }

    func localFileURL(for itemID: String) -> URL? {
        downloadedItem(for: itemID)?.localFileURL
    }

    var totalStorageBytes: Int64 {
        downloadedItems.reduce(0) { $0 + $1.fileSizeBytes }
    }

    var formattedTotalStorage: String {
        ByteCountFormatter.string(fromByteCount: totalStorageBytes, countStyle: .file)
    }

    var deviceTotalDiskBytes: Int64 {
        refreshDiskStatsIfNeeded()
        return cachedTotalDiskBytes
    }

    var deviceFreeDiskBytes: Int64 {
        refreshDiskStatsIfNeeded()
        return cachedFreeDiskBytes
    }

    /// Recomputes disk capacity at most once every `diskStatsTTL` seconds.
    private func refreshDiskStatsIfNeeded() {
        let now = Date().timeIntervalSince1970
        guard now - diskStatsLastRefresh >= Self.diskStatsTTL || cachedTotalDiskBytes == 0 else { return }
        diskStatsLastRefresh = now

        let homeURL = URL(fileURLWithPath: NSHomeDirectory())
        let values = try? homeURL.resourceValues(forKeys: [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey
        ])

        if let total = values?.volumeTotalCapacity, total > 0 {
            cachedTotalDiskBytes = Int64(total)
        } else {
            let attrs = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory())
            cachedTotalDiskBytes = (attrs?[.systemSize] as? Int64) ?? 128_000_000_000
        }

        if let free = values?.volumeAvailableCapacityForImportantUsage, free > 0 {
            cachedFreeDiskBytes = free
        } else {
            let attrs = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory())
            cachedFreeDiskBytes = (attrs?[.systemFreeSize] as? Int64) ?? 32_000_000_000
        }
    }

    var formattedDeviceFreeSpace: String {
        ByteCountFormatter.string(fromByteCount: deviceFreeDiskBytes, countStyle: .file)
    }

    /// Movies only (not series episodes)
    var downloadedMoviesOnly: [DownloadedMediaItem] {
        downloadedItems.filter { $0.contentType == .movie }
    }

    var activeMovieDownloads: [ActiveDownloadItem] {
        activeDownloads.values.filter { $0.contentType == .movie }
    }

    var queuedMovieDownloads: [ActiveDownloadItem] {
        queuedDownloads.filter { $0.contentType == .movie }
    }

    /// Groups all Series Episodes (downloaded, active, and queued) under a single Series Poster entry
    var groupedSeriesDownloads: [DownloadedSeriesGroup] {
        var groupsByKey: [String: DownloadedSeriesGroup] = [:]
        var orderedKeys: [String] = []

        func keyFor(seriesID: Int?, cleanTitle: String) -> String {
            if let sID = seriesID, sID > 0 {
                return "series-\(sID)"
            }
            return "series-title-\(cleanTitle.lowercased())"
        }

        // 1. Active episode downloads
        for active in activeDownloads.values where active.contentType == .seriesEpisode {
            let key = keyFor(seriesID: active.seriesID, cleanTitle: active.cleanTitle)
            if groupsByKey[key] == nil {
                orderedKeys.append(key)
                groupsByKey[key] = DownloadedSeriesGroup(
                    id: key,
                    seriesID: active.seriesID,
                    title: active.cleanTitle,
                    artworkURL: active.artworkURL,
                    downloadedEpisodes: [],
                    activeEpisodes: [],
                    queuedEpisodes: []
                )
            }
            groupsByKey[key]?.activeEpisodes.append(active)
            if groupsByKey[key]?.artworkURL == nil, let art = active.artworkURL {
                groupsByKey[key]?.artworkURL = art
            }
        }

        // 2. Queued episode downloads
        for queued in queuedDownloads where queued.contentType == .seriesEpisode {
            let key = keyFor(seriesID: queued.seriesID, cleanTitle: queued.cleanTitle)
            if groupsByKey[key] == nil {
                orderedKeys.append(key)
                groupsByKey[key] = DownloadedSeriesGroup(
                    id: key,
                    seriesID: queued.seriesID,
                    title: queued.cleanTitle,
                    artworkURL: queued.artworkURL,
                    downloadedEpisodes: [],
                    activeEpisodes: [],
                    queuedEpisodes: []
                )
            }
            groupsByKey[key]?.queuedEpisodes.append(queued)
            if groupsByKey[key]?.artworkURL == nil, let art = queued.artworkURL {
                groupsByKey[key]?.artworkURL = art
            }
        }

        // 3. Completed episode downloads
        for item in downloadedItems where item.contentType == .seriesEpisode {
            let key = keyFor(seriesID: item.seriesID, cleanTitle: item.cleanTitle)
            if groupsByKey[key] == nil {
                orderedKeys.append(key)
                groupsByKey[key] = DownloadedSeriesGroup(
                    id: key,
                    seriesID: item.seriesID,
                    title: item.cleanTitle,
                    artworkURL: item.artworkURL,
                    downloadedEpisodes: [],
                    activeEpisodes: [],
                    queuedEpisodes: []
                )
            }
            groupsByKey[key]?.downloadedEpisodes.append(item)
            if groupsByKey[key]?.artworkURL == nil, let art = item.artworkURL {
                groupsByKey[key]?.artworkURL = art
            }
        }

        return orderedKeys.compactMap { key in
            guard var group = groupsByKey[key] else { return nil }
            group.downloadedEpisodes.sort { lhs, rhs in
                (lhs.subtitle ?? lhs.id).localizedStandardCompare(rhs.subtitle ?? rhs.id) == .orderedAscending
            }
            return group
        }
    }

    func deleteSeriesGroup(_ group: DownloadedSeriesGroup) {
        for active in group.activeEpisodes {
            cancelDownload(id: active.id)
        }
        for queued in group.queuedEpisodes {
            cancelDownload(id: queued.id)
        }
        for ep in group.downloadedEpisodes {
            deleteDownload(id: ep.id)
        }
    }

    // MARK: - Start / Retry / Cancel / Delete Downloads

    func startMovieDownload(
        movie: XtreamVODStream,
        resolvedExtension: String?,
        credentials: XtreamCredentials,
        qualityLabel: String? = nil,
        compressPreset: String? = nil,
        sizeScaleFactor: Double? = nil,
        customItemID: String? = nil
    ) {
        let preset = preferredQualityPreset
        let resolvedQualityLabel = qualityLabel ?? preset.shortLabel
        let resolvedScale = sizeScaleFactor ?? preset.sizeScaleFactor
        let ext = (resolvedExtension?.isEmpty == false) ? resolvedExtension! : (movie.containerExtension ?? "mkv")
        let itemID = customItemID ?? "movie-\(movie.streamId.value)"
        guard activeDownloads[itemID] == nil, !isDownloaded(itemID) else { return }
        guard let url = credentials.vodStreamURL(streamID: movie.streamId.value, containerExtension: ext) else {
            lastDownloadError = "Invalid download URL for \(movie.cleanName)."
            return
        }

        let active = ActiveDownloadItem(
            id: itemID,
            contentType: .movie,
            title: movie.name,
            subtitle: "Movie • \(resolvedQualityLabel) (\(ext.uppercased()))",
            artworkURL: movie.streamIcon,
            streamID: movie.streamId.value,
            episodeID: nil,
            seriesID: nil,
            containerExtension: ext,
            sourceURLString: url.absoluteString,
            qualityLabel: resolvedQualityLabel,
            compressPreset: compressPreset,
            sizeScaleFactor: resolvedScale,
            progress: 0,
            bytesWritten: 0,
            totalBytes: 0
        )
        enqueueOrStartDownload(active)
    }

    func startEpisodeDownload(
        series: XtreamSeries,
        episode: XtreamEpisode,
        seasonNumber: Int,
        credentials: XtreamCredentials,
        qualityLabel: String? = nil,
        compressPreset: String? = nil,
        sizeScaleFactor: Double? = nil
    ) {
        let preset = preferredQualityPreset
        let resolvedQualityLabel = qualityLabel ?? preset.shortLabel
        let resolvedScale = sizeScaleFactor ?? preset.sizeScaleFactor
        let ext = (episode.containerExtension?.isEmpty == false) ? episode.containerExtension! : "mkv"
        let itemID = "episode-\(episode.episodeId.value)"
        guard activeDownloads[itemID] == nil, !isQueued(itemID), !isDownloaded(itemID) else { return }
        guard let url = credentials.seriesEpisodeURL(episodeID: episode.episodeId.value, containerExtension: ext) else {
            lastDownloadError = "Invalid download URL for episode."
            return
        }

        let epTitle = XtreamTextFormatter.format(episode.title).cleanTitle
        let active = ActiveDownloadItem(
            id: itemID,
            contentType: .seriesEpisode,
            title: series.name,
            subtitle: "S\(seasonNumber):E\(episode.episodeNum.value) • \(epTitle) (\(resolvedQualityLabel))",
            artworkURL: series.cover ?? episode.info?.movieImage,
            streamID: nil,
            episodeID: episode.episodeId.value,
            seriesID: series.seriesId.value,
            containerExtension: ext,
            sourceURLString: url.absoluteString,
            qualityLabel: resolvedQualityLabel,
            compressPreset: compressPreset,
            sizeScaleFactor: resolvedScale,
            progress: 0,
            bytesWritten: 0,
            totalBytes: 0
        )
        enqueueOrStartDownload(active)
    }

    /// Queues all remaining episodes of an entire season in sequential order (E1 -> E2 -> E3...)
    func startSeasonDownload(
        series: XtreamSeries,
        episodes: [XtreamEpisode],
        seasonNumber: Int,
        credentials: XtreamCredentials
    ) {
        let missingCount = episodes.filter { ep in
            let id = "episode-\(ep.episodeId.value)"
            return !isDownloaded(id) && activeDownloads[id] == nil && !isQueued(id)
        }.count
        for ep in episodes {
            startEpisodeDownload(
                series: series,
                episode: ep,
                seasonNumber: seasonNumber,
                credentials: credentials
            )
        }
        if missingCount > 0 {
            NotificationManager.shared.recordSeasonDownloadQueued(
                series: series,
                seasonNumber: seasonNumber,
                episodeCount: missingCount,
                qualityLabel: preferredQualityPreset.shortLabel
            )
        }
    }

    func cancelSeasonDownloads(episodes: [XtreamEpisode]) {
        for ep in episodes {
            let itemID = "episode-\(ep.episodeId.value)"
            queuedDownloads.removeAll { $0.id == itemID }
            // Remove state before cancelling so the cancellation callback is recognised as user-initiated.
            activeDownloads.removeValue(forKey: itemID)
            itemsInHandoff.remove(itemID)
            releaseKeepAlive(for: itemID)
            if let linked = downloadTasks.removeValue(forKey: itemID) {
                linked.task.cancel()
            }
            deletePersistedResumeData(for: itemID)
        }
        advanceQueueIfNeeded()
        persistStateNow()
    }

    func deleteSeasonDownloads(episodes: [XtreamEpisode]) {
        cancelSeasonDownloads(episodes: episodes)
        for ep in episodes {
            let itemID = "episode-\(ep.episodeId.value)"
            deleteDownload(id: itemID)
        }
    }

    private func enqueueOrStartDownload(_ item: ActiveDownloadItem) {
        failedDownloads.removeAll { $0.id == item.id }
        guard activeDownloads[item.id] == nil,
              !isQueued(item.id),
              !isDownloaded(item.id) else { return }

        if hasReattachedTasks && activeDownloads.count < concurrencyLimit {
            beginDownload(active: item)
        } else {
            // Before relaunch re-attachment finishes, park new requests in the queue; the scheduler
            // starts them once system tasks have been reconciled.
            queuedDownloads.append(item)
            persistStateNow()
        }
    }

    private func advanceQueueIfNeeded() {
        guard hasReattachedTasks, lineCredentials != nil else { return }
        while activeDownloads.count < concurrencyLimit, !queuedDownloads.isEmpty {
            let next = queuedDownloads.removeFirst()
            if !isDownloaded(next.id) && activeDownloads[next.id] == nil {
                beginDownload(active: next)
            }
        }
    }

    /// If the user lowers the concurrency setting below the number of running transfers, pause the
    /// least-progressed extras (keeping resume data) and put them back at the front of the queue.
    private func enforceConcurrencyLimit() {
        guard hasReattachedTasks else { return }
        let overflow = activeDownloads.count - concurrencyLimit
        guard overflow > 0 else { return }
        let toPause = activeDownloads.values
            .sorted { $0.progress < $1.progress }
            .prefix(overflow)
        for item in toPause.reversed() {
            pauseActiveDownloadToQueue(item)
        }
    }

    /// Cancels the transfer with `cancel(byProducingResumeData:)`, persists the resume data to disk,
    /// and re-queues the item at the front so it resumes (not restarts) when a slot frees up.
    private func pauseActiveDownloadToQueue(_ item: ActiveDownloadItem) {
        activeDownloads.removeValue(forKey: item.id)
        queuedDownloads.removeAll { $0.id == item.id }
        queuedDownloads.insert(item, at: 0)
        guard let linked = downloadTasks.removeValue(forKey: item.id) else { return }
        releaseKeepAlive(for: item.id)
        let itemID = item.id
        linked.task.cancel(byProducingResumeData: { [weak self] data in
            guard let data else { return }
            self?.savePersistedResumeData(data, for: itemID)
        })
    }

    /// Moves a queued download to the front of the queue (or starts it immediately by pausing/replacing if desired)
    func prioritizeQueuedDownload(id: String) {
        guard let idx = queuedDownloads.firstIndex(where: { $0.id == id }) else { return }
        let item = queuedDownloads.remove(at: idx)
        queuedDownloads.insert(item, at: 0)
        advanceQueueIfNeeded()
        persistStateNow()
    }

    func clearQueue() {
        for item in queuedDownloads {
            deletePersistedResumeData(for: item.id)
        }
        queuedDownloads.removeAll()
        persistStateNow()
    }

    /// Puts every failed download back in the queue (resume data persisted when they failed is reused).
    func retryFailedDownloads() {
        let failed = failedDownloads
        lastDownloadError = nil
        for item in failed { retryFailedDownload(id: item.id) }
    }

    func retryFailedDownload(id: String) {
        guard let idx = failedDownloads.firstIndex(where: { $0.id == id }) else { return }
        var item = failedDownloads.remove(at: idx)
        item.retryCount = 0
        item.statusNote = nil
        if failedDownloads.isEmpty { lastDownloadError = nil }
        enqueueOrStartDownload(item)
        persistStateNow()
    }

    func removeFailedDownload(id: String) {
        failedDownloads.removeAll { $0.id == id }
        if failedDownloads.isEmpty { lastDownloadError = nil }
        deletePersistedResumeData(for: id)
        persistStateNow()
    }

    private func recordFailure(_ item: ActiveDownloadItem, reason: String) {
        var failed = item
        failed.statusNote = reason
        failedDownloads.removeAll { $0.id == item.id }
        failedDownloads.insert(failed, at: 0)
        lastDownloadError = reason
        NotificationManager.shared.recordDownloadFailed(item: item, reason: reason)
    }

    /// Starts a transfer on the in-process session while the app is in the foreground, or on the
    /// background session otherwise. When `resumeData` is nil, previously persisted resume data for
    /// the item (if any) is used so interrupted downloads continue where they left off.
    private func beginDownload(active: ActiveDownloadItem, resumeData explicitResumeData: Data? = nil, clearsFailure: Bool = true) {
        guard downloadTasks[active.id] == nil, !itemsInHandoff.contains(active.id) else {
            activeDownloads[active.id] = active
            return
        }
        failedDownloads.removeAll { $0.id == active.id }
        if clearsFailure {
            lastDownloadError = failedDownloads.first?.statusNote
        }

        let kind = preferredSessionKind
        let targetSession = session(for: kind)
        var item = active
        item.statusNote = nil
        let task: URLSessionDownloadTask
        let resumeData = explicitResumeData ?? consumePersistedResumeData(for: active.id)
        if let resumeData {
            // Progress is kept as-is: the resumed transfer continues from the saved offset.
            task = targetSession.downloadTask(withResumeData: resumeData)
        } else {
            guard let url = active.resolvedSourceURL(using: lineCredentials) else {
                activeDownloads.removeValue(forKey: active.id)
                if lineCredentials == nil {
                    // Saved without the login (after a relaunch): wait for the line to sign in.
                    if !isQueued(active.id) { queuedDownloads.insert(active, at: 0) }
                    persistStateNow()
                    return
                }
                lastDownloadError = "Invalid download URL for \(active.cleanTitle)."
                persistStateNow()
                return
            }
            var request = URLRequest(url: url)
            request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
            task = targetSession.downloadTask(with: request)
            // Fresh transfer from byte 0.
            item.progress = 0
            item.bytesWritten = 0
        }

        // taskDescription is how tasks are re-linked to items after a relaunch (getAllTasks) and
        // how delegate callbacks from either session find their item.
        task.taskDescription = active.id
        activeDownloads[active.id] = item
        downloadTasks[active.id] = LinkedDownloadTask(task: task, kind: kind, startedFromResumeData: resumeData != nil)
        persistStateNow()
        task.resume()
    }

    func cancelDownload(id: String) {
        queuedDownloads.removeAll { $0.id == id }
        // Remove state before cancelling so the cancellation callback is recognised as user-initiated.
        activeDownloads.removeValue(forKey: id)
        itemsInHandoff.remove(id)
        releaseKeepAlive(for: id)
        if let linked = downloadTasks.removeValue(forKey: id) {
            linked.task.cancel()
        }
        deletePersistedResumeData(for: id)
        advanceQueueIfNeeded()
        persistStateNow()
    }

    func deleteDownload(id: String) {
        if let idx = downloadedItems.firstIndex(where: { $0.id == id }) {
            let item = downloadedItems[idx]
            try? FileManager.default.removeItem(at: item.localFileURL)
            downloadedItems.remove(at: idx)
            saveManifest()
        }
    }

    func clearAllDownloads() {
        queuedDownloads.removeAll()
        activeDownloads.removeAll()
        itemsInHandoff.removeAll()
        keptAliveForegroundItems.removeAll()
        endKeepAliveAssertion()
        for linked in downloadTasks.values {
            linked.task.cancel()
        }
        downloadTasks.removeAll()
        deleteAllPersistedResumeData()
        failedDownloads.removeAll()
        lastDownloadError = nil
        for item in downloadedItems {
            try? FileManager.default.removeItem(at: item.localFileURL)
        }
        downloadedItems.removeAll()
        saveManifest()
        persistStateNow()
    }

    /// Returns true if `task` (from the session of `kind`) is the transfer currently linked to `itemID`.
    /// Identity is (session, taskIdentifier) because identifiers are only unique per session.
    /// If no task is linked yet (events arriving before relaunch re-attachment completes), the task is
    /// adopted — unless it is one we cancelled for a session handoff.
    private func isCurrentTask(_ task: URLSessionTask, kind: DownloadSessionKind, for itemID: String) -> Bool {
        let key = DownloadTaskKey(kind: kind, task: task)
        if let linked = downloadTasks[itemID] {
            return linked.key == key
        }
        if handoffCancelledTaskKeys.contains(key) || itemsInHandoff.contains(itemID) {
            return false
        }
        if let downloadTask = task as? URLSessionDownloadTask {
            downloadTasks[itemID] = LinkedDownloadTask(task: downloadTask, kind: kind, startedFromResumeData: true)
        }
        return true
    }

    // MARK: - URLSessionDownloadDelegate (both sessions; called on `delegateQueue`)

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let kind = DownloadSessionKind(session: session)
        let throttleKey = DownloadTaskKey(kind: kind, task: downloadTask)
        let now = ProcessInfo.processInfo.systemUptime
        let isFinalChunk = totalBytesExpectedToWrite > 0 && totalBytesWritten >= totalBytesExpectedToWrite
        if !isFinalChunk, let last = progressThrottleTimes[throttleKey], now - last < Self.progressPublishInterval {
            return
        }
        progressThrottleTimes[throttleKey] = now
        guard let itemID = downloadTask.taskDescription else { return }

        DispatchQueue.main.async { [weak self] in
            self?.applyProgress(
                itemID: itemID,
                task: downloadTask,
                kind: kind,
                totalBytesWritten: totalBytesWritten,
                totalBytesExpectedToWrite: totalBytesExpectedToWrite
            )
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didResumeAtOffset fileOffset: Int64,
        expectedTotalBytes: Int64
    ) {
        // Publish the resumed offset immediately so progress stays continuous across handoffs.
        let kind = DownloadSessionKind(session: session)
        guard let itemID = downloadTask.taskDescription else { return }
        DispatchQueue.main.async { [weak self] in
            self?.applyProgress(
                itemID: itemID,
                task: downloadTask,
                kind: kind,
                totalBytesWritten: fileOffset,
                totalBytesExpectedToWrite: expectedTotalBytes
            )
        }
    }

    /// Main thread.
    private func applyProgress(
        itemID: String,
        task: URLSessionDownloadTask,
        kind: DownloadSessionKind,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard var active = activeDownloads[itemID], isCurrentTask(task, kind: kind, for: itemID) else { return }

        let scale = min(max(active.sizeScaleFactor, 0.1), 1.0)
        let newBytesWritten = Int64(Double(totalBytesWritten) * scale)
        // Resumed transfers must never move progress backwards (e.g. a late/odd counter after a handoff).
        if downloadTasks[itemID]?.startedFromResumeData == true && newBytesWritten < active.bytesWritten {
            return
        }
        active.bytesWritten = newBytesWritten
        active.totalBytes = totalBytesExpectedToWrite > 0 ? Int64(Double(totalBytesExpectedToWrite) * scale) : 0
        if totalBytesExpectedToWrite > 0 {
            active.progress = min(max(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite), 0), 1)
        }
        activeDownloads[itemID] = active
        persistStateThrottled()
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        let kind = DownloadSessionKind(session: session)
        progressThrottleTimes.removeValue(forKey: DownloadTaskKey(kind: kind, task: downloadTask))
        guard let itemID = downloadTask.taskDescription else { return }

        // Capture response metadata here (thread-safe reads) for validation on main.
        let http = downloadTask.response as? HTTPURLResponse
        let statusCode = http?.statusCode
        let mimeType = http?.mimeType?.lowercased()

        // `location` is deleted as soon as this method returns, so move it synchronously right now
        // into a staging file on the same volume; final validation/rename happens on main.
        var stagedURL: URL?
        var stagingError: Error?
        let fm = FileManager.default
        try? fm.createDirectory(at: Self.incomingDirectory, withIntermediateDirectories: true)
        let staged = Self.incomingDirectory.appendingPathComponent("\(UUID().uuidString).part")
        do {
            try fm.moveItem(at: location, to: staged)
            stagedURL = staged
        } catch {
            stagingError = error
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else {
                if let stagedURL { try? FileManager.default.removeItem(at: stagedURL) }
                return
            }
            self.finalizeDownload(
                itemID: itemID,
                task: downloadTask,
                kind: kind,
                stagedURL: stagedURL,
                stagingError: stagingError,
                statusCode: statusCode,
                mimeType: mimeType
            )
        }
    }

    /// Main thread. Validates the staged file, moves it into the downloads library, records it,
    /// fires the "Download complete" notification, then advances the queue.
    private func finalizeDownload(
        itemID: String,
        task: URLSessionDownloadTask,
        kind: DownloadSessionKind,
        stagedURL: URL?,
        stagingError: Error?,
        statusCode: Int?,
        mimeType: String?
    ) {
        // A task we were handing off may have finished just before the cancel landed: its file is
        // complete, so accept it (and drop any replacement transfer below).
        let finishedDuringHandoff = handoffCancelledTaskKeys.contains(DownloadTaskKey(kind: kind, task: task))
        guard let active = activeDownloads[itemID],
              finishedDuringHandoff || isCurrentTask(task, kind: kind, for: itemID) else {
            // Cancelled by the user (or stale) while finishing: discard.
            if let stagedURL { try? FileManager.default.removeItem(at: stagedURL) }
            return
        }

        let safeFileName = "\(active.id).\(active.containerExtension)"
        let destinationURL = Self.downloadsDirectory.appendingPathComponent(safeFileName)

        // A line with no free connection answers 509/884 (or a near-empty body). That isn't a broken
        // download: wait and try again instead of failing it.
        let stagedSize = stagedURL.flatMap { (try? FileManager.default.attributesOfItem(atPath: $0.path))?[.size] as? Int64 } ?? 0
        let lineBusy = statusCode.map(Self.busyStatusCodes.contains) ?? false
            || (stagedURL != nil && stagedSize < 4096 && (statusCode.map { (200..<300).contains($0) } ?? true))
        if lineBusy {
            if let stagedURL { try? FileManager.default.removeItem(at: stagedURL) }
            if waitForFreeConnection(active, task: task, kind: kind) { return }
        }

        // Reject HTTP error responses and text/* bodies (HTML/JSON error pages) instead of saving them as video.
        var rejectionReason: String?
        if let statusCode, !(200..<300).contains(statusCode) {
            rejectionReason = "Server returned HTTP \(statusCode) for \(active.cleanTitle)."
        } else if let mime = mimeType, mime.hasPrefix("text/"), let stagedURL {
            // Guard against misconfigured servers labelling large real video files as text/*
            let tempAttrs = try? FileManager.default.attributesOfItem(atPath: stagedURL.path)
            let tempSize = (tempAttrs?[.size] as? Int64) ?? 0
            if tempSize < 2_000_000 {
                rejectionReason = "Server returned an error page (\(mime)) instead of video for \(active.cleanTitle)."
            }
        }

        if lineBusy {
            recordFailure(active, reason: "Your IPTV line stayed busy, so \(active.cleanTitle) couldn’t download. Close other players using the line, then retry.")
        } else if let rejectionReason {
            if let stagedURL { try? FileManager.default.removeItem(at: stagedURL) }
            recordFailure(active, reason: rejectionReason)
        } else if let stagedURL {
            do {
                if FileManager.default.fileExists(atPath: destinationURL.path) {
                    try FileManager.default.removeItem(at: destinationURL)
                }
                try FileManager.default.moveItem(at: stagedURL, to: destinationURL)

                let attrs = try? FileManager.default.attributesOfItem(atPath: destinationURL.path)
                let rawFileSize = (attrs?[.size] as? Int64) ?? active.bytesWritten

                if rawFileSize < 4096 {
                    try? FileManager.default.removeItem(at: destinationURL)
                    recordFailure(active, reason: "Server returned an empty stream for \(active.cleanTitle).")
                } else {
                    let scale = min(max(active.sizeScaleFactor, 0.1), 1.0)
                    let effectiveSize = max(Int64(Double(rawFileSize) * scale), 4096)
                    let completed = DownloadedMediaItem(
                        id: active.id,
                        contentType: active.contentType,
                        title: active.title,
                        subtitle: active.subtitle,
                        artworkURL: active.artworkURL,
                        streamID: active.streamID,
                        episodeID: active.episodeID,
                        seriesID: active.seriesID,
                        containerExtension: active.containerExtension,
                        localFileName: safeFileName,
                        fileSizeBytes: effectiveSize,
                        downloadedAt: Date()
                    )
                    downloadedItems.removeAll { $0.id == active.id }
                    downloadedItems.insert(completed, at: 0)
                    saveManifest()
                    NotificationManager.shared.recordDownloadCompleted(item: completed, qualityLabel: active.qualityLabel)

                    // Optional hardware re-encode if user chose MP4 720p/1080p storage saver
                    if let preset = active.compressPreset,
                       active.containerExtension.lowercased() == "mp4" {
                        Task {
                            await compressMP4IfPossible(item: completed, presetName: preset)
                        }
                    }
                }
            } catch {
                try? FileManager.default.removeItem(at: stagedURL)
                recordFailure(active, reason: "Failed to save offline file: \(error.localizedDescription)")
            }
        } else {
            recordFailure(active, reason: "Failed to save offline file: \(stagingError?.localizedDescription ?? "unknown error")")
        }

        // Remove the item before cancelling any replacement transfer so its callback is ignored.
        activeDownloads.removeValue(forKey: itemID)
        itemsInHandoff.remove(itemID)
        releaseKeepAlive(for: itemID)
        if let linked = downloadTasks.removeValue(forKey: itemID),
           linked.key != DownloadTaskKey(kind: kind, task: task) {
            linked.task.cancel()
        }
        deletePersistedResumeData(for: itemID)
        advanceQueueIfNeeded()
        persistStateNow()
    }

    private func compressMP4IfPossible(item: DownloadedMediaItem, presetName: String) async {
        let asset = AVURLAsset(url: item.localFileURL)
        guard let export = AVAssetExportSession(asset: asset, presetName: presetName) else { return }
        let tempOutput = Self.downloadsDirectory.appendingPathComponent("\(item.id)-compressed.mp4")
        try? FileManager.default.removeItem(at: tempOutput)
        export.outputURL = tempOutput
        export.outputFileType = .mp4
        export.shouldOptimizeForNetworkUse = true

        await export.export()
        if export.status == .completed,
           let attrs = try? FileManager.default.attributesOfItem(atPath: tempOutput.path),
           let newSize = attrs[.size] as? Int64,
           newSize > 10_000 && newSize < item.fileSizeBytes {
            try? FileManager.default.removeItem(at: item.localFileURL)
            try? FileManager.default.moveItem(at: tempOutput, to: item.localFileURL)
            await MainActor.run {
                if let idx = self.downloadedItems.firstIndex(where: { $0.id == item.id }) {
                    let updated = DownloadedMediaItem(
                        id: item.id,
                        contentType: item.contentType,
                        title: item.title,
                        subtitle: item.subtitle,
                        artworkURL: item.artworkURL,
                        streamID: item.streamID,
                        episodeID: item.episodeID,
                        seriesID: item.seriesID,
                        containerExtension: item.containerExtension,
                        localFileName: item.localFileName,
                        fileSizeBytes: newSize,
                        downloadedAt: item.downloadedAt
                    )
                    self.downloadedItems[idx] = updated
                    self.saveManifest()
                }
            }
        } else {
            try? FileManager.default.removeItem(at: tempOutput)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let kind = DownloadSessionKind(session: session)
        progressThrottleTimes.removeValue(forKey: DownloadTaskKey(kind: kind, task: task))
        let itemID = task.taskDescription
        let nsError = error.map { $0 as NSError }
        let resumeData = nsError?.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        // Present when the system cancelled a background-session transfer (user force-quit the app,
        // background refresh disabled, low resources). Delivered after the next launch recreates the session.
        let backgroundCancelReason = nsError?.userInfo[NSURLErrorBackgroundTaskCancelledReasonKey] as? Int

        // Always hop to main (also on success) so handoff bookkeeping for this task is cleared.
        DispatchQueue.main.async { [weak self] in
            self?.handleTaskCompletion(
                itemID: itemID,
                task: task,
                kind: kind,
                error: nsError,
                resumeData: resumeData,
                backgroundCancelReason: backgroundCancelReason
            )
        }
    }

    /// Main thread.
    private func handleTaskCompletion(
        itemID: String?,
        task: URLSessionTask,
        kind: DownloadSessionKind,
        error: NSError?,
        resumeData: Data?,
        backgroundCancelReason: Int?
    ) {
        // Cancellations we initiated for a session handoff: not a failure, not a user cancel, and the
        // resume data is delivered to completeHandoff via cancel(byProducingResumeData:) instead.
        if handoffCancelledTaskKeys.remove(DownloadTaskKey(kind: kind, task: task)) != nil {
            return
        }
        // Success is fully handled in didFinishDownloadingTo.
        guard let error, let itemID else { return }

        // User-cancelled / paused items were removed from `activeDownloads` before cancelling;
        // stale tasks (already replaced) fail the identity check. Both are ignored.
        guard var active = activeDownloads[itemID], isCurrentTask(task, kind: kind, for: itemID) else { return }
        downloadTasks.removeValue(forKey: itemID)
        releaseKeepAlive(for: itemID)

        // Persist resume data to disk so retries — including after a relaunch — resume instead of restart.
        if let resumeData {
            savePersistedResumeData(resumeData, for: itemID)
        }

        if kind == .background && error.code == NSURLErrorCancelled && backgroundCancelReason != nil {
            // System-initiated cancellation: restart right away without consuming a retry.
            persistStateNow()
            scheduleRestart(itemID: itemID, after: 0)
            return
        }

        // IPTV providers often drop a transfer when the line's connection is taken elsewhere; back off
        // so the provider has time to release it instead of burning every retry within a few seconds.
        if active.retryCount < Self.networkRetryDelays.count {
            let delay = Self.networkRetryDelays[active.retryCount]
            active.retryCount += 1
            active.statusNote = "Connection dropped • retrying in \(Int(delay)) s"
            activeDownloads[itemID] = active
            persistStateNow()
            scheduleRestart(itemID: itemID, after: delay)
            return
        }

        activeDownloads.removeValue(forKey: itemID)
        recordFailure(active, reason: "Download interrupted for \(active.cleanTitle): \(error.localizedDescription)")
        advanceQueueIfNeeded()
        persistStateNow()
    }

    /// Keeps a refused item in its slot and retries it later. Returns false once the retries are used up.
    private func waitForFreeConnection(_ item: ActiveDownloadItem, task: URLSessionDownloadTask, kind: DownloadSessionKind) -> Bool {
        guard item.retryCount < Self.busyRetryLimit else { return false }
        var waiting = item
        waiting.retryCount += 1
        let delay = min(15 * TimeInterval(waiting.retryCount), 120)
        waiting.statusNote = "Waiting for a free connection on your IPTV line • retrying in \(Int(delay)) s"
        activeDownloads[item.id] = waiting
        if let linked = downloadTasks[item.id], linked.key == DownloadTaskKey(kind: kind, task: task) {
            downloadTasks.removeValue(forKey: item.id)
        }
        releaseKeepAlive(for: item.id)
        deletePersistedResumeData(for: item.id) // the refused body isn't part of the video
        persistStateNow()
        scheduleRestart(itemID: item.id, after: delay)
        return true
    }

    private func scheduleRestart(itemID: String, after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            // Skip if cancelled meanwhile, already restarted (e.g. by relaunch re-attachment), or mid-handoff.
            guard let self,
                  let current = self.activeDownloads[itemID],
                  self.downloadTasks[itemID] == nil,
                  !self.itemsInHandoff.contains(itemID) else { return }
            self.beginDownload(active: current)
        }
    }

    // MARK: - Background Session Events

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        // All delegate messages for this launch have been delivered; their main-queue hops were
        // enqueued earlier, so by the time this block runs state is updated. Flush and tell iOS
        // it can snapshot/suspend the app again.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.persistStateNow()
            self.flushPendingWrites()
            let handler = self.backgroundCompletionHandler
            self.backgroundCompletionHandler = nil
            handler?()
        }
    }

    // MARK: - Manifest Persistence

    private func loadManifest() {
        guard let data = try? Data(contentsOf: Self.manifestURL),
              let decoded = try? JSONDecoder().decode([DownloadedMediaItem].self, from: data) else {
            downloadedItems = []
            return
        }
        downloadedItems = decoded.filter { FileManager.default.fileExists(atPath: $0.localFileURL.path) }
        NotificationManager.shared.seedFromExistingDownloads(downloadedItems)
    }

    private func saveManifest() {
        guard let data = try? JSONEncoder().encode(downloadedItems) else { return }
        try? data.write(to: Self.manifestURL, options: .atomic)
    }
}

// MARK: - Series Grouped Offline Download Model

struct DownloadedSeriesGroup: Identifiable {
    let id: String
    let seriesID: Int?
    let title: String
    var artworkURL: String?
    var downloadedEpisodes: [DownloadedMediaItem]
    var activeEpisodes: [ActiveDownloadItem]
    var queuedEpisodes: [ActiveDownloadItem]

    var totalBytes: Int64 {
        downloadedEpisodes.reduce(0) { $0 + $1.fileSizeBytes }
    }

    var formattedTotalSize: String {
        ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
    }

    var totalInFlightCount: Int {
        activeEpisodes.count + queuedEpisodes.count
    }

}

// MARK: - Real In-App & Local Notification Engine

enum AppNotificationCategory: String, Codable, Hashable {
    case downloadComplete
    case seasonQueued
    case downloadError
    case catalogSynced
    case accountStatus

    var iconName: String {
        switch self {
        case .downloadComplete: return "arrow.down.circle.fill"
        case .seasonQueued: return "square.stack.3d.down.right.fill"
        case .downloadError: return "exclamationmark.triangle.fill"
        case .catalogSynced: return "sparkles.tv.fill"
        case .accountStatus: return "checkmark.shield.fill"
        }
    }
}

struct AppNotification: Codable, Identifiable, Hashable {
    let id: String
    let category: AppNotificationCategory
    var title: String
    var message: String
    var artworkURL: String?
    var createdAt: Date
    var isRead: Bool
    var relatedItemID: String?
}

@Observable
final class NotificationManager {
    static let shared = NotificationManager()

    private(set) var notifications: [AppNotification] = []

    private let storageKey = "xtream.appNotifications.v1"
    private let seededDownloadsKey = "xtream.appNotifications.seededDownloads.v1"
    private let maxNotifications = 60

    var unreadCount: Int {
        notifications.filter { !$0.isRead }.count
    }

    private init() {
        loadNotifications()
        requestLocalNotificationPermissionIfNeeded()
    }

    private func requestLocalNotificationPermissionIfNeeded() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    private func postSystemBanner(title: String, body: String, id: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    func markAllAsRead() {
        var changed = false
        for idx in notifications.indices where !notifications[idx].isRead {
            notifications[idx].isRead = true
            changed = true
        }
        if changed {
            saveNotifications()
        }
    }

    func clearAll() {
        notifications.removeAll()
        saveNotifications()
    }

    /// Seeds notifications from already-downloaded files if they don't have a notification entry yet.
    /// Runs only once per install (persisted flag) and respects the 60-item notification cap.
    func seedFromExistingDownloads(_ items: [DownloadedMediaItem]) {
        guard !UserDefaults.standard.bool(forKey: seededDownloadsKey) else { return }
        UserDefaults.standard.set(true, forKey: seededDownloadsKey)

        var added = false
        for item in items {
            let notifID = "dl-complete-\(item.id)"
            if !notifications.contains(where: { $0.id == notifID }) {
                let detail = item.subtitle ?? "Offline Video"
                let notif = AppNotification(
                    id: notifID,
                    category: .downloadComplete,
                    title: "Download Complete • \(item.cleanTitle)",
                    message: "\(detail) • Ready to watch offline (\(item.formattedSize))",
                    artworkURL: item.artworkURL,
                    createdAt: item.downloadedAt,
                    isRead: false,
                    relatedItemID: item.id
                )
                notifications.append(notif)
                added = true
            }
        }
        if added {
            notifications.sort { $0.createdAt > $1.createdAt }
            if notifications.count > maxNotifications {
                notifications = Array(notifications.prefix(maxNotifications))
            }
            saveNotifications()
        }
    }

    func recordDownloadCompleted(item: DownloadedMediaItem, qualityLabel: String) {
        let notifID = "dl-complete-\(item.id)"
        let detail = item.subtitle ?? qualityLabel
        let title = "Download Complete • \(item.cleanTitle)"
        let message = "\(detail) • Ready to watch offline (\(item.formattedSize))"
        let notif = AppNotification(
            id: notifID,
            category: .downloadComplete,
            title: title,
            message: message,
            artworkURL: item.artworkURL,
            createdAt: Date(),
            isRead: false,
            relatedItemID: item.id
        )
        upsertNotification(notif)
        postSystemBanner(title: title, body: message, id: notifID)
    }

    func recordSeasonDownloadQueued(series: XtreamSeries, seasonNumber: Int, episodeCount: Int, qualityLabel: String) {
        let notifID = "season-queue-\(series.seriesId.value)-s\(seasonNumber)"
        let notif = AppNotification(
            id: notifID,
            category: .seasonQueued,
            title: "Downloading Season \(seasonNumber) • \(series.cleanName)",
            message: "Queued \(episodeCount) \(episodeCount == 1 ? "episode" : "episodes") in \(qualityLabel) quality for offline playback.",
            artworkURL: series.cover,
            createdAt: Date(),
            isRead: false,
            relatedItemID: nil
        )
        upsertNotification(notif)
    }

    func recordDownloadFailed(item: ActiveDownloadItem, reason: String) {
        let notifID = "dl-error-\(item.id)"
        let notif = AppNotification(
            id: notifID,
            category: .downloadError,
            title: "Download Interrupted • \(item.cleanTitle)",
            message: reason,
            artworkURL: item.artworkURL,
            createdAt: Date(),
            isRead: false,
            relatedItemID: nil
        )
        upsertNotification(notif)
    }

    func recordCatalogSynced(moviesCount: Int, seriesCount: Int, liveCount: Int, artworkURL: String?) {
        guard moviesCount > 0 || seriesCount > 0 || liveCount > 0 else { return }
        let notifID = "catalog-sync-latest"
        let alreadyRead = notifications.first(where: { $0.id == notifID })?.isRead ?? false
        let notif = AppNotification(
            id: notifID,
            category: .catalogSynced,
            title: "Catalog Auto-Synced",
            message: "\(moviesCount.formatted()) Movies, \(seriesCount.formatted()) Series & \(liveCount.formatted()) Live TV channels indexed.",
            artworkURL: artworkURL,
            createdAt: Date(),
            isRead: alreadyRead,
            relatedItemID: nil
        )
        upsertNotification(notif)
    }

    func recordAccountStatus(lineName: String, status: String, countdownText: String, activeCons: String, maxCons: String) {
        let notifID = "account-status-active"
        let alreadyRead = notifications.first(where: { $0.id == notifID })?.isRead ?? false
        let notif = AppNotification(
            id: notifID,
            category: .accountStatus,
            title: "\(lineName) • Line \(status)",
            message: "Subscription time left: \(countdownText) • Connections: \(activeCons)/\(maxCons) active.",
            artworkURL: nil,
            createdAt: Date(),
            isRead: alreadyRead,
            relatedItemID: nil
        )
        upsertNotification(notif)
    }

    private func upsertNotification(_ notif: AppNotification) {
        DispatchQueue.main.async {
            self.notifications.removeAll { $0.id == notif.id }
            self.notifications.insert(notif, at: 0)
            if self.notifications.count > self.maxNotifications {
                self.notifications = Array(self.notifications.prefix(self.maxNotifications))
            }
            self.saveNotifications()
        }
    }

    private func loadNotifications() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([AppNotification].self, from: data) else {
            notifications = []
            return
        }
        notifications = decoded
    }

    private func saveNotifications() {
        guard let data = try? JSONEncoder().encode(notifications) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }
}

// MARK: - Netflix Download Quality Selector Sheet

struct MovieDownloadQualitySheet: View {
    @Environment(AppState.self) var appState
    private var downloadManager = DownloadManager.shared
    @Environment(\.dismiss) private var dismiss

    let primaryMovie: XtreamVODStream
    let resolvedExtension: String

    @State private var probedSizes: [String: Int64] = [:]
    @State private var isProbing: Bool = true

    /// Finds any alternate quality versions of the same movie across loaded & companion categories (e.g. 4K vs HD vs HEVC)
    private var matchingServerVariants: [XtreamVODStream] {
        appState.findMatchingQualityVariants(for: primaryMovie)
    }

    private var candidates: [DownloadQualityCandidate] {
        guard let creds = appState.credentials else { return [] }
        var result: [DownloadQualityCandidate] = []

        for (index, variant) in matchingServerVariants.enumerated() {
            let ext = (index == 0) ? resolvedExtension : (variant.containerExtension ?? "mkv")
            guard let url = creds.vodStreamURL(streamID: variant.streamId.value, containerExtension: ext) else { continue }
            let qualityTag = variant.qualityBadges.first ?? (index == 0 ? "Original" : "HD")
            let prefix = variant.prefixBadge.map { "\($0) • " } ?? ""

            result.append(
                DownloadQualityCandidate(
                    id: "direct-\(variant.streamId.value)",
                    title: index == 0 ? "Original Quality (\(qualityTag))" : "Alternate Server Stream (\(prefix)\(qualityTag))",
                    subtitle: index == 0
                        ? "Direct \(ext.uppercased()) stream • Maximum server bitrate"
                        : "Native server alternate resolution stream (\(ext.uppercased()))",
                    badge: "\(qualityTag) • \(ext.uppercased())",
                    movie: variant,
                    resolvedExtension: ext,
                    streamURL: url,
                    compressPreset: nil,
                    sizeScaleFactor: 1.0
                )
            )

            if index == 0 {
                result.append(
                    DownloadQualityCandidate(
                        id: "1080p-\(variant.streamId.value)",
                        title: "High Quality (1080p HD)",
                        subtitle: "Balanced 1080p Full HD offline storage (~52% size)",
                        badge: "1080P HD",
                        movie: variant,
                        resolvedExtension: ext,
                        streamURL: url,
                        compressPreset: AVAssetExportPreset1920x1080,
                        sizeScaleFactor: DownloadQualityPreset.high1080p.sizeScaleFactor
                    )
                )
                result.append(
                    DownloadQualityCandidate(
                        id: "720p-\(variant.streamId.value)",
                        title: "Standard / Data Saver (720p)",
                        subtitle: "Compact 720p HD mode for mobile storage (~28% size)",
                        badge: "720P SAVER",
                        movie: variant,
                        resolvedExtension: ext,
                        streamURL: url,
                        compressPreset: AVAssetExportPreset1280x720,
                        sizeScaleFactor: DownloadQualityPreset.standard720p.sizeScaleFactor
                    )
                )
            }
        }
        return result
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color(red: 0.07, green: 0.07, blue: 0.08).ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        // Header Movie Info
                        HStack(spacing: 14) {
                            ArtworkImageView(
                                urlString: primaryMovie.streamIcon,
                                fallbackTitle: primaryMovie.cleanName,
                                fallbackIcon: "film"
                            )
                            .frame(width: 72, height: 102)
                            .clipShape(RoundedRectangle(cornerRadius: 6))

                            VStack(alignment: .leading, spacing: 6) {
                                Text(primaryMovie.cleanName)
                                    .font(.system(size: 18, weight: .bold))
                                    .foregroundStyle(.white)
                                    .lineLimit(2)

                                Text("Select Download Quality & Storage")
                                    .font(.system(size: 13))
                                    .foregroundStyle(.white.opacity(0.65))

                                if isProbing {
                                    HStack(spacing: 6) {
                                        ProgressView()
                                            .scaleEffect(0.75)
                                            .tint(AppTheme.netflixRed)
                                        Text("Scanning companion categories & sizes...")
                                            .font(.system(size: 12))
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 12)

                        // Quality Options
                        VStack(spacing: 10) {
                            ForEach(candidates) { option in
                                Button {
                                    guard let creds = appState.credentials,
                                          let targetMovie = option.movie else { return }
                                    downloadManager.startMovieDownload(
                                        movie: targetMovie,
                                        resolvedExtension: option.resolvedExtension,
                                        credentials: creds,
                                        qualityLabel: option.badge,
                                        compressPreset: option.compressPreset,
                                        sizeScaleFactor: option.sizeScaleFactor,
                                        customItemID: "movie-\(primaryMovie.streamId.value)"
                                    )
                                    dismiss()
                                } label: {
                                    HStack(spacing: 14) {
                                        Image(systemName: "arrow.down.circle.fill")
                                            .font(.system(size: 26))
                                            .foregroundStyle(AppTheme.netflixRed)

                                        VStack(alignment: .leading, spacing: 4) {
                                            HStack(spacing: 8) {
                                                Text(option.title)
                                                    .font(.system(size: 15, weight: .bold))
                                                    .foregroundStyle(.white)
                                                QualityBadgeView(text: option.badge)
                                            }

                                            Text(option.subtitle)
                                                .font(.system(size: 12))
                                                .foregroundStyle(.white.opacity(0.65))
                                                .multilineTextAlignment(.leading)
                                        }

                                        Spacer()

                                        if let bytes = probedSizes[option.id] {
                                            let adjusted = Int64(Double(bytes) * option.sizeScaleFactor)
                                            Text(ByteCountFormatter.string(fromByteCount: adjusted, countStyle: .file))
                                                .font(.system(size: 13, weight: .bold))
                                                .foregroundStyle(AppTheme.matchGreen)
                                        }
                                    }
                                    .padding(14)
                                    .background(AppTheme.elevatedGray, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 16)

                        // Info Note About Xtream Server Streams
                        VStack(alignment: .leading, spacing: 6) {
                            Label("Smart Multi-Resolution & Storage Saver", systemImage: "info.circle")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(.white.opacity(0.8))

                            Text("NucFlix automatically scans companion 4K, 1080p HD, and HEVC categories on your server and scales 1080p / 720p offline storage tiers so every quality tier uses its target storage footprint.")
                                .font(.system(size: 11))
                                .foregroundStyle(.white.opacity(0.55))
                        }
                        .padding(.horizontal, 18)
                        .padding(.top, 4)
                    }
                    .padding(.bottom, 28)
                }
            }
            .navigationTitle("Download Quality")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .foregroundStyle(AppTheme.netflixRed)
                }
            }
            .task {
                await appState.loadCompanionVODCategories(for: primaryMovie)
                await probeAllCandidateSizes()
            }
        }
        .preferredColorScheme(.dark)
        .presentationDetents([.medium, .large])
    }

    private func probeAllCandidateSizes() async {
        isProbing = true
        for option in candidates {
            if let size = await downloadManager.probeRemoteFileSize(url: option.streamURL) {
                probedSizes[option.id] = size
            }
        }
        isProbing = false
    }
}

// MARK: - Inline Netflix Download Quality Selector Bar (Shown Directly Under Download Button)

// MARK: - App Delegate (Background URLSession Relaunch Handling)

/// Wired into SwiftUI via `@UIApplicationDelegateAdaptor` in `NucFlixApp`.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Recreate the background download session early so finished/in-flight transfers re-attach.
        _ = DownloadManager.shared
        return true
    }

    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        guard identifier == DownloadManager.backgroundSessionIdentifier else {
            completionHandler()
            return
        }
        let manager = DownloadManager.shared
        manager.backgroundCompletionHandler = completionHandler
        manager.ensureBackgroundSessionActive()
    }
}
