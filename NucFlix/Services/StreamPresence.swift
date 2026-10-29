import Foundation
import UIKit
import FirebaseAuth
import FirebaseFirestore

/// Who is streaming from the IPTV line right now, across the household (users/{uid}/devices/{deviceId}).
///
/// Every device marks `nowPlaying` while its player pulls a stream from the line and refreshes `lastSeen`
/// every minute; a device that hasn't checked in for a few minutes (crashed, unplugged) no longer counts.
/// Lines often allow a single connection, so `DownloadManager` gives downloads only the connections
/// left over: they pause while anyone watches and pick up again when everyone stops.
@MainActor
final class StreamPresence {
    static let shared = StreamPresence()

    private static let heartbeat: TimeInterval = 60
    private static let freshFor: TimeInterval = 150
    private static let lineKey = "nucflix.stream.lineID"
    private static let deviceKey = "nucflix.stream.deviceID"

    /// This install's document id (the owner's phones share one uid, so the uid can't be the id).
    let deviceID: String
    private let db = Firestore.firestore()
    private var uid: String?
    private var lineID: String? = UserDefaults.standard.string(forKey: lineKey)
    private var listener: ListenerRegistration?
    private var others: [Watcher] = []
    private var streamingHere: PlaybackItem?
    private var heartbeatTimer: Timer?
    private var expiryTimer: Timer?

    private struct Watcher {
        let name: String
        let lineID: String
        let lastSeen: Date
    }

    private init() {
        if let saved = UserDefaults.standard.string(forKey: Self.deviceKey) {
            deviceID = saved
        } else {
            deviceID = "ios-" + (UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString)
            UserDefaults.standard.set(deviceID, forKey: Self.deviceKey)
        }
    }

    /// Hooks the background check into the download manager. Call once at launch: the system can wake the
    /// app for download events before any screen (or `AppState`) exists.
    func install() {
        DownloadManager.shared.streamCheck = { await StreamPresence.shared.check() }
    }

    /// Follows the household's devices for this line (called when a profile + line become active).
    func start(uid: String, lineID: String) {
        guard self.uid != uid || self.lineID != lineID || listener == nil else { return }
        stop()
        self.uid = uid
        self.lineID = lineID
        UserDefaults.standard.set(lineID, forKey: Self.lineKey)
        listener = devices(uid).addSnapshotListener { [weak self] snap, _ in
            Task { @MainActor in
                guard let self, self.uid == uid, let snap else { return }
                self.others = snap.documents.compactMap { self.watcher($0) }
                self.publish()
            }
        }
        // Heartbeats stop when a device dies; re-count now and then so it drops out.
        expiryTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            Task { @MainActor in StreamPresence.shared.publish() }
        }
    }

    func stop() {
        setStreaming(nil)
        listener?.remove()
        listener = nil
        expiryTimer?.invalidate()
        expiryTimer = nil
        others = []
        uid = nil
        publish()
    }

    /// The player on this phone started (item) or stopped (nil) streaming from the line. Playing a
    /// downloaded file doesn't count.
    func setStreaming(_ item: PlaybackItem?) {
        let changed = streamingHere?.id != item?.id
        streamingHere = item
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        if item != nil {
            heartbeatTimer = Timer.scheduledTimer(withTimeInterval: Self.heartbeat, repeats: true) { _ in
                Task { @MainActor in StreamPresence.shared.writeOwnDocument() }
            }
        }
        if changed {
            writeOwnDocument()
            publish()
        }
    }

    /// A fresh count from the server (for background wake-ups). Never blocks downloads on failure.
    func check() async -> (count: Int, names: [String]) {
        var count = streamingHere == nil ? 0 : 1
        var names = streamingHere == nil ? [] : [UIDevice.current.name]
        guard let uid = uid ?? Self.ownerUID, let lineID else { return (count, names) }
        let ref = devices(uid)
        let docs: [QueryDocumentSnapshot]? = await withTaskGroup(of: [QueryDocumentSnapshot]?.self) { group in
            group.addTask { try? await ref.getDocuments(source: .server).documents }
            group.addTask {
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        for w in (docs ?? []).compactMap({ watcher($0) }) where w.lineID == lineID && isFresh(w) {
            count += 1
            names.append(w.name)
        }
        return (count, names)
    }

    // MARK: Internals

    private static var ownerUID: String? {
        guard let user = Auth.auth().currentUser, !user.isAnonymous else { return nil }
        return user.uid
    }

    private func devices(_ uid: String) -> CollectionReference {
        db.collection("users").document(uid).collection("devices")
    }

    private func watcher(_ doc: QueryDocumentSnapshot) -> Watcher? {
        guard doc.documentID != deviceID else { return nil } // this phone counts through `streamingHere`
        let d = doc.data(with: .estimate)
        guard let playing = d["nowPlaying"] as? [String: Any], let line = playing["lineId"] as? String,
              let seen = (d["lastSeen"] as? Timestamp)?.dateValue() else { return nil }
        return Watcher(name: d["name"] as? String ?? "Another device", lineID: line, lastSeen: seen)
    }

    private func isFresh(_ w: Watcher) -> Bool {
        Date().timeIntervalSince(w.lastSeen) < Self.freshFor
    }

    private func publish() {
        var names = streamingHere == nil ? [] : [UIDevice.current.name]
        if let lineID {
            names += others.filter { $0.lineID == lineID && isFresh($0) }.map(\.name)
        }
        DownloadManager.shared.setStreamsInUse(names.count, deviceNames: names)
    }

    private func writeOwnDocument() {
        guard let uid = uid ?? Self.ownerUID else { return }
        var playing: Any = NSNull()
        if let item = streamingHere, let lineID {
            playing = ["lineId": lineID, "kind": Self.kind(item.contentType), "title": String(item.title.prefix(200))]
        }
        devices(uid).document(deviceID).setData([
            "name": String(UIDevice.current.name.prefix(80)), "platform": "ios",
            "lastSeen": FieldValue.serverTimestamp(), "nowPlaying": playing
        ])
    }

    private static func kind(_ type: MediaContentType) -> String {
        switch type {
        case .movie: return "movie"
        case .seriesEpisode: return "episode"
        case .live: return "live"
        }
    }
}
