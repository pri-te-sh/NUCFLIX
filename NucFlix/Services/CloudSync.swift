import Foundation
import UIKit
import FirebaseFirestore

/// Keeps one profile's favorites and watch progress for the active line in sync with Firestore
/// (users/{uid}/profiles/{profileId}/favorites|progress, keyed "<lineId>:<kind>:<id>").
/// Remote changes — e.g. from the Fire TV — flow into AppState live; local changes are written back,
/// with playback progress throttled to one write per title every ~20 s.
@MainActor
final class CloudSync {
    struct Doc {
        let key: String
        let data: [String: Any]
    }

    let lineID: String
    private weak var appState: AppState?
    private let profileRef: DocumentReference
    private let device = UIDevice.current.name
    private var listeners: [ListenerRegistration] = []
    private var pending: [String: WatchHistoryEntry] = [:]
    private var lastWrite: [String: Date] = [:]
    private var flushTask: Task<Void, Never>?
    private var backgroundObserver: NSObjectProtocol?

    private static let progressInterval: TimeInterval = 20

    init(appState: AppState, uid: String, profileID: String, lineID: String) {
        self.appState = appState
        self.lineID = lineID
        self.profileRef = Firestore.firestore().collection("users").document(uid).collection("profiles").document(profileID)
    }

    func start() {
        listeners.append(profileRef.collection("favorites").addSnapshotListener { [weak self] snap, _ in
            Task { @MainActor in
                guard let self, let snap else { return }
                self.applyFavorites(snap.documents)
            }
        })
        listeners.append(profileRef.collection("progress").order(by: "updatedAt", descending: true).limit(to: 120)
            .addSnapshotListener { [weak self] snap, _ in
                Task { @MainActor in
                    guard let self, let snap else { return }
                    self.applyProgress(snap.documents)
                }
            })
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.flush() }
        }
    }

    func stop() {
        flush()
        listeners.forEach { $0.remove() }
        listeners = []
        flushTask?.cancel()
        if let backgroundObserver { NotificationCenter.default.removeObserver(backgroundObserver) }
        backgroundObserver = nil
    }

    // MARK: Remote -> local

    private func applyFavorites(_ docs: [QueryDocumentSnapshot]) {
        guard let appState else { return }
        var live: [(Date, XtreamLiveStream)] = []
        var movies: [(Date, XtreamVODStream)] = []
        var series: [(Date, XtreamSeries)] = []
        for doc in docs {
            let d = doc.data(with: .estimate)
            guard d["lineId"] as? String == lineID, let kind = d["kind"] as? String else { continue }
            let id = (d["id"] as? Int) ?? Int(d["id"] as? String ?? "") ?? 0
            let title = d["title"] as? String ?? ""
            let art = d["artwork"] as? String
            let added = (d["addedAt"] as? Timestamp)?.dateValue() ?? .distantPast
            switch kind {
            case "movie":
                if let m = appState.movieByID(id) ?? Self.decode(XtreamVODStream.self, [
                    "stream_id": id, "name": title, "stream_icon": art, "container_extension": d["ext"],
                    "category_id": d["categoryId"]]) { movies.append((added, m)) }
            case "series":
                if let s = appState.seriesByID(id) ?? Self.decode(XtreamSeries.self, [
                    "series_id": id, "name": title, "cover": art, "category_id": d["categoryId"]]) { series.append((added, s)) }
            case "live":
                if let c = Self.decode(XtreamLiveStream.self, [
                    "stream_id": id, "name": title, "stream_icon": art, "category_id": d["categoryId"]]) { live.append((added, c)) }
            default:
                break
            }
        }
        appState.applyCloudFavorites(
            live: live.sorted { $0.0 > $1.0 }.map(\.1),
            movies: movies.sorted { $0.0 > $1.0 }.map(\.1),
            series: series.sorted { $0.0 > $1.0 }.map(\.1)
        )
    }

    private func applyProgress(_ docs: [QueryDocumentSnapshot]) {
        guard let appState else { return }
        var byID: [String: WatchHistoryEntry] = [:]
        for doc in docs {
            if let entry = Self.entry(from: doc.data(with: .estimate), lineID: lineID) { byID[entry.id] = entry }
        }
        // Local positions not written yet are newer than what the server has.
        for entry in pending.values { byID[entry.id] = entry }
        appState.applyCloudHistory(byID.values.sorted { $0.lastWatchedAt > $1.lastWatchedAt })
    }

    // MARK: Local -> remote

    func setFavorite(_ on: Bool, kind: String, id: Int, title: String, artwork: String?, ext: String? = nil, categoryId: String? = nil) {
        let ref = profileRef.collection("favorites").document("\(lineID):\(kind):\(id)")
        if on {
            ref.setData(Self.favoriteData(lineID: lineID, kind: kind, id: id, title: title, artwork: artwork, ext: ext, categoryId: categoryId))
        } else {
            ref.delete()
        }
    }

    func saveProgress(_ entry: WatchHistoryEntry) {
        pending[entry.id] = entry
        let due = Date().timeIntervalSince(lastWrite[entry.id] ?? .distantPast) >= Self.progressInterval
        if due {
            write(entry.id)
        } else if flushTask == nil {
            flushTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(Self.progressInterval * 1_000_000_000))
                self?.flushTask = nil
                self?.flush()
            }
        }
    }

    /// Writes every position not yet saved (on pause, leaving the player, going to the background).
    func flush() {
        for id in Array(pending.keys) { write(id) }
    }

    private func write(_ entryID: String) {
        guard let entry = pending.removeValue(forKey: entryID),
              let doc = Self.progressDocument(lineID: lineID, entry: entry, device: device) else { return }
        lastWrite[entryID] = Date()
        profileRef.collection("progress").document(doc.key).setData(doc.data)
    }

    func clearProgress(_ entries: [WatchHistoryEntry]) {
        pending.removeAll()
        let batch = Firestore.firestore().batch()
        entries.compactMap { Self.contentKey(lineID: lineID, entry: $0) }
            .forEach { batch.deleteDocument(profileRef.collection("progress").document($0)) }
        batch.commit()
    }

    func saveAutoplay(_ on: Bool) {
        profileRef.setData(["prefs": ["autoplayNext": on], "updatedAt": FieldValue.serverTimestamp()], merge: true)
    }

    // MARK: Document shapes

    static func favoriteData(lineID: String, kind: String, id: Int, title: String, artwork: String?,
                             ext: String? = nil, categoryId: String? = nil) -> [String: Any] {
        var data: [String: Any] = [
            "lineId": lineID, "kind": kind, "id": id, "title": clip(title.isEmpty ? "Untitled" : title, 300),
            "addedAt": FieldValue.serverTimestamp()
        ]
        if let artwork, !artwork.isEmpty, artwork.count <= 1000 { data["artwork"] = artwork }
        if let ext, !ext.isEmpty { data["ext"] = clip(ext, 10) }
        if let categoryId, !categoryId.isEmpty { data["categoryId"] = clip(categoryId, 40) }
        return data
    }

    private static func kind(_ type: MediaContentType) -> String {
        switch type {
        case .movie: return "movie"
        case .seriesEpisode: return "episode"
        case .live: return "live"
        }
    }

    static func contentKey(lineID: String, entry: WatchHistoryEntry) -> String? {
        let id = entry.contentType == .seriesEpisode ? entry.episodeID : entry.streamID.map(String.init)
        guard let id, !id.isEmpty else { return nil }
        return "\(lineID):\(kind(entry.contentType)):\(id)"
    }

    static func progressDocument(lineID: String, entry: WatchHistoryEntry, device: String) -> Doc? {
        guard let key = contentKey(lineID: lineID, entry: entry) else { return nil }
        var data: [String: Any] = [
            "lineId": lineID, "kind": kind(entry.contentType),
            "title": clip(entry.title.isEmpty ? "Untitled" : entry.title, 300),
            "position": max(0, entry.positionSeconds.isFinite ? entry.positionSeconds : 0),
            "duration": max(0, entry.durationSeconds.isFinite ? entry.durationSeconds : 0),
            "updatedAt": FieldValue.serverTimestamp(), "device": clip(device, 80)
        ]
        if let v = entry.streamID { data["streamId"] = v }
        if let v = entry.seriesID { data["seriesId"] = v }
        if let v = entry.episodeID { data["episodeId"] = v }
        if let v = entry.subtitle, !v.isEmpty { data["subtitle"] = clip(v, 300) }
        if let v = entry.artworkURL, !v.isEmpty, v.count <= 1000 { data["artwork"] = v }
        if let v = entry.containerExtension, !v.isEmpty { data["ext"] = clip(v, 10) }
        return Doc(key: key, data: data)
    }

    static func entry(from d: [String: Any], lineID: String) -> WatchHistoryEntry? {
        guard d["lineId"] as? String == lineID, let kind = d["kind"] as? String else { return nil }
        let streamID = d["streamId"] as? Int
        let episodeID = d["episodeId"] as? String
        let type: MediaContentType
        let id: String
        switch kind {
        case "movie": guard let s = streamID else { return nil }; type = .movie; id = "movie-\(s)"
        case "live": guard let s = streamID else { return nil }; type = .live; id = "live-\(s)"
        case "episode": guard let e = episodeID else { return nil }; type = .seriesEpisode; id = "episode-\(e)"
        default: return nil
        }
        return WatchHistoryEntry(
            id: id, contentType: type, title: d["title"] as? String ?? "", subtitle: d["subtitle"] as? String,
            artworkURL: d["artwork"] as? String, streamID: streamID, episodeID: episodeID, seriesID: d["seriesId"] as? Int,
            containerExtension: d["ext"] as? String,
            positionSeconds: (d["position"] as? NSNumber)?.doubleValue ?? 0,
            durationSeconds: (d["duration"] as? NSNumber)?.doubleValue ?? 0,
            lastWatchedAt: (d["updatedAt"] as? Timestamp)?.dateValue() ?? Date()
        )
    }

    private static func clip(_ s: String, _ max: Int) -> String {
        s.count <= max ? s : String(s.prefix(max))
    }

    /// Builds a catalog model from the few fields a favorite stores (used until the full catalog has loaded).
    private static func decode<T: Decodable>(_ type: T.Type, _ fields: [String: Any?]) -> T? {
        guard let data = try? JSONSerialization.data(withJSONObject: fields.compactMapValues { $0 }) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}
