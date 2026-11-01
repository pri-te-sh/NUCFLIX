import Foundation
import UIKit
import AVFoundation
import CoreImage
import MobileVLCKit
import FirebaseAuth
import FirebaseFirestore
import FirebaseFunctions

/// NucFlix "smart" features: frame checks for credits / intros / dead channels, AI category tags and
/// natural-language search. The AI itself runs in Cloud Functions (Ollama Cloud: Clef decisions, Gemma 4);
/// nothing here ever blocks playback — every call can fail and the app carries on as before.
@MainActor
final class SmartAI {
    static let shared = SmartAI()
    static let region = "us-central1"

    /// Set when the household is out of AI budget or the service refuses us; reset on the next sign-in.
    private(set) var disabled = false
    private let db = Firestore.firestore()

    private var uid: String? {
        guard let user = Auth.auth().currentUser, !user.isAnonymous else { return nil }
        return user.uid
    }

    func reset() {
        disabled = false
        searchCache = [:]
    }

    private func call(_ name: String, _ data: [String: Any]) async -> [String: Any]? {
        guard !disabled, uid != nil else { return nil }
        let callable = Functions.functions(region: Self.region).httpsCallable(name)
        callable.timeoutInterval = 30
        do {
            return try await callable.call(data).data as? [String: Any]
        } catch {
            let ns = error as NSError
            if ns.domain == FunctionsErrorDomain, let code = FunctionsErrorCode(rawValue: ns.code),
               [.resourceExhausted, .permissionDenied, .unauthenticated].contains(code) {
                disabled = true
            }
            print("ai \(name): \(ns.localizedDescription)")
            return nil
        }
    }

    // MARK: - Frame checks

    struct FrameVerdict {
        let label: String
        let confidence: Double
        let probabilities: [String: Double]

        func p(_ label: String) -> Double { probabilities[label] ?? 0 }
    }

    /// Clef's verdict on one or two frames (task: credits, intro or live).
    func frameCheck(task: String, images: [Data], title: String?) async -> FrameVerdict? {
        var data: [String: Any] = ["task": task, "images": images.map { $0.base64EncodedString() }]
        if let title, !title.isEmpty { data["title"] = String(title.prefix(200)) }
        guard let res = await call("frameCheck", data), let label = res["label"] as? String else { return nil }
        let probs = (res["probabilities"] as? [String: Any] ?? [:]).compactMapValues { ($0 as? NSNumber)?.doubleValue }
        return FrameVerdict(label: label, confidence: (res["confidence"] as? NSNumber)?.doubleValue ?? 0, probabilities: probs)
    }

    /// A ~512 px wide JPEG of a decoded video frame.
    nonisolated static func jpeg(from pixelBuffer: CVPixelBuffer, width: CGFloat = 512) -> Data? {
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        let scale = width / max(image.extent.width, 1)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cg = ciContext.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cg).jpegData(compressionQuality: 0.72)
    }

    nonisolated static func jpeg(from image: UIImage, width: CGFloat = 512) -> Data? {
        let size = CGSize(width: width, height: (width * image.size.height / max(image.size.width, 1)).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format)
            .image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
            .jpegData(compressionQuality: 0.72)
    }

    nonisolated private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    /// VLC writes snapshots to disk asynchronously; waits up to ~3 s for the file.
    static func snapshot(_ player: VLCMediaPlayer, width: Int32 = 512) async -> Data? {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("nucflix-frame-\(UUID().uuidString).png").path
        player.saveVideoSnapshot(at: path, withWidth: width, andHeight: 0)
        defer { try? FileManager.default.removeItem(atPath: path) }
        var lastSize = -1
        for _ in 0..<30 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
            if size > 0 && size == lastSize, let image = UIImage(contentsOfFile: path) {
                return jpeg(from: image, width: CGFloat(width))
            }
            lastSize = size
        }
        return nil
    }

    // MARK: - X-Ray (the xray function: who's on screen by face matching against the TMDB cast, trivia, actor pages)

    struct XRayPerson: Identifiable, Hashable {
        let id: Int
        let name: String
        let character: String
        let photo: String
    }

    struct XRayTitle {
        let type: String
        let id: Int
        let name: String
        let year: String
        let hasTrivia: Bool
    }

    /// `scene` is nil when the frame couldn't be looked at; `faces` counts the faces found in it, recognised or not.
    struct XRayScene {
        let title: XRayTitle?
        let scene: [XRayPerson]?
        let faces: Int
        let cast: [XRayPerson]
        var found: Bool { title != nil }
    }

    struct XRayCredit: Identifiable, Hashable {
        let id = UUID()
        let title: String
        let year: String
        let character: String
        let poster: String
    }

    struct XRayPersonDetail {
        let name: String
        let bio: String
        let born: String
        let died: String
        let place: String
        let photo: String
        let credits: [XRayCredit]
    }

    private static func people(_ v: Any?) -> [XRayPerson] {
        (v as? [[String: Any]] ?? []).compactMap { p in
            guard let id = (p["id"] as? NSNumber)?.intValue else { return nil }
            return XRayPerson(id: id, name: p["name"] as? String ?? "", character: p["character"] as? String ?? "", photo: p["photo"] as? String ?? "")
        }
    }

    /// Who's in the frame (a ~768 px JPEG) of a movie or episode. `info` carries kind, title, year, tmdbId,
    /// season and episode (see the function). Returns nil when X-Ray couldn't answer at all.
    func xrayScene(info: [String: Any], position: Double, frame: Data?) async -> XRayScene? {
        var data = info
        data["position"] = max(0, position)
        if let frame { data["image"] = frame.base64EncodedString() }
        guard let r = await call("xray", data) else { return nil }
        guard r["found"] as? Bool == true, let t = r["title"] as? [String: Any] else {
            return XRayScene(title: nil, scene: nil, faces: 0, cast: [])
        }
        let title = XRayTitle(type: t["type"] as? String ?? "movie", id: (t["id"] as? NSNumber)?.intValue ?? 0,
                              name: t["name"] as? String ?? "", year: t["year"] as? String ?? "", hasTrivia: t["trivia"] as? Bool ?? false)
        return XRayScene(title: title, scene: r["scene"] is NSNull || r["scene"] == nil ? nil : Self.people(r["scene"]),
                         faces: (r["faces"] as? NSNumber)?.intValue ?? 0, cast: Self.people(r["cast"]))
    }

    func xrayPerson(id: Int) async -> XRayPersonDetail? {
        guard let r = await call("xray", ["action": "person", "personId": id]) else { return nil }
        let credits = (r["credits"] as? [[String: Any]] ?? []).map {
            XRayCredit(title: $0["title"] as? String ?? "", year: $0["year"] as? String ?? "",
                       character: $0["character"] as? String ?? "", poster: $0["poster"] as? String ?? "")
        }
        return XRayPersonDetail(name: r["name"] as? String ?? "", bio: r["bio"] as? String ?? "", born: r["born"] as? String ?? "",
                                died: r["died"] as? String ?? "", place: r["place"] as? String ?? "", photo: r["photo"] as? String ?? "",
                                credits: credits)
    }

    /// A few behind-the-scenes facts from the title's Wikipedia article (empty when there are none).
    func xrayTrivia(type: String, id: Int) async -> [String] {
        let r = await call("xray", ["action": "trivia", "type": type, "id": id])
        return r?["facts"] as? [String] ?? []
    }

    // MARK: - Credits / intro markers (users/{uid}/markers, shared by the household)

    struct ContentMarker {
        var creditsAt: Double?
        var introStart: Double?
        var introEnd: Double?
        var duration: Double?
    }

    func marker(lineID: String, kind: String, id: String) async -> ContentMarker {
        guard let uid else { return ContentMarker() }
        let ref = db.collection("users").document(uid).collection("markers").document("\(lineID):\(kind):\(id)")
        guard let d = try? await ref.getDocument().data() else { return ContentMarker() }
        let num = { (k: String) in (d[k] as? NSNumber)?.doubleValue }
        return ContentMarker(creditsAt: num("creditsAt"), introStart: num("introStart"), introEnd: num("introEnd"), duration: num("duration"))
    }

    func saveMarker(lineID: String, kind: String, id: String, duration: Double, fields: [String: Double]) {
        guard let uid, duration.isFinite, duration > 0 else { return }
        var doc: [String: Any] = ["lineId": lineID, "kind": kind, "source": "ai", "updatedAt": FieldValue.serverTimestamp(),
                                  "duration": (duration * 10).rounded() / 10]
        for (k, v) in fields where v.isFinite { doc[k] = (v * 10).rounded() / 10 }
        db.collection("users").document(uid).collection("markers").document("\(lineID):\(kind):\(id)")
            .setData(doc, merge: true) { error in
                if let error { print("marker: \(error.localizedDescription)") }
            }
    }

    // MARK: - Category tags (users/{uid}/lineTags/{lineId}, written by the classifyCategories function)

    struct CategoryTag: Equatable {
        let kids: Double
        let adult: Double
        let lang: String?
        let genre: String?
    }

    private(set) var tags: [String: CategoryTag] = [:]
    private var tagsLineID: String?
    private var tagsListener: ListenerRegistration?
    private var tagsCategories: [(kind: String, cats: [XtreamCategory])] = []
    private var fillingTags = false

    func tag(_ kind: String, _ categoryID: String?) -> CategoryTag? {
        guard let categoryID, !categoryID.isEmpty else { return nil }
        return tags["\(kind):\(categoryID)"]
    }

    /// Follows the line's tags and fills in categories that don't have any yet, in the background.
    func startTags(lineID: String, categories: [(kind: String, cats: [XtreamCategory])], onChange: @escaping () -> Void) {
        tagsCategories = categories
        if tagsLineID == lineID, tagsListener != nil {
            fillTags(lineID: lineID)
            return
        }
        stopTags()
        guard let uid else { return }
        tagsLineID = lineID
        tagsListener = db.collection("users").document(uid).collection("lineTags").document(lineID)
            .addSnapshotListener { [weak self] snap, _ in
                Task { @MainActor in
                    guard let self, self.tagsLineID == lineID else { return }
                    let cats = snap?.data()?["cats"] as? [String: Any] ?? [:]
                    let parsed: [String: CategoryTag] = cats.compactMapValues { raw in
                        guard let t = raw as? [String: Any] else { return nil }
                        return CategoryTag(kids: (t["kids"] as? NSNumber)?.doubleValue ?? 0.5,
                                           adult: (t["adult"] as? NSNumber)?.doubleValue ?? 0,
                                           lang: t["lang"] as? String, genre: t["genre"] as? String)
                    }
                    if parsed != self.tags {
                        self.tags = parsed
                        onChange()
                    }
                    self.fillTags(lineID: lineID)
                }
            }
    }

    func stopTags() {
        tagsListener?.remove()
        tagsListener = nil
        tagsLineID = nil
        tags = [:]
    }

    private func fillTags(lineID: String) {
        guard !fillingTags, !disabled else { return }
        var todo: [[String: String]] = []
        for (kind, cats) in tagsCategories {
            for c in cats where tags["\(kind):\(c.id)"] == nil && !c.id.isEmpty && !c.categoryName.isEmpty {
                todo.append(["id": c.id, "name": String(c.categoryName.prefix(120)), "kind": kind])
            }
        }
        guard !todo.isEmpty else { return }
        fillingTags = true
        Task { @MainActor in
            defer { fillingTags = false }
            for start in stride(from: 0, to: todo.count, by: 16) {
                guard tagsLineID == lineID, !disabled else { return }
                let batch = Array(todo[start..<min(start + 16, todo.count)])
                guard await call("classifyCategories", ["lineId": lineID, "categories": batch]) != nil else { return }
                try? await Task.sleep(nanoseconds: 1_500_000_000) // gentle: one batch every couple of seconds
            }
        }
    }

    // MARK: - Kids profiles

    /// Deterministic kids rules, the same as the Fire TV app's. Layer 1: a category must not look mature, and must
    /// look made for children or be judged kids-safe by the AI tags (untagged ones stay hidden). Layer 2: a title
    /// must not be flagged adult or carry mature words / genres. Layer 3 is the AI title score below.
    enum KidsRules {
        nonisolated static let blockCategory = #"\b(adults?|xxx|porn|erotic|nsfw|uncensored|nude|sexy|horror|terror|slasher|gore|thriller|crime|war|mature|after dark|late night|ppv|ufc|wwe|mma|boxing)\b|18\s?\+"#
        nonisolated static let allowCategory = #"\b(kids?|children'?s?|cartoons?|junior|jr|toddlers?|pre-?school|bab(y|ies)|nursery|family|nickelodeon|nick|cbeebies|boomerang|pogo)\b"#
        nonisolated static let blockTitle = #"\b(xxx|porn|erotic|nsfw|uncensored|nude|sexy|horror|slasher|gore|adult|for adults)\b|18\s?\+"#
        nonisolated static let blockGenre = #"\b(horror|thriller|crime|war|erotic|adult)\b"#
        nonisolated static let badGenres: Set<String> = ["adult", "horror", "thriller", "crime"]

        nonisolated static func matches(_ text: String, _ pattern: String) -> Bool {
            text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
        }

        nonisolated static func categoryOK(name: String, tag: CategoryTag?) -> Bool {
            if matches(name, blockCategory) { return false }
            if let tag, tag.adult > 0.3 || badGenres.contains(tag.genre ?? "") { return false }
            return matches(name, allowCategory) || (tag?.kids ?? 0) >= 0.6
        }

        nonisolated static func titleOK(name: String, isAdult: Bool, genre: String?) -> Bool {
            !isAdult && !matches(name, blockTitle) && !(genre.map { matches($0, blockGenre) } ?? false)
        }
    }

    // Kids title scores (users/{uid}/kidsTitles/{lineId}, written by the kidsTitles function): 0-1, how suitable a
    // title is for a child under 12. Kids profiles show only titles scored at least `kidsMinimum`.
    nonisolated static let kidsMinimum = 0.6
    /// The scores live in `kidsShards` documents per line, `{lineId}_{id % kidsShards}` (see the function).
    nonisolated static let kidsShards = 8
    private(set) var kidsScores: [String: Double] = [:]
    private var kidsShardScores: [Int: [String: Double]] = [:]
    private var kidsLineID: String?
    private var kidsListeners: [ListenerRegistration] = []
    private(set) var fillingKids = false

    func kidsScore(_ kind: String, _ id: Int) -> Double? { kidsScores["\(kind):\(id)"] }

    func startKids(lineID: String, onChange: @escaping () -> Void) {
        if kidsLineID == lineID, !kidsListeners.isEmpty { return }
        stopKids()
        guard let uid else { return }
        kidsLineID = lineID
        let col = db.collection("users").document(uid).collection("kidsTitles")
        for shard in 0..<Self.kidsShards {
            kidsListeners.append(col.document("\(lineID)_\(shard)").addSnapshotListener { [weak self] snap, _ in
                Task { @MainActor in
                    guard let self, self.kidsLineID == lineID else { return }
                    let raw = snap?.data()?["titles"] as? [String: Any] ?? [:]
                    let parsed = raw.compactMapValues { ($0 as? NSNumber)?.doubleValue }
                    guard parsed != self.kidsShardScores[shard] else { return }
                    self.kidsShardScores[shard] = parsed
                    self.kidsScores = self.kidsShardScores.values.reduce(into: [:]) { $0.merge($1) { _, new in new } }
                    onChange()
                }
            })
        }
    }

    func stopKids() {
        kidsListeners.forEach { $0.remove() }
        kidsListeners = []
        kidsLineID = nil
        kidsScores = [:]
        kidsShardScores = [:]
    }

    /// Sends titles without a score to the AI, 40 per call; `pending` ({kind, id, title}) is re-read every round.
    func fillKids(lineID: String, pending: @escaping () -> [[String: Any]], done: @escaping () -> Void) {
        guard !fillingKids, !disabled, kidsLineID == lineID else { return }
        fillingKids = true
        Task { @MainActor in
            defer { fillingKids = false; done() }
            for _ in 0..<400 {
                guard kidsLineID == lineID, !disabled else { return }
                // One batch = one shard of the saved scores (id % kidsShards, as the function stores them).
                let todo = pending().filter { kidsScores["\($0["kind"] ?? ""):\($0["id"] ?? "")"] == nil }
                guard let firstID = todo.first?["id"] as? Int else { return }
                let shard = firstID % Self.kidsShards
                let batch = Array(todo.filter { ($0["id"] as? Int ?? -1) % Self.kidsShards == shard }.prefix(40))
                guard let res = await call("kidsTitles", ["lineId": lineID, "items": batch]) else { return }
                for (key, value) in res["scores"] as? [String: Any] ?? [:] {
                    if let n = value as? NSNumber { kidsScores[key] = n.doubleValue }
                }
            }
        }
    }

    // MARK: - Smart search

    struct SearchFilters: Equatable {
        let kind: String // movie | series | live | any
        let keywords: [String]
        let genres: [String]
        let languages: [String]
        let yearFrom: Int?
        let yearTo: Int?
        let sort: String // relevance | newest | rating

        /// "Hindi comedy movies, 2010–2019"
        var summary: String {
            let names = ["en": "English", "hi": "Hindi", "ta": "Tamil", "te": "Telugu", "ml": "Malayalam",
                         "es": "Spanish", "ar": "Arabic", "fr": "French"]
            let noun = ["movie": "movies", "series": "shows", "live": "channels"][kind] ?? "titles"
            var text = [languages.map { names[$0] ?? $0.uppercased() }.joined(separator: "/"), genres.joined(separator: "/"), noun]
                .filter { !$0.isEmpty }.joined(separator: " ")
            text = text.prefix(1).uppercased() + text.dropFirst()
            if let from = yearFrom, let to = yearTo, from != to {
                text += ", \(from)–\(to)"
            } else if let year = yearFrom ?? yearTo {
                text += ", \(year)"
            }
            if !keywords.isEmpty { text += " matching “\(keywords.joined(separator: " "))”" }
            return text
        }
    }

    private var searchCache: [String: SearchFilters] = [:]

    /// Natural-language request -> filters (nil when it reads like a plain title search or AI is off).
    func searchFilters(_ query: String) async -> SearchFilters? {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard q.split(whereSeparator: \.isWhitespace).count >= 3 else { return nil }
        if let cached = searchCache[q] { return cached }
        guard let r = await call("smartSearch", ["query": q]) else { return nil }
        let year = { (k: String) in (r[k] as? NSNumber)?.intValue }
        let f = SearchFilters(kind: r["kind"] as? String ?? "any", keywords: r["keywords"] as? [String] ?? [],
                              genres: r["genres"] as? [String] ?? [], languages: r["languages"] as? [String] ?? [],
                              yearFrom: year("yearFrom"), yearTo: year("yearTo"), sort: r["sort"] as? String ?? "relevance")
        searchCache[q] = f
        return f
    }

    nonisolated static func year(in title: String) -> Int? {
        guard let range = title.range(of: #"\b(19|20)\d{2}\b"#, options: .regularExpression) else { return nil }
        return Int(title[range])
    }

    // MARK: - Live channel alternatives

    private nonisolated static let qualityWords = #"\b(uhd|fhd|hd|sd|4k|8k|hevc|h265|backup|bk|raw|vip|plus|\d{3,4}p|50fps|60fps)\b"#

    /// "UK: Sky News FHD" and "Sky News HD" -> "sky news".
    nonisolated static func channelKey(_ name: String) -> String {
        name.lowercased()
            .replacingOccurrences(of: #"^[a-z]{2,3}\s*[|:\-]\s*"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: qualityWords, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - Player companion

/// Watches playback for the AI checks: where the credits start (so the next episode is offered when they
/// really begin), the opening titles (Skip Intro), and live channels that are black, frozen or off air.
/// Findings are saved as markers so every device in the household gets them without asking again.
@MainActor
@Observable
final class PlayerAI {
    /// Seek target while the Skip Intro button should show.
    private(set) var skipIntroTo: Double?
    /// When the AI (or a saved marker) saw the credits start.
    private(set) var creditsReachedAt: Date?
    /// "This channel is showing a black screen." when a live channel looks broken.
    private(set) var offAirMessage: String?

    @ObservationIgnored var grabFrame: (() async -> Data?)?
    @ObservationIgnored var onCreditsReached: (() -> Void)?

    @ObservationIgnored private var item: PlaybackItem?
    @ObservationIgnored private var ref: (lineID: String, kind: String, id: String)?
    @ObservationIgnored private var marker: SmartAI.ContentMarker?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var busy = false
    @ObservationIgnored private var nextCheckAt = Date.distantPast
    /// A normal scene from this episode, sent with intro checks so the AI can compare: on real episodes an opening
    /// montage scored 0.2–0.5 "intro" alone and 0.86–0.95 next to a scene from the same episode.
    @ObservationIgnored private var scene: Data?
    @ObservationIgnored private var lastPosition: (position: Double, at: Date, playing: Bool)?
    /// Bumped on every seek: answers to checks started before it are dropped.
    @ObservationIgnored private var pass = 0
    @ObservationIgnored private var creditsHit: Double?
    @ObservationIgnored private var creditsDone = false
    /// Seconds from the end where this show's credits started on an earlier episode.
    @ObservationIgnored private var creditsHint: Double?
    @ObservationIgnored private var introStart: Double?
    @ObservationIgnored private var introLast: Double?
    @ObservationIgnored private var introFirstCheck: Double?
    @ObservationIgnored private var introCandidate: Double?
    @ObservationIgnored private var introDone = false
    @ObservationIgnored private var liveDone = false
    @ObservationIgnored private var playingSince: Date?

    private static let checkInterval: TimeInterval = 10
    private static let liveOkKey = "nucflix.liveOkAt"
    private static let liveOkFor: TimeInterval = 6 * 3600
    private static let confirmInterval: TimeInterval = 3
    /// Finding intros frame by frame doesn't work on real shows (an opening montage reads as "a scene"), so the
    /// scan is off; saved intro markers still show Skip Intro. Planned instead: matching the opening across
    /// episodes of a series, the way streaming services do.
    private static let introScan = false
    /// Opening titles usually come within the first 7 minutes.
    private static let introScanUntil: Double = 420

    func start(item: PlaybackItem, lineID: String?) {
        stop()
        self.item = item
        let gen = generation
        guard item.contentType != .live, item.localFileURL == nil, let lineID else { return }
        let ref: (lineID: String, kind: String, id: String)?
        switch item.contentType {
        case .movie: ref = item.streamID.map { (lineID, "movie", String($0)) }
        case .seriesEpisode: ref = item.episodeID.map { (lineID, "episode", $0) }
        case .live: ref = nil
        }
        guard let ref else { return }
        self.ref = ref
        Task { @MainActor in
            let m = await SmartAI.shared.marker(lineID: ref.lineID, kind: ref.kind, id: ref.id)
            guard self.generation == gen else { return }
            // A new episode: where the show's credits started last time narrows the search to a few looks.
            if item.contentType == .seriesEpisode, m.creditsAt == nil, let seriesID = item.seriesID {
                let s = await SmartAI.shared.marker(lineID: ref.lineID, kind: "series", id: String(seriesID))
                guard self.generation == gen else { return }
                if let at = s.creditsAt, let duration = s.duration, duration - at > 5, duration - at < 900 {
                    self.creditsHint = duration - at
                }
            }
            self.marker = m
        }
    }

    func stop() {
        generation += 1
        item = nil
        ref = nil
        marker = nil
        busy = false
        nextCheckAt = .distantPast
        scene = nil
        lastPosition = nil
        creditsHit = nil
        creditsDone = false
        creditsHint = nil
        introStart = nil
        introLast = nil
        introFirstCheck = nil
        introCandidate = nil
        introDone = false
        liveDone = false
        playingSince = nil
        skipIntroTo = nil
        creditsReachedAt = nil
        offAirMessage = nil
    }

    func dismissOffAir() { offAirMessage = nil }
    func dismissSkipIntro() { skipIntroTo = nil }

    /// Past the detected start of the credits (progress then saves as finished).
    func pastCredits(_ position: Double) -> Bool {
        guard let at = marker?.creditsAt, at > 0 else { return false }
        return position >= at
    }

    func tick(position: Double, duration: Double, playing: Bool) {
        guard let item, position.isFinite else { return }
        if item.contentType == .live {
            liveTick(playing: playing)
            return
        }
        guard let m = marker, duration > 1, duration.isFinite else { return }
        watchForSeeks(position, playing: playing)
        if !creditsDone {
            if let at = m.creditsAt, at > 0 {
                if position >= at && position < duration - 2 { creditsReached() }
            } else if duration > 300 && position >= creditsFrom(duration) && playing {
                check("credits", position: position, duration: duration)
            }
        }
        guard item.contentType == .seriesEpisode else { return }
        if let end = m.introEnd {
            let from = m.introStart ?? 0
            let target: Double? = end > from + 5 && position >= from - 1 && position < end - 3 ? end : nil
            if skipIntroTo != target { skipIntroTo = target }
        } else if Self.introScan && !introDone && position < Self.introScanUntil && playing {
            check("intro", position: position, duration: duration)
        }
    }

    /// Where the credits search starts: just before this show's usual spot, else the last stretch of the title.
    private func creditsFrom(_ duration: Double) -> Double {
        if let hint = creditsHint { return max(duration * 0.5, duration - hint - 45) }
        return item?.contentType == .movie ? max(duration * 0.85, duration - 600) : max(duration * 0.8, duration - 600)
    }

    /// Gap between looks: tight around the show's usual spot, sparse elsewhere (each look is an AI call).
    private func checkStep(_ task: String, position: Double, duration: Double) -> TimeInterval {
        guard task == "credits" else { return Self.checkInterval }
        if let hint = creditsHint, position <= duration - hint + 60 { return 8 }
        return item?.contentType == .movie ? 30 : 15
    }

    /// A jump (scrubbing, skipping, resuming) breaks the run of frames the evidence was built on: start over.
    private func watchForSeeks(_ position: Double, playing: Bool) {
        // Compared even while buffering (a seek pauses playback for a moment). Standing still is a stall, not a
        // jump; only moving backwards, or forwards faster than the clock, is.
        let previous = lastPosition
        lastPosition = (position, Date(), playing)
        guard let previous else { return }
        let ran = previous.playing ? Date().timeIntervalSince(previous.at) : 0
        guard position <= previous.position - 3 || position >= previous.position + ran + 8 else { return }
        pass += 1
        // Every jump starts a fresh pass over the opening minutes (also after one that ended without a result);
        // "no intro" is only concluded by a pass that ran unbroken from the first minute.
        if marker?.introEnd == nil {
            introStart = nil
            introLast = nil
            introCandidate = nil
            introFirstCheck = nil
            introDone = false
        }
        creditsHit = nil
        nextCheckAt = Date().addingTimeInterval(2) // look again once the picture has settled
    }

    private func check(_ task: String, position: Double, duration: Double) {
        guard !busy, Date() >= nextCheckAt, !SmartAI.shared.disabled, let grabFrame, let item else { return }
        busy = true
        nextCheckAt = Date().addingTimeInterval(checkStep(task, position: position, duration: duration))
        let gen = generation
        let pass = self.pass
        let scene = self.scene
        Task { @MainActor in
            defer { if self.generation == gen { self.busy = false } }
            guard let frame = await grabFrame(), self.generation == gen,
                  let r = await SmartAI.shared.frameCheck(task: task, images: task == "intro" ? scene.map { [frame, $0] } ?? [frame] : [frame],
                                                          title: item.title),
                  self.generation == gen, self.pass == pass else { return }
            if self.scene == nil && r.p("programme") >= 0.7 { self.scene = frame }
            if task == "credits" {
                self.creditsFrame(r, position: position, duration: duration)
            } else {
                self.introFrame(r, position: position, duration: duration)
            }
        }
    }

    private func creditsFrame(_ r: SmartAI.FrameVerdict, position: Double, duration: Double) {
        let credits = r.p("end_credits") + r.p("next_preview")
        guard credits >= 0.7 else {
            creditsHit = nil
            return
        }
        guard let hit = creditsHit ?? (credits >= 0.92 ? position : nil) else {
            creditsHit = position // confirm with a second look a few seconds later
            nextCheckAt = Date().addingTimeInterval(Self.confirmInterval)
            return
        }
        marker?.creditsAt = hit
        if let ref {
            SmartAI.shared.saveMarker(lineID: ref.lineID, kind: ref.kind, id: ref.id, duration: duration, fields: ["creditsAt": hit])
            // Remembered for the show too, so its other episodes only look near the same spot.
            if item?.contentType == .seriesEpisode, let seriesID = item?.seriesID {
                SmartAI.shared.saveMarker(lineID: ref.lineID, kind: "series", id: String(seriesID), duration: duration, fields: ["creditsAt": hit])
            }
        }
        creditsReached()
    }

    private func creditsReached() {
        creditsDone = true
        creditsReachedAt = Date()
        onCreditsReached?()
    }

    private func introFrame(_ r: SmartAI.FrameVerdict, position: Double, duration: Double) {
        if introFirstCheck == nil { introFirstCheck = position }
        if r.p("intro") >= 0.7 {
            // Two sightings in a row (3 s apart) before the titles count as started: one odd frame isn't an
            // intro. Keep looking often while inside, to find the end to a second or two.
            nextCheckAt = Date().addingTimeInterval(Self.confirmInterval)
            if introStart == nil {
                guard let candidate = introCandidate else {
                    introCandidate = position
                    return
                }
                introStart = max(0, candidate - 4)
            }
            introLast = position
            return
        }
        introCandidate = nil
        var fields: [String: Double]?
        if let start = introStart {
            introDone = true // the titles just ended, somewhere between the last two looks
            fields = ["introStart": start, "introEnd": ((introLast ?? position) + position) / 2]
        } else if position > Self.introScanUntil - 20 {
            introDone = true
            // No opening titles in the first minutes: remember that too, but only if all of them were watched.
            if (introFirstCheck ?? .infinity) < 60 { fields = ["introStart": 0, "introEnd": 0] }
        }
        guard let fields else { return }
        marker?.introStart = fields["introStart"]
        marker?.introEnd = fields["introEnd"]
        if let ref { SmartAI.shared.saveMarker(lineID: ref.lineID, kind: ref.kind, id: ref.id, duration: duration, fields: fields) }
    }

    private func liveTick(playing: Bool) {
        guard !liveDone else { return }
        guard playing else {
            playingSince = nil
            return
        }
        guard let since = playingSince else {
            playingSince = Date()
            return
        }
        guard Date().timeIntervalSince(since) >= 10, !busy, !SmartAI.shared.disabled, let grabFrame, let item else { return }
        liveDone = true
        // A channel that looked fine recently isn't checked again (flicking through channels was an AI call each).
        let channel = String(item.streamID ?? 0)
        let okAt = UserDefaults.standard.dictionary(forKey: Self.liveOkKey) as? [String: Double] ?? [:]
        if Date().timeIntervalSince1970 - (okAt[channel] ?? 0) < Self.liveOkFor { return }
        busy = true
        let gen = generation
        Task { @MainActor in
            defer { if self.generation == gen { self.busy = false } }
            guard let a = await grabFrame() else { return }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard self.generation == gen, let b = await grabFrame(), self.generation == gen,
                  let r = await SmartAI.shared.frameCheck(task: "live", images: [a, b], title: item.title),
                  self.generation == gen else { return }
            guard r.label != "ok", r.p(r.label) >= 0.7, r.confidence >= 0.5 else {
                var seen = UserDefaults.standard.dictionary(forKey: Self.liveOkKey) as? [String: Double] ?? [:]
                seen[channel] = Date().timeIntervalSince1970
                // Keep the newest few hundred channels.
                if seen.count > 300 { seen = Dictionary(uniqueKeysWithValues: seen.sorted { $0.value > $1.value }.prefix(300).map { ($0.key, $0.value) }) }
                UserDefaults.standard.set(seen, forKey: Self.liveOkKey)
                return
            }
            self.offAirMessage = [
                "black": "This channel is showing a black screen.",
                "frozen": "This channel’s picture looks frozen.",
                "offline": "This channel looks off air."
            ][r.label] ?? "This channel may not be working."
        }
    }
}
